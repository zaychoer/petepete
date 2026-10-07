defmodule Petepete.Ledger do
  @moduledoc """
  A group's append-only double-entry record of money events (ADR-0001, ADR-0002).

  Schemas: `Petepete.Ledger.Txn` (`ledger_txns`), `Petepete.Ledger.Entry`
  (`ledger_entries`) and `Petepete.Ledger.AuditLog` (`audit_log`, host money actions).
  The database enforces zero-sum per txn (deferred constraint trigger) and rejects
  UPDATE/DELETE on txns and entries; this module is the rule, the trigger the backstop.

  Callers never send entries, signs or accounts. They hand `record/2` an Actor and one of
  eight event structs; the Ledger derives balanced entries and enforces that kind's rules.

  ## Writing: `record/2`

      record(actor, event) ::
        {:ok, %{txn: %Txn{entries: [%Entry{}]}, replayed: boolean}}
        | {:ok, %{txn: txn, replayed: boolean, balances_before: %{member_id => integer}}}  # SessionBilled only
        | {:error, reason}

  * **Actor**: a `%Petepete.Actor{}`: `type: :host` (with its `user_id` and `member_id`) for
    every event except `GatewayPaymentReceived`, which takes `Actor.gateway()` only. Anything
    else is `{:error, :invalid_actor}`. There is no system actor. The Ledger trusts that a
    host Actor was authorized at the edge (`Petepete.Groups.authorize_actor/3`); it never
    checks roles.
  * **Transaction**: `record/2` never opens a transaction. It must run inside the caller's
    `Repo.transaction/1` / `Ecto.Multi`; outside one it raises `ArgumentError`. A returned
    `{:error, _}` has written nothing, so the caller decides whether to roll back.
  * **Lock**: the first statement is `pg_advisory_xact_lock` for the event's group, so the
    caller must already hold its row locks (session, then bills by id); see ADR-0002.
  * **Idempotency**: `idempotency_key` is required and globally unique. Same key and same
    event (same group, actor, fields) returns the original txn with `replayed: true` and
    posts nothing; same key with a different event is `{:error, :idempotency_key_conflict}`.
    A replay is answered before any state rule, so it succeeds even if the state has moved on.
    `balances_before` of a replayed `SessionBilled` is recomputed from the entries older
    than the original txn.
  * `txn.entries` are the posted `Petepete.Ledger.Entry` rows. `txn.inserted_at` is the
    event's `at` for `CashReceived`/`CashPaymentCancelled`, else the current time.

  ## Events (`Petepete.Ledger.Event.*`)

  Every event has `:idempotency_key` (string) and `:group_id`. All amounts are positive integer
  rupiah. Every member id must belong to `group_id` (guests and former members included).

  | Struct | Extra fields | Entries (debit −, credit +) |
  | --- | --- | --- |
  | `SessionBilled` | `session_id`, `shares: [{member_id, share}]`, `fronted: [{member_id, amount}]` (default `[]`), `kas_remainder` (≥ 0) | −share per participant; +amount per fronted entry; +`kas_remainder` to kas (omitted when 0) |
  | `GatewayPaymentReceived` | `bill_id`, `member_id`, `amount` | +amount to member; −amount to the payout account owner |
  | `CashReceived` | `bill_id`, `member_id`, `amount`, `at` | +amount to member; −amount to the host Actor's `member_id` |
  | `Settlement` | `payer_member_id`, `payee_member_id`, `amount`, `note` | +amount payer; −amount payee |
  | `KasSpend` | `member_id`, `amount`, `note` | −amount kas; +amount member |
  | `SessionBillsCancelled` | `txn_id`, `reason` | mirror of that `session_billed` txn |
  | `CashPaymentCancelled` | `txn_id`, `reason`, `at` | mirror of that `cash_received` txn |
  | `Correction` | `txn_id`, `reason` | mirror of that `settlement` / `kas_spend` txn |

  `ref_type`/`ref_id` on the txn: `"session"`/`session_id` for `SessionBilled`,
  `"bill"`/`bill_id` for the two payments; undo events copy the original's. Undo events set
  `reverses_txn_id`. `note` of `Settlement`/`KasSpend` is stored in the txn's `reason`.

  ## Rules and typed errors

  Structural rules are checked before anything is read from the database, state rules after.

  * any: `:idempotency_key_required`, `:invalid_actor`, `:amount_not_positive`,
    `:group_not_found`, `:member_not_in_group`, `:invalid_time` (bad `at`), `:unknown_event`
  * `SessionBilled`: `:empty_shares`, `:duplicate_member` (in `shares`), `:negative_remainder`,
    `:unbalanced_shares` (Σ shares ≠ Σ fronted + kas_remainder)
  * `GatewayPaymentReceived`: `:no_payout_account` (the owner is the latest payout account's
    owner, resolved now and written into the entries; later owner changes leave history alone)
  * `CashReceived`: `:member_not_in_group` also when the host Actor's `member_id` is not on
    the group's roster
  * `Settlement`: `:same_member`
  * `KasSpend`: `:insufficient_kas` (amount > kas balance; cash and gateway payments have no cap)
  * undo events: `:reason_required`, `:txn_not_found` (missing or other group), `:not_undoable`
    (wrong kind for the event; gateway payments and the three undo kinds are never undoable),
    `:already_reversed` (once only), `:undo_window_expired` (`CashPaymentCancelled` when
    `at` is more than 24 hours after the `cash_received` txn's `inserted_at`)
  * `:idempotency_key_conflict`

  `SessionBillsCancelled` is not checked against the kas balance; kas may go negative.

  ## Reading

  `balances/1` and `txns/2` read the entries directly; there is no cache.
  """

  import Ecto.Query

  alias Petepete.Actor
  alias Petepete.Groups.{Member, PayoutAccount}
  alias Petepete.Ledger.Event
  alias Petepete.Ledger.{Entry, Txn}
  alias Petepete.Repo

  @undo_window_seconds 24 * 60 * 60

  @lock_namespace 0x4C444752

  @undo_rules %{
    Event.SessionBillsCancelled => ["session_billed"],
    Event.CashPaymentCancelled => ["cash_received"],
    Event.Correction => ["settlement", "kas_spend"]
  }

  @kinds %{
    Event.SessionBilled => "session_billed",
    Event.GatewayPaymentReceived => "gateway_payment_received",
    Event.CashReceived => "cash_received",
    Event.Settlement => "settlement",
    Event.KasSpend => "kas_spend",
    Event.SessionBillsCancelled => "session_bills_cancelled",
    Event.CashPaymentCancelled => "cash_payment_cancelled",
    Event.Correction => "correction"
  }

  @type account :: :kas | {:member, pos_integer()}

  # ── Writing ────────────────────────────────────────────────────────────────

  @doc "Posts one money event. See the moduledoc for the contract."
  @spec record(Actor.t(), Event.t()) :: {:ok, map()} | {:error, atom()}
  def record(%Actor{} = actor, %mod{} = event) when is_map_key(@kinds, mod) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "Ledger.record/2 must run inside the caller's Repo.transaction/Ecto.Multi"
    end

    lock_group(event.group_id)

    with :ok <- group_exists(event.group_id),
         {:ok, spec} <- plan(actor, event) do
      case Repo.get_by(Txn, idempotency_key: event.idempotency_key) do
        nil -> post(spec, event)
        txn -> replay(txn, spec, event)
      end
    end
  end

  def record(%Actor{}, _event), do: {:error, :unknown_event}

  defp lock_group(group_id) when is_integer(group_id) do
    key = Bitwise.bor(Bitwise.bsl(@lock_namespace, 32), Bitwise.band(group_id, 0xFFFFFFFF))
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end

  defp lock_group(_), do: raise(ArgumentError, "event.group_id must be an integer")

  defp group_exists(group_id) do
    if Repo.exists?(from g in Petepete.Groups.Group, where: g.id == ^group_id),
      do: :ok,
      else: {:error, :group_not_found}
  end

  # ── Planning (no state beyond the original txn of undo events) ─────────────

  # A spec is the event reduced to what gets stored. Accounts may be the placeholders
  # :payout_owner, resolved only when actually posting.
  defp plan(actor, event) do
    with :ok <- check_key(event.idempotency_key),
         :ok <- check_actor(actor, event),
         {:ok, spec} <- do_plan(actor, event) do
      {:ok, Map.merge(spec, actor_fields(actor))}
    end
  end

  defp check_key(key) when is_binary(key), do: if(String.trim(key) == "", do: err(), else: :ok)
  defp check_key(_), do: err()
  defp err, do: {:error, :idempotency_key_required}

  defp check_actor(%Actor{type: :gateway}, %Event.GatewayPaymentReceived{}), do: :ok

  defp check_actor(%Actor{type: :host, user_id: user_id, member_id: member_id}, event)
       when is_integer(user_id) and is_integer(member_id) do
    if is_struct(event, Event.GatewayPaymentReceived), do: {:error, :invalid_actor}, else: :ok
  end

  defp check_actor(_, _), do: {:error, :invalid_actor}

  defp actor_fields(%Actor{type: :gateway}), do: %{actor_type: "gateway", actor_user_id: nil}

  defp actor_fields(%Actor{type: :host, user_id: id}),
    do: %{actor_type: "host", actor_user_id: id}

  defp base(event, extra) do
    Map.merge(
      %{
        kind: Map.fetch!(@kinds, event.__struct__),
        group_id: event.group_id,
        ref_type: nil,
        ref_id: nil,
        reverses_txn_id: nil,
        reason: nil,
        at: now(),
        member_ids: [],
        entries: []
      },
      extra
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp do_plan(_actor, %Event.SessionBilled{} = e) do
    shares = e.shares
    fronted = e.fronted
    share_ids = Enum.map(shares, &elem(&1, 0))

    with :ok <- non_empty(shares),
         :ok <- positive_pairs(shares),
         :ok <- positive_pairs(fronted),
         :ok <- unique(share_ids),
         :ok <- remainder(e.kas_remainder),
         :ok <- balanced(shares, fronted, e.kas_remainder) do
      entries =
        Enum.map(shares, fn {m, a} -> {{:member, m}, -a} end) ++
          Enum.map(fronted, fn {m, a} -> {{:member, m}, a} end) ++
          if(e.kas_remainder > 0, do: [{:kas, e.kas_remainder}], else: [])

      {:ok,
       base(e, %{
         ref_type: "session",
         ref_id: e.session_id,
         member_ids: Enum.uniq(share_ids ++ Enum.map(fronted, &elem(&1, 0))),
         entries: entries
       })}
    end
  end

  defp do_plan(_actor, %Event.GatewayPaymentReceived{} = e) do
    with :ok <- positive(e.amount) do
      {:ok,
       base(e, %{
         ref_type: "bill",
         ref_id: e.bill_id,
         member_ids: [e.member_id],
         entries: [{{:member, e.member_id}, e.amount}, {:payout_owner, -e.amount}]
       })}
    end
  end

  defp do_plan(%Actor{member_id: host_member_id}, %Event.CashReceived{} = e) do
    with :ok <- positive(e.amount),
         {:ok, at} <- time(e.at) do
      {:ok,
       base(e, %{
         ref_type: "bill",
         ref_id: e.bill_id,
         at: at,
         member_ids: [e.member_id, host_member_id],
         entries: [{{:member, e.member_id}, e.amount}, {{:member, host_member_id}, -e.amount}]
       })}
    end
  end

  defp do_plan(_actor, %Event.Settlement{} = e) do
    with :ok <- positive(e.amount),
         :ok <- if(e.payer_member_id == e.payee_member_id, do: {:error, :same_member}, else: :ok) do
      {:ok,
       base(e, %{
         reason: e.note,
         member_ids: [e.payer_member_id, e.payee_member_id],
         entries: [
           {{:member, e.payer_member_id}, e.amount},
           {{:member, e.payee_member_id}, -e.amount}
         ]
       })}
    end
  end

  defp do_plan(_actor, %Event.KasSpend{} = e) do
    with :ok <- positive(e.amount) do
      {:ok,
       base(e, %{
         reason: e.note,
         member_ids: [e.member_id],
         entries: [{:kas, -e.amount}, {{:member, e.member_id}, e.amount}]
       })}
    end
  end

  defp do_plan(_actor, %mod{} = e) when is_map_key(@undo_rules, mod) do
    with :ok <- reason(e.reason),
         {:ok, at} <- undo_time(e),
         {:ok, orig} <- load_original(e),
         :ok <- undoable(mod, orig) do
      {:ok,
       base(e, %{
         ref_type: orig.ref_type,
         ref_id: orig.ref_id,
         reverses_txn_id: orig.id,
         reason: e.reason,
         at: at,
         original: orig,
         entries: Enum.map(orig.entries, fn en -> {account(en), -en.amount} end)
       })}
    end
  end

  defp undo_time(%Event.CashPaymentCancelled{at: at}), do: time(at)
  defp undo_time(_), do: {:ok, now()}

  defp time(%DateTime{} = at), do: {:ok, DateTime.truncate(at, :second)}
  defp time(_), do: {:error, :invalid_time}

  defp non_empty([_ | _]), do: :ok
  defp non_empty(_), do: {:error, :empty_shares}

  defp positive(a) when is_integer(a) and a > 0, do: :ok
  defp positive(_), do: {:error, :amount_not_positive}

  defp positive_pairs(list) when is_list(list) do
    if Enum.all?(list, fn {_m, a} -> positive(a) == :ok end),
      do: :ok,
      else: {:error, :amount_not_positive}
  end

  defp unique(ids),
    do: if(length(Enum.uniq(ids)) == length(ids), do: :ok, else: {:error, :duplicate_member})

  defp remainder(r) when is_integer(r) and r >= 0, do: :ok
  defp remainder(_), do: {:error, :negative_remainder}

  defp balanced(shares, fronted, remainder) do
    sum = fn l -> Enum.reduce(l, 0, fn {_, a}, acc -> acc + a end) end

    if sum.(shares) == sum.(fronted) + remainder, do: :ok, else: {:error, :unbalanced_shares}
  end

  defp reason(r) when is_binary(r),
    do: if(String.trim(r) == "", do: {:error, :reason_required}, else: :ok)

  defp reason(_), do: {:error, :reason_required}

  defp load_original(%{txn_id: id, group_id: group_id}) when is_integer(id) do
    case Repo.get(Txn, id) do
      %Txn{group_id: ^group_id} = txn -> {:ok, Repo.preload(txn, entries: entries_query())}
      _ -> {:error, :txn_not_found}
    end
  end

  defp load_original(_), do: {:error, :txn_not_found}

  defp undoable(mod, %Txn{kind: kind}) do
    if kind in Map.fetch!(@undo_rules, mod), do: :ok, else: {:error, :not_undoable}
  end

  defp entries_query, do: from(e in Entry, order_by: e.id)

  defp account(%Entry{account_type: "kas"}), do: :kas
  defp account(%Entry{account_type: "member", member_id: id}), do: {:member, id}

  # ── Posting a new txn ──────────────────────────────────────────────────────

  defp post(spec, event) do
    with :ok <- members_in_group(spec),
         :ok <- state_rules(spec, event),
         {:ok, entries} <- resolve(spec.entries, spec) do
      balances_before = balances_before(event, nil)

      txn =
        Repo.insert!(%Txn{
          group_id: spec.group_id,
          kind: spec.kind,
          ref_type: spec.ref_type,
          ref_id: spec.ref_id,
          actor_type: spec.actor_type,
          actor_user_id: spec.actor_user_id,
          reverses_txn_id: spec.reverses_txn_id,
          reason: spec.reason,
          idempotency_key: event.idempotency_key,
          inserted_at: spec.at
        })

      rows =
        Enum.map(entries, fn {acct, amount} ->
          {type, member_id} = column(acct)

          %{
            txn_id: txn.id,
            group_id: spec.group_id,
            account_type: type,
            member_id: member_id,
            amount: amount
          }
        end)

      {_, inserted} = Repo.insert_all(Entry, rows, returning: true)
      inserted = Enum.sort_by(inserted, & &1.id)

      {:ok, result(%{txn | entries: inserted}, false, balances_before)}
    end
  end

  defp column(:kas), do: {"kas", nil}
  defp column({:member, id}), do: {"member", id}

  defp result(txn, replayed, nil), do: %{txn: txn, replayed: replayed}

  defp result(txn, replayed, balances_before),
    do: %{txn: txn, replayed: replayed, balances_before: balances_before}

  defp members_in_group(%{member_ids: ids, group_id: group_id}) do
    ids = Enum.uniq(ids)

    if Enum.all?(ids, &is_integer/1) and
         Repo.aggregate(
           from(m in Member, where: m.group_id == ^group_id and m.id in ^ids),
           :count
         ) ==
           length(ids),
       do: :ok,
       else: {:error, :member_not_in_group}
  end

  defp state_rules(%{kind: "kas_spend", entries: entries, group_id: group_id}, _event) do
    {:kas, neg} = List.keyfind(entries, :kas, 0)
    if -neg <= kas_balance(group_id), do: :ok, else: {:error, :insufficient_kas}
  end

  defp state_rules(%{reverses_txn_id: id, original: orig, at: at, kind: kind}, _event)
       when is_integer(id) do
    cond do
      Repo.exists?(from t in Txn, where: t.reverses_txn_id == ^id) ->
        {:error, :already_reversed}

      kind == "cash_payment_cancelled" and
          not cash_undo_window_open?(orig.inserted_at, at) ->
        {:error, :undo_window_expired}

      true ->
        :ok
    end
  end

  defp state_rules(_spec, _event), do: :ok

  defp resolve(entries, spec) do
    Enum.reduce_while(entries, {:ok, []}, fn {acct, amount}, {:ok, acc} ->
      case resolve_account(acct, spec) do
        {:ok, resolved} -> {:cont, {:ok, [{resolved, amount} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp resolve_account(:payout_owner, %{group_id: group_id}) do
    owner =
      Repo.one(
        from p in PayoutAccount,
          where: p.group_id == ^group_id,
          order_by: [desc: p.id],
          limit: 1,
          select: p.owner_member_id
      )

    if owner, do: {:ok, {:member, owner}}, else: {:error, :no_payout_account}
  end

  defp resolve_account(acct, _spec), do: {:ok, acct}

  # ── Replaying an existing key ──────────────────────────────────────────────

  defp replay(%Txn{} = txn, spec, event) do
    txn = Repo.preload(txn, entries: entries_query())
    stored = Enum.map(txn.entries, fn en -> {account(en), en.amount} end)

    # The payout owner was fixed when the txn was posted; take it from there.
    placeholder =
      case Enum.find(stored, fn {acct, amount} -> amount < 0 and acct != :kas end) do
        {acct, _} -> acct
        nil -> nil
      end

    expected =
      Enum.map(spec.entries, fn
        {:payout_owner, amount} -> {placeholder, amount}
        other -> other
      end)

    same? =
      txn.group_id == spec.group_id and txn.kind == spec.kind and
        txn.ref_type == spec.ref_type and txn.ref_id == spec.ref_id and
        txn.reverses_txn_id == spec.reverses_txn_id and txn.reason == spec.reason and
        txn.actor_type == spec.actor_type and txn.actor_user_id == spec.actor_user_id and
        Enum.sort(expected) == Enum.sort(stored)

    if same?,
      do: {:ok, result(txn, true, balances_before(event, txn.id))},
      else: {:error, :idempotency_key_conflict}
  end

  # ── Balances before a SessionBilled posting ────────────────────────────────

  defp balances_before(%Event.SessionBilled{group_id: group_id, shares: shares}, upto_txn_id) do
    ids = Enum.map(shares, &elem(&1, 0))

    query =
      from e in Entry,
        where: e.group_id == ^group_id and e.member_id in ^ids,
        group_by: e.member_id,
        select: {e.member_id, fragment("sum(?)::bigint", e.amount)}

    query = if upto_txn_id, do: where(query, [e], e.txn_id < ^upto_txn_id), else: query

    sums = query |> Repo.all() |> Map.new()
    Map.new(ids, &{&1, Map.get(sums, &1, 0)})
  end

  defp balances_before(_event, _), do: nil

  @doc """
  Whether a `cash_received` txn written at `cash_at` can still be undone by a
  `CashPaymentCancelled` at `at` (24 hours). The Ledger stays authoritative; callers use
  this only to decide whether to offer the action.
  """
  @spec cash_undo_window_open?(DateTime.t(), DateTime.t()) :: boolean()
  def cash_undo_window_open?(%DateTime{} = cash_at, %DateTime{} = at),
    do: DateTime.diff(at, cash_at) <= @undo_window_seconds

  # ── Reading ────────────────────────────────────────────────────────────────

  @doc """
  Balances of a group, summed straight from the entries.

  Returns `%{kas: integer, members: %{member_id => integer}}`; every member of the group is
  present (0 if untouched). Negative member balance = owes the group; positive = credit.
  """
  @spec balances(pos_integer()) :: %{kas: integer(), members: %{pos_integer() => integer()}}
  def balances(group_id) do
    members =
      from(m in Member,
        left_join: e in Entry,
        on: e.member_id == m.id and e.account_type == "member",
        where: m.group_id == ^group_id,
        group_by: m.id,
        select: {m.id, fragment("coalesce(sum(?), 0)::bigint", e.amount)}
      )
      |> Repo.all()
      |> Map.new()

    %{kas: kas_balance(group_id), members: members}
  end

  defp kas_balance(group_id) do
    Repo.one(
      from e in Entry,
        where: e.group_id == ^group_id and e.account_type == "kas",
        select: fragment("coalesce(sum(?), 0)::bigint", e.amount)
    )
  end

  @doc """
  A group's txns in chronological order (oldest first), each with all its entries.

  Options: `member_id:` keeps only txns that have an entry for that member.
  """
  @spec txns(pos_integer(), keyword()) :: [%Txn{}]
  def txns(group_id, opts \\ []) do
    query =
      from t in Txn,
        where: t.group_id == ^group_id,
        order_by: t.id,
        preload: [entries: ^entries_query()]

    query =
      case Keyword.get(opts, :member_id) do
        nil ->
          query

        member_id ->
          from t in query,
            where:
              t.id in subquery(
                from e in Entry, where: e.member_id == ^member_id, select: e.txn_id
              )
      end

    Repo.all(query)
  end
end
