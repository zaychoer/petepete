defmodule Petepete.BillingScenario do
  @moduledoc """
  An issued session for the Billing command tests: a group whose host fronted a Rp100.000
  cost for three attendees (host, `a`, `b`) and owns the payout account. Shares are
  Rp34.000 each with Rp2.000 into the kas; the host's bill is Rp0 and paid by credit, the
  bills of `a` and `b` are unpaid for Rp34.000.
  """
  import Petepete.Fixtures

  alias Petepete.{Billing, Ledger, Repo}
  alias Petepete.Billing.Bill
  alias Petepete.Ledger.Event.GatewayPaymentReceived
  alias Petepete.Payments.PaymentAttempt

  @doc "Creates the group, draft session and costs, then issues it (key `issue-<n>`)."
  def issued do
    group = group_fixture()
    {user, host} = host_fixture(group)
    owner_account = Petepete.Fixtures.payout_account!(group, host)
    [a, b] = for _ <- 1..2, do: member_fixture(group, "member")
    session = session_fixture(group)
    for m <- [host, a, b], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 100_000, paid_by: host)

    ctx = %{
      group: group,
      user: user,
      host: host,
      a: a,
      b: b,
      session: session,
      payout_account: owner_account
    }

    Map.merge(ctx, issue(ctx))
  end

  @doc "Issues `ctx.session` with a fresh key; returns `%{issue: result, bills: %{member_id => bill}}`."
  def issue(ctx) do
    {:ok, result} =
      Billing.issue(ctx.session.id,
        actor: {:host, ctx.user.id},
        idempotency_key: "issue-#{uniq()}"
      )

    %{issue: result, bills: Map.new(result.bills, &{&1.member_id, &1})}
  end

  @doc "Options for a host command: actor plus a fresh (or given) idempotency key."
  def opts(ctx, extra \\ []) do
    Keyword.merge([actor: {:host, ctx.user.id}, idempotency_key: "k-#{uniq()}"], extra)
  end

  def reload(%Bill{id: id}), do: Repo.get!(Bill, id)

  @doc "A pending attempt of `bill` for a QRIS payment with the given fee."
  def attempt!(%Bill{} = bill, attrs \\ []) do
    seq = Keyword.get(attrs, :seq, 1)
    fee = Keyword.get(attrs, :fee, 240)

    Repo.insert!(
      struct(
        %PaymentAttempt{
          bill_id: bill.id,
          seq: seq,
          external_id: "#{bill.id}-#{seq}",
          provider: "fake",
          method: "qris",
          amount_due: bill.amount_due,
          fee: fee,
          gross_amount: bill.amount_due + fee,
          status: "pending"
        },
        Keyword.delete(attrs, :fee) |> Keyword.delete(:seq)
      )
    )
  end

  @doc "Posts a gateway payment of `amount` for `bill` straight through the Ledger."
  def gateway_payment!(ctx, %Bill{} = bill, amount) do
    {:ok, {:ok, res}} =
      Repo.transaction(fn ->
        Ledger.record(:gateway, %GatewayPaymentReceived{
          idempotency_key: "gw-#{uniq()}",
          group_id: ctx.group.id,
          bill_id: bill.id,
          member_id: bill.member_id,
          amount: amount
        })
      end)

    res.txn
  end

  def balance(ctx, member), do: Ledger.balances(ctx.group.id).members[member.id]
end
