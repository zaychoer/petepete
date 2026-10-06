defmodule Petepete.Billing.Invoicing do
  @moduledoc """
  `Billing.preview/1` and `Billing.issue/2`: reading a draft session's stored attendance
  and cost items, splitting them with `Petepete.Billing.Calculation`, and turning the
  split into bills.

  Preview and issue share one computation path: both call `Calculation.shares/1` over
  `load_input/1` and then `Calculation.apply_credit/2`. They differ only in where the
  balances come from. Preview reads `Ledger.balances/1` without a lock, so it can differ
  from the bills if a payment arrives in between. Issue takes its balances from the
  `balances_before` of the `session_billed` txn it posts, inside one transaction, so credit
  is applied against exactly the balances the posting saw.

  `issue/2` lock order (spec "Urutan kunci Billing"): the session row, the session's bill
  rows by id (`Petepete.Billing.Locks.lock_session_and_bills/1`), then the Ledger group
  lock inside `Ledger.record/2`.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, Calculation, CostItem, CostItemMember, Locks, Participant}
  alias Petepete.Billing.{Session, Transitions}
  alias Petepete.{Actor, Clock}
  alias Petepete.Groups.{Group, Member}
  alias Petepete.Ledger
  alias Petepete.Ledger.Audit
  alias Petepete.Ledger.Event.SessionBilled
  alias Petepete.Ledger.Txn
  alias Petepete.Metrics
  alias Petepete.Repo

  @token_bytes 24
  @token_ttl_days 30

  @doc """
  The breakdown the host sees before sending bills. See `Petepete.Billing.preview/1`.
  """
  @spec preview(pos_integer()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | Petepete.Billing.TransitionError.t()
             | {:invalid, [Calculation.error()]}}
  def preview(session_id) when is_integer(session_id) do
    with {:ok, session} <- fetch_session(session_id),
         :ok <- Transitions.session(session.status, "issued", :issue),
         {:ok, plan} <- Calculation.shares(load_input(session)) do
      balances = Ledger.balances(session.group_id).members

      {:ok,
       plan
       |> Calculation.apply_credit(balances)
       |> Map.put(:session_id, session.id)}
    end
  end

  @doc "Issues a draft session's bills. See `Petepete.Billing.issue/2`."
  @spec issue(pos_integer(), keyword()) ::
          {:ok, %{session: %Session{}, txn: %Txn{}, bills: [%Bill{}], replayed: boolean()}}
          | {:error, term()}
  def issue(session_id, opts) when is_integer(session_id) do
    actor = Keyword.fetch!(opts, :actor)
    key = Keyword.get(opts, :idempotency_key)

    if is_binary(key) and String.trim(key) != "" do
      Repo.transaction(fn ->
        with {:ok, session, bills} <- Locks.lock_session_and_bills(session_id),
             {:ok, reply} <- issue_locked(session, bills, actor, key) do
          reply
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :idempotency_key_required}
    end
  end

  ## Issue

  defp issue_locked(session, bills, actor, key) do
    case replayed_txn(session, key) do
      %Txn{} = txn ->
        live = Enum.reject(bills, &(&1.status == "void"))
        {:ok, %{session: session, txn: txn, bills: load_members(live), replayed: true}}

      nil ->
        post_and_bill(session, actor, key)
    end
  end

  # The same key on a session that this key already issued: answer with what exists.
  defp replayed_txn(%Session{status: "issued", issue_txn_id: txn_id}, key)
       when is_integer(txn_id) do
    case Repo.get_by(Txn, idempotency_key: key) do
      %Txn{id: ^txn_id} = txn -> txn
      _ -> nil
    end
  end

  defp replayed_txn(_session, _key), do: nil

  defp post_and_bill(session, actor, key) do
    with :ok <- Transitions.session(session.status, "issued", :issue),
         {:ok, plan} <- Calculation.shares(load_input(session)),
         billable = Enum.filter(plan.members, &(&1.share > 0)),
         {:ok, result} <- Ledger.record(actor, session_billed(session, key, plan, billable)),
         :ok <- fresh_txn(result) do
      final = Calculation.apply_credit(plan, result.balances_before)
      {:ok, issued} = Transitions.issue_session(session, result.txn.id)
      bills = for m <- final.members, m.share > 0, do: insert_bill(session, m)
      record_metrics(session, bills)
      record_audit(session, actor, result.txn, bills)

      {:ok, %{session: issued, txn: result.txn, bills: load_members(bills), replayed: false}}
    end
  end

  defp session_billed(session, key, plan, billable) do
    %SessionBilled{
      idempotency_key: key,
      group_id: session.group_id,
      session_id: session.id,
      shares: for(m <- billable, do: {m.member_id, m.share}),
      fronted: plan.fronted,
      kas_remainder: plan.kas_remainder
    }
  end

  # The key already posted a txn for this session, which has since been cancelled (the
  # session went back to draft): its txn is not a new issue and must not get new bills.
  defp fresh_txn(%{replayed: false}), do: :ok
  defp fresh_txn(%{replayed: true}), do: {:error, :idempotency_key_conflict}

  # PP-REL-02: in the issue transaction, so only the first issue of a key records anything.
  defp record_metrics(session, bills) do
    now = Clock.now()

    if started_at = first_edit_at(session) do
      Metrics.record(:session_build_duration,
        group_id: session.group_id,
        session_id: session.id,
        value_ms: Metrics.duration_ms(started_at, now)
      )
    end

    for bill <- bills do
      Metrics.record(:bills_sent,
        group_id: session.group_id,
        session_id: session.id,
        bill_id: bill.id
      )

      # Credit paid it in full at issue: counts as a zero-duration time to paid.
      if bill.status == "paid" do
        Metrics.record_paid(bill, session.group_id, bill.paid_at, :credit)
      end
    end

    :ok
  end

  # Host action that changes money: in the issue transaction, so a replay writes no second row.
  defp record_audit(session, %Actor{user_id: user_id}, txn, bills) do
    Audit.record(session.group_id, user_id, "session.issue", {"session", session.id}, %{
      "txn_id" => txn.id,
      "bill_ids" => Enum.map(bills, & &1.id),
      "total_billed" => bills |> Enum.map(& &1.share) |> Enum.sum()
    })
  end

  # The earliest cost item or attendance row the host created for the draft.
  defp first_edit_at(%Session{id: session_id}) do
    costs =
      Repo.one(from c in CostItem, where: c.session_id == ^session_id, select: min(c.inserted_at))

    attendance =
      Repo.one(
        from p in Participant, where: p.session_id == ^session_id, select: min(p.inserted_at)
      )

    case Enum.reject([costs, attendance], &is_nil/1) do
      [] -> nil
      times -> Enum.min(times, DateTime)
    end
  end

  defp insert_bill(session, member) do
    now = Clock.now()
    status = Transitions.initial_bill_status(member.amount_due)

    Repo.insert!(%Bill{
      session_id: session.id,
      member_id: member.member_id,
      share: member.share,
      credit_applied: member.credit_applied,
      amount_due: member.amount_due,
      status: status,
      paid_via: if(status == "paid", do: "credit"),
      paid_at: if(status == "paid", do: now),
      pay_token: Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false),
      token_expires_at: DateTime.add(now, @token_ttl_days, :day),
      inserted_at: now,
      updated_at: now
    })
  end

  defp load_members(bills),
    do: bills |> Repo.preload(:member) |> Enum.sort_by(& &1.member_id)

  ## Reading the stored rows

  defp fetch_session(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Attendance, weights and cost items of `session` in the shape `Calculation.shares/1`
  takes. Also used by `Petepete.Billing.PayPage` to rebuild a bill's lines.
  """
  @spec load_input(%Session{}) :: map()
  def load_input(%Session{id: session_id, group_id: group_id}) do
    participants =
      Repo.all(
        from p in Participant,
          join: m in Member,
          on: m.id == p.member_id,
          where: p.session_id == ^session_id and p.attended,
          select: %{member_id: p.member_id, display_name: m.display_name, weight: p.weight}
      )

    items = Repo.all(from c in CostItem, where: c.session_id == ^session_id)

    subset_members =
      from(cm in CostItemMember,
        where: cm.cost_item_id in ^Enum.map(items, & &1.id),
        select: {cm.cost_item_id, cm.member_id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    %{
      rounding_unit:
        Repo.one!(from g in Group, where: g.id == ^group_id, select: g.rounding_unit),
      participants: participants,
      items:
        for item <- items do
          %{
            id: item.id,
            category: item.category,
            label: item.label,
            amount: item.amount,
            paid_by_member_id: item.paid_by_member_id,
            scope: item.scope,
            member_ids: Map.get(subset_members, item.id, [])
          }
        end
    }
  end
end
