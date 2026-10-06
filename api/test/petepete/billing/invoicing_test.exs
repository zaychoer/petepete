defmodule Petepete.Billing.InvoicingTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.{Billing, Clock, Ledger}
  alias Petepete.Billing.{Bill, Session, TransitionError}
  alias Petepete.Ledger.Event.Settlement

  @t0 ~U[2026-10-06 03:00:00Z]

  setup do
    Clock.freeze(@t0)
    :ok
  end

  # The spec's "Pos subset" session: 10 attended, lapangan Rp350.000 + wasit Rp100.000 for all,
  # minum Rp60.000 for 6 drinkers. The host (not a drinker) fronted the lapangan, `payer`
  # (a drinker) fronted wasit and minum.
  defp example1(group_attrs \\ %{}) do
    group = group_fixture(group_attrs)
    {user, host} = host_fixture(group)
    payer = member_fixture(group, role: "member")
    drinkers = [payer | for(_ <- 1..5, do: member_fixture(group, role: "member"))]
    others = for _ <- 1..3, do: member_fixture(group, role: "member")
    session = session_fixture(event_fixture(group))

    for m <- [host | drinkers ++ others], do: attendance_fixture(session, m)

    cost_item_fixture(session, amount: 350_000, paid_by: host, category: "lapangan")
    cost_item_fixture(session, amount: 100_000, paid_by: payer, category: "wasit")

    cost_item_fixture(session,
      amount: 60_000,
      paid_by: payer,
      category: "minum",
      members: drinkers
    )

    %{
      group: group,
      user: user,
      host: host,
      payer: payer,
      drinkers: drinkers,
      others: others,
      session: session,
      opts: [actor: {:host, user.id}, idempotency_key: "issue-#{uniq()}"]
    }
  end

  # 3 attended, one cost of Rp100.000 fronted by the first member.
  defp rounding_example do
    group = group_fixture()
    {user, host} = host_fixture(group)
    [m2, m3] = for _ <- 1..2, do: member_fixture(group, role: "member")
    session = session_fixture(event_fixture(group))
    for m <- [host, m2, m3], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 100_000, paid_by: host)
    %{group: group, host: host, members: [host, m2, m3], session: session, user: user}
  end

  defp issue!(ctx, opts \\ nil) do
    assert {:ok, result} = Billing.issue(ctx.session.id, opts || ctx.opts)
    result
  end

  defp credit!(ctx, member, amount) do
    {:ok, {:ok, _}} =
      Repo.transaction(fn ->
        Ledger.record(ctx.opts[:actor], %Settlement{
          idempotency_key: "credit-#{uniq()}",
          group_id: ctx.group.id,
          payer_member_id: member.id,
          payee_member_id: ctx.host.id,
          amount: amount
        })
      end)
  end

  defp by_member(list), do: Map.new(list, &{&1.member_id, &1})

  describe "preview/1" do
    test "splits the stored rows: per person, per item, total billed against total cost" do
      ctx = example1()
      assert {:ok, preview} = Billing.preview(ctx.session.id)

      members = by_member(preview.members)
      for m <- ctx.drinkers, do: assert(members[m.id].share == 55_000)
      for m <- [ctx.host | ctx.others], do: assert(members[m.id].share == 45_000)

      assert preview.total_cost == 510_000
      assert preview.total_billed == 510_000
      assert preview.kas_remainder == 0
      assert Enum.map(preview.items, & &1.category) == ["lapangan", "wasit", "minum"]

      drinker = members[ctx.payer.id]

      assert Enum.map(drinker.lines, &{&1.category, &1.amount}) ==
               [{"lapangan", 35_000}, {"wasit", 10_000}, {"minum", 10_000}]

      assert drinker.display_name == ctx.payer.display_name
    end

    test "shows the kas remainder (Masuk kas) of the rounding example" do
      ctx = rounding_example()
      assert {:ok, preview} = Billing.preview(ctx.session.id)

      assert Enum.map(preview.members, & &1.share) == [34_000, 34_000, 34_000]
      assert preview.total_billed == 102_000
      assert preview.kas_remainder == 2_000
    end

    test "uses the group's rounding unit" do
      ctx = rounding_example()
      Repo.update_all(Petepete.Groups.Group, set: [rounding_unit: 500])

      assert {:ok, %{rounding_unit: 500} = preview} = Billing.preview(ctx.session.id)
      assert Enum.map(preview.members, & &1.share) == [33_500, 33_500, 33_500]
      assert preview.kas_remainder == 500
    end

    test "only members marked attended are billed" do
      ctx = rounding_example()
      absent = member_fixture(ctx.group, role: "member")
      attendance_fixture(ctx.session, absent, attended: false)

      assert {:ok, preview} = Billing.preview(ctx.session.id)
      refute absent.id in Enum.map(preview.members, & &1.member_id)
      assert preview.total_billed == 102_000
    end

    test "a subset item skips members who did not come" do
      ctx = example1()
      [absent | _] = Enum.reject(ctx.drinkers, &(&1.id == ctx.payer.id))

      Repo.update_all(from(p in Billing.Participant, where: p.member_id == ^absent.id),
        set: [attended: false]
      )

      assert {:ok, preview} = Billing.preview(ctx.session.id)
      members = by_member(preview.members)

      refute Map.has_key?(members, absent.id)

      # 9 attended: lapangan + wasit Rp450.000 / 9 = Rp50.000; minum Rp60.000 / 5 drinkers = Rp12.000.
      assert members[ctx.payer.id].share == 62_000
      assert members[hd(ctx.others).id].share == 50_000
    end

    test "credit comes from the ledger balances: a debt is not deducted, a balance is" do
      ctx = example1()
      [a, b, c | _] = ctx.others
      credit!(ctx, a, 20_000)
      # b receives a settlement from c: b is now Rp5.000 in debt.
      credit!(%{ctx | host: b}, c, 5_000)

      {:ok, preview} = Billing.preview(ctx.session.id)
      members = by_member(preview.members)

      assert members[a.id].credit_balance == 20_000
      assert members[a.id].credit_applied == 20_000
      assert members[a.id].amount_due == 25_000
      assert members[b.id].credit_balance == 0
      assert members[b.id].credit_applied == 0
      assert members[b.id].amount_due == 45_000
    end

    test "a session that cannot be billed returns every problem" do
      ctx = example1()
      cost_item_fixture(ctx.session, amount: 5_000, paid_by: ctx.host, members: [])

      Repo.update_all(Billing.Participant, set: [attended: false])

      assert {:error, {:invalid, errors}} = Billing.preview(ctx.session.id)
      assert Enum.all?(errors, &match?({:item_without_bearers, _}, &1))
      assert length(errors) == 4
    end

    test "only drafts and known sessions" do
      ctx = rounding_example()
      assert {:error, :not_found} = Billing.preview(0)

      Repo.update_all(Session, set: [status: "issued"])
      assert {:error, %TransitionError{from: "issued"}} = Billing.preview(ctx.session.id)
    end
  end

  describe "issue/2" do
    test "credit for the fronting host: bill Rp0 paid via credit, host balance +Rp305.000" do
      ctx = example1()
      result = issue!(ctx)

      bills = by_member(result.bills)
      host_bill = bills[ctx.host.id]

      assert {host_bill.share, host_bill.credit_applied, host_bill.amount_due} ==
               {45_000, 45_000, 0}

      assert host_bill.status == "paid"
      assert host_bill.paid_via == "credit"
      assert host_bill.paid_txn_id == nil
      assert host_bill.paid_at == @t0

      for m <- ctx.others do
        assert %{status: "unpaid", share: 45_000, credit_applied: 0, amount_due: 45_000} =
                 bills[m.id]
      end

      balances = Ledger.balances(ctx.group.id)
      assert balances.members[ctx.host.id] == 305_000
      assert balances.members[hd(ctx.others).id] == -45_000
      assert balances.kas == 0
      assert Enum.sum(Map.values(balances.members)) + balances.kas == 0
    end

    test "moves the session to issued with its txn, and posts exactly one session_billed txn" do
      ctx = example1()
      result = issue!(ctx)

      assert result.replayed == false
      assert result.txn.kind == "session_billed"
      assert %Session{status: "issued", issue_txn_id: txn_id} = Repo.get!(Session, ctx.session.id)
      assert txn_id == result.txn.id
      assert [%{id: ^txn_id}] = Ledger.txns(ctx.group.id)
      assert length(result.bills) == 10
    end

    test "writes one session.issue audit row for the host, none on a replay" do
      ctx = example1()
      result = issue!(ctx)
      issue!(ctx)

      assert [row] =
               Repo.all(from a in Petepete.Ledger.AuditLog, where: a.action == "session.issue")

      assert row.subject_type == "session" and row.subject_id == ctx.session.id
      assert row.group_id == ctx.group.id and row.actor_user_id == ctx.user.id
      assert row.metadata["txn_id"] == result.txn.id
      assert length(row.metadata["bill_ids"]) == 10
    end

    test "rounding remainder goes to the kas" do
      ctx = rounding_example()
      issue!(ctx, actor: {:host, ctx.user.id}, idempotency_key: "k1")

      balances = Ledger.balances(ctx.group.id)
      assert balances.kas == 2_000
      assert balances.members[ctx.host.id] == 100_000 - 34_000
      assert Enum.map(tl(ctx.members), &balances.members[&1.id]) == [-34_000, -34_000]
    end

    test "applies credit from the balance the ledger saw just before posting" do
      ctx = example1()
      member = hd(ctx.others)
      credit!(ctx, member, 20_000)

      result = issue!(ctx)
      bill = by_member(result.bills)[member.id]

      assert {bill.share, bill.credit_applied, bill.amount_due} == {45_000, 20_000, 25_000}
      assert bill.status == "unpaid"
    end

    test "preview and issue agree on every share, and on credit when nothing moved" do
      ctx = example1()
      credit!(ctx, hd(ctx.others), 20_000)
      {:ok, preview} = Billing.preview(ctx.session.id)
      result = issue!(ctx)

      expected =
        for m <- preview.members, do: {m.member_id, m.share, m.credit_applied, m.amount_due}

      actual = for b <- result.bills, do: {b.member_id, b.share, b.credit_applied, b.amount_due}
      assert Enum.sort(expected) == Enum.sort(actual)
    end

    test "a payment arriving after the preview changes credit, never the shares" do
      ctx = example1()
      member = hd(ctx.others)
      {:ok, before} = Billing.preview(ctx.session.id)
      credit!(ctx, member, 45_000)

      result = issue!(ctx)
      bill = by_member(result.bills)[member.id]

      assert by_member(before.members)[member.id].amount_due == 45_000
      assert bill.share == by_member(before.members)[member.id].share
      assert bill.amount_due == 0
      assert bill.status == "paid"
    end

    test "the same key again returns the same txn and bills and posts nothing" do
      ctx = example1()
      first = issue!(ctx)
      again = issue!(ctx)

      assert again.replayed == true
      assert again.txn.id == first.txn.id
      assert Enum.map(again.bills, & &1.id) == Enum.map(first.bills, & &1.id)
      assert Enum.map(again.bills, & &1.pay_token) == Enum.map(first.bills, & &1.pay_token)
      assert length(Ledger.txns(ctx.group.id)) == 1
      assert Repo.aggregate(from(b in Bill, where: b.session_id == ^ctx.session.id), :count) == 10
    end

    test "another key on an issued session is refused and posts nothing" do
      ctx = example1()
      issue!(ctx)

      assert {:error, %TransitionError{from: "issued", to: "issued"}} =
               Billing.issue(ctx.session.id, Keyword.put(ctx.opts, :idempotency_key, "other"))

      assert length(Ledger.txns(ctx.group.id)) == 1
    end

    test "cancelled sessions are refused" do
      ctx = rounding_example()
      {:ok, _} = Billing.cancel_session(ctx.session.id)

      assert {:error, %TransitionError{from: "cancelled"}} =
               Billing.issue(ctx.session.id, actor: {:host, ctx.user.id}, idempotency_key: "k")
    end

    test "a key whose txn was cancelled cannot issue the session again" do
      ctx = rounding_example()
      opts = [actor: {:host, ctx.user.id}, idempotency_key: "old"]
      issue!(ctx, opts)

      # What Billing.void_issue/2 will do to the rows: bills void, session back to draft.
      Repo.update_all(Bill, set: [status: "void"])
      Repo.update_all(Session, set: [status: "draft"])

      assert {:error, :idempotency_key_conflict} = Billing.issue(ctx.session.id, opts)
      assert length(Ledger.txns(ctx.group.id)) == 1
      assert Repo.aggregate(Bill, :count) == 3
    end

    test "a failure after the ledger posted rolls back the txn, the bills and the status" do
      ctx = rounding_example()
      # A live bill for one participant already exists: the third insert violates the
      # (session, member) uniqueness, after the ledger txn was posted.
      bill_fixture(ctx.session, List.last(ctx.members))

      assert_raise Ecto.ConstraintError, fn ->
        Billing.issue(ctx.session.id, actor: {:host, ctx.user.id}, idempotency_key: "k")
      end

      assert Ledger.txns(ctx.group.id) == []
      assert Repo.get!(Session, ctx.session.id).status == "draft"
      assert Repo.aggregate(Bill, :count) == 1
    end

    test "invalid sessions post nothing" do
      ctx = example1()
      Repo.update_all(Billing.Participant, set: [attended: false])

      assert {:error, {:invalid, [_ | _]}} = Billing.issue(ctx.session.id, ctx.opts)
      assert Ledger.txns(ctx.group.id) == []
      assert Repo.get!(Session, ctx.session.id).status == "draft"
    end

    test "an attendee who bears nothing gets no bill" do
      ctx = rounding_example()
      extra = member_fixture(ctx.group, role: "member")
      attendance_fixture(ctx.session, extra)
      Repo.delete_all(Billing.CostItem)
      cost_item_fixture(ctx.session, amount: 90_000, paid_by: ctx.host, members: ctx.members)

      result = issue!(ctx, actor: {:host, ctx.user.id}, idempotency_key: "k")

      refute extra.id in Enum.map(result.bills, & &1.member_id)
      assert length(result.bills) == 3
    end

    test "pay tokens are url-safe, at least 128 bits, unique, and expire 30 days after issue" do
      ctx = example1()
      result = issue!(ctx)
      tokens = Enum.map(result.bills, & &1.pay_token)

      assert length(Enum.uniq(tokens)) == 10

      for token <- tokens do
        assert token =~ ~r/\A[A-Za-z0-9_-]+\z/
        assert byte_size(Base.url_decode64!(token, padding: false)) >= 16
      end

      expected = DateTime.add(@t0, 30, :day)
      assert Enum.all?(result.bills, &(&1.token_expires_at == expected))
    end

    test "a blank or missing key is refused before anything is read" do
      ctx = rounding_example()
      actor = {:host, ctx.user.id}

      assert {:error, :idempotency_key_required} = Billing.issue(ctx.session.id, actor: actor)

      assert {:error, :idempotency_key_required} =
               Billing.issue(ctx.session.id, actor: actor, idempotency_key: "  ")
    end

    test "unknown sessions" do
      assert {:error, :not_found} = Billing.issue(0, actor: {:host, 1}, idempotency_key: "k")
    end
  end
end
