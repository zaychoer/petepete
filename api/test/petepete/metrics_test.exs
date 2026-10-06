defmodule Petepete.MetricsTest do
  use Petepete.DataCase, async: true

  import Ecto.Query
  import Petepete.BillingScenario, only: [attempt!: 1, attempt!: 2, opts: 1]
  import Petepete.Fixtures

  alias Petepete.{Billing, Clock, Metrics}
  alias Petepete.Billing.{Bill, CostItem, Participant}
  alias Petepete.Metrics.Event

  @t0 ~U[2026-10-06 03:00:00Z]

  setup do
    Clock.freeze(@t0)

    group = group_fixture()
    {user, host} = host_fixture(group)
    payout_account_fixture(group, host)
    guest = member_fixture(group, role: "guest")
    {_account, installed} = plain_member_fixture(group)
    session = session_fixture(event_fixture(group))
    for m <- [host, guest, installed], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 90_000, paid_by: host)

    %{group: group, user: user, host: host, guest: guest, installed: installed, session: session}
  end

  defp backdate(session, opts) do
    for {table, schema} <- [cost: CostItem, attendance: Participant], seconds = opts[table] do
      at = DateTime.add(@t0, -seconds, :second)

      Repo.update_all(from(r in schema, where: r.session_id == ^session.id),
        set: [inserted_at: at]
      )
    end
  end

  defp issue!(ctx, key \\ "issue-key") do
    {:ok, result} =
      Billing.issue(ctx.session.id, actor: {:host, ctx.user.id}, idempotency_key: key)

    result
  end

  defp events(ctx, name) do
    Repo.all(from e in Event, where: e.group_id == ^ctx.group.id and e.name == ^name)
  end

  defp events_for(ctx, name, bill), do: Enum.filter(events(ctx, name), &(&1.bill_id == bill.id))

  defp bill_of(issue, member), do: Enum.find(issue.bills, &(&1.member_id == member.id))

  defp pay_gateway(bill, key \\ "gw-1", seq \\ 1) do
    attempt = attempt!(bill, seq: seq)

    Repo.transaction(fn ->
      Billing.apply_gateway_payment(bill.id, %{
        paid_amount: attempt.gross_amount,
        matches_expected: true,
        idempotency_key: key,
        attempt_id: attempt.id
      })
    end)
  end

  describe "issue" do
    test "records the build duration from the earliest cost or attendance row", ctx do
      backdate(ctx.session, cost: 600, attendance: 3_600)
      issue!(ctx)
      assert [%{value_ms: 3_600_000, session_id: sid}] = events(ctx, "session_build_duration")
      assert sid == ctx.session.id

      # Cost items are the earlier edits here.
      other = session_fixture(event_fixture(ctx.group))
      attendance_fixture(other, ctx.host)
      cost_item_fixture(other, amount: 50_000, paid_by: ctx.host)
      backdate(other, cost: 7_200, attendance: 60)
      {:ok, _} = Billing.issue(other.id, opts(ctx))

      assert [3_600_000, 7_200_000] =
               events(ctx, "session_build_duration") |> Enum.map(& &1.value_ms) |> Enum.sort()
    end

    test "records one bills_sent event per bill", ctx do
      result = issue!(ctx)

      sent = events(ctx, "bills_sent")
      assert length(sent) == length(result.bills) and sent != []
      assert Enum.sort(Enum.map(sent, & &1.bill_id)) == Enum.sort(Enum.map(result.bills, & &1.id))
    end

    test "a replay with the same key records nothing more", ctx do
      issue!(ctx)
      before = Repo.aggregate(Event, :count)
      assert %{replayed: true} = issue!(ctx)
      assert Repo.aggregate(Event, :count) == before
    end

    test "a failed issue records nothing", ctx do
      Repo.delete_all(from c in CostItem, where: c.session_id == ^ctx.session.id)
      assert {:error, _} = Billing.issue(ctx.session.id, opts(ctx))
      assert Repo.aggregate(Event, :count) == 0
    end

    test "re-issuing a voided session keeps the first build duration", ctx do
      first = issue!(ctx)

      {:ok, _} =
        Billing.void_issue(ctx.session.id, opts(ctx) |> Keyword.put(:reason, "salah hitung"))

      Clock.advance(3_600)
      second = issue!(ctx, "issue-again")

      assert [_one] = events(ctx, "session_build_duration")
      # The reissued bills are new bills sent.
      assert length(events(ctx, "bills_sent")) == length(first.bills) + length(second.bills)
    end
  end

  describe "cash payment" do
    test "records time_to_paid once, never paid_without_install", ctx do
      bill = bill_of(issue!(ctx), ctx.guest)
      Clock.advance(90)

      assert {:ok, %{replayed: false}} =
               Billing.mark_paid_cash(
                 bill.id,
                 opts(ctx) |> Keyword.put(:idempotency_key, "cash-1")
               )

      assert [%{value_ms: 90_000}] = events_for(ctx, "time_to_paid", bill)
      assert events(ctx, "paid_without_install") == []

      assert {:ok, %{replayed: true}} =
               Billing.mark_paid_cash(
                 bill.id,
                 opts(ctx) |> Keyword.put(:idempotency_key, "cash-1")
               )

      assert [_one] = events_for(ctx, "time_to_paid", bill)
    end

    test "a bill paid at issue by credit counts with time_to_paid 0, once", ctx do
      result = issue!(ctx)
      credit_bill = Enum.find(result.bills, &(&1.amount_due == 0 and &1.status == "paid"))
      assert credit_bill

      assert [%{value_ms: 0}] = events_for(ctx, "time_to_paid", credit_bill)
      assert events_for(ctx, "paid_without_install", credit_bill) == []
      issue!(ctx)
      assert [_one] = events_for(ctx, "time_to_paid", credit_bill)
    end

    test "cancelling and taking the cash again counts the bill once", ctx do
      bill = bill_of(issue!(ctx), ctx.guest)
      {:ok, _} = Billing.mark_paid_cash(bill.id, opts(ctx))
      {:ok, _} = Billing.cancel_cash(bill.id, opts(ctx) |> Keyword.put(:reason, "salah tandai"))
      Clock.advance(600)
      {:ok, %{replayed: false}} = Billing.mark_paid_cash(bill.id, opts(ctx))

      assert [%{value_ms: 0}] = events_for(ctx, "time_to_paid", bill)
    end
  end

  describe "gateway payment" do
    test "records time_to_paid and paid_without_install for a member without an account",
         ctx do
      bill = bill_of(issue!(ctx), ctx.guest)
      Clock.advance(120)

      assert {:ok, {:ok, :paid}} = pay_gateway(bill)

      assert [%{value_ms: 120_000, bill_id: bill_id}] = events_for(ctx, "time_to_paid", bill)
      assert [%{bill_id: ^bill_id, value_ms: nil}] = events(ctx, "paid_without_install")
    end

    test "records no paid_without_install for a member with an account", ctx do
      bill = bill_of(issue!(ctx), ctx.installed)
      assert {:ok, {:ok, :paid}} = pay_gateway(bill)

      assert [_one] = events_for(ctx, "time_to_paid", bill)
      assert events(ctx, "paid_without_install") == []
    end

    test "a replayed notification records nothing more", ctx do
      bill = bill_of(issue!(ctx), ctx.guest)
      assert {:ok, {:ok, :paid}} = pay_gateway(bill)
      before = Repo.aggregate(Event, :count)

      assert {:ok, {:ok, :paid}} = pay_gateway(bill, "gw-1", 2)

      assert Repo.aggregate(Event, :count) == before
    end

    test "a second payment on a paid bill (credit) records nothing", ctx do
      bill = bill_of(issue!(ctx), ctx.guest)
      assert {:ok, {:ok, :paid}} = pay_gateway(bill)
      before = Repo.aggregate(Event, :count)

      assert {:ok, {:ok, :overpaid}} = pay_gateway(Repo.get!(Bill, bill.id), "gw-2", 2)
      assert Repo.aggregate(Event, :count) == before
    end

    test "an amount mismatch (needs_review) records nothing", ctx do
      bill = bill_of(issue!(ctx), ctx.guest)
      attempt = attempt!(bill)
      before = Repo.aggregate(Event, :count)

      assert {:ok, {:ok, :needs_review}} =
               Repo.transaction(fn ->
                 Billing.apply_gateway_payment(bill.id, %{
                   paid_amount: attempt.gross_amount - 1,
                   matches_expected: false,
                   idempotency_key: "gw-short",
                   attempt_id: attempt.id
                 })
               end)

      assert Repo.aggregate(Event, :count) == before
      assert events_for(ctx, "time_to_paid", bill) == []
    end
  end

  describe "record/2" do
    test "refuses to run outside a transaction", ctx do
      assert_raise ArgumentError, fn ->
        Metrics.record(:bills_sent, group_id: ctx.group.id)
      end
    end
  end

  test "metric_events holds no phone numbers, names or user ids" do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'metric_events'"
      )

    assert rows |> List.flatten() |> Enum.sort() ==
             ~w(bill_id group_id id inserted_at name session_id value_ms)
  end
end
