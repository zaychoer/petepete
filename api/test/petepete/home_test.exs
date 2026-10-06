defmodule Petepete.HomeTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.{Home, Ledger, Repo}
  alias Petepete.Billing.{CostItem, Participant}
  alias Petepete.Ledger.Event.SessionBilled

  # Tuesday 2026-10-06 10:00 WIB.
  @now ~U[2026-10-06 03:00:00Z]

  setup do
    group = group!()
    event = event!(group, name: "Futsal Kamis", type: "recurring")
    %{group: group, event: event, host: member!(group, role: "host"), a: member!(group)}
  end

  defp add_cost(session, amount),
    do: Repo.insert!(%CostItem{session_id: session.id, category: "lapangan", amount: amount})

  test "next session is the earliest live one from the start of today in WIB",
       %{group: group, event: event, a: a} do
    session!(event, starts_at: ~U[2026-10-05 12:00:00Z])
    session!(event, starts_at: ~U[2026-10-07 12:00:00Z], status: "cancelled")
    # Today 00:30 WIB is still "today" even though it has begun: 2026-10-05 17:30 UTC.
    today = session!(event, starts_at: ~U[2026-10-05 17:30:00Z])
    session!(event, starts_at: ~U[2026-10-13 12:00:00Z])
    add_cost(today, 100_000)
    add_cost(today, 20_000)
    Repo.insert!(%Participant{session_id: today.id, member_id: a.id, attended: true})

    Repo.insert!(%Participant{
      session_id: today.id,
      member_id: member!(group).id,
      attended: false
    })

    assert %{next_session: card} = Home.for_group(group.id, @now)

    assert %{
             event_name: "Futsal Kamis",
             cost_total: 120_000,
             attended_count: 1,
             progress: :draft
           } = card

    assert card.session.id == today.id
  end

  test "no session ahead gives no card, an empty kas and no bills", %{group: group} do
    assert %{next_session: nil, kas_balance: 0, unpaid_bills: [], needs_review_bills: []} =
             Home.for_group(group.id, @now)
  end

  test "lists unpaid and needs_review bills apart, without paid or void ones", %{
    group: group,
    event: event,
    a: a
  } do
    older = session!(event, starts_at: ~U[2026-09-29 12:00:00Z], status: "issued")
    newer = session!(event, starts_at: ~U[2026-10-01 12:00:00Z], status: "issued")
    b = member!(group)
    c = member!(group)

    newer_bill = bill!(newer, a, amount_due: 30_000)
    older_bill = bill!(older, a, amount_due: 20_000)
    review = bill!(newer, b, amount_due: 40_000, status: "needs_review")
    bill!(newer, c, status: "paid", amount_due: 0)
    bill!(older, c, status: "void")

    home = Home.for_group(group.id, @now)

    assert Enum.map(home.unpaid_bills, & &1.id) == [older_bill.id, newer_bill.id]
    assert Enum.map(home.needs_review_bills, & &1.id) == [review.id]

    assert %{
             member_id: member_id,
             member_name: name,
             amount_due: 20_000,
             session_id: session_id,
             session_starts_at: ~U[2026-09-29 12:00:00Z],
             event_name: "Futsal Kamis"
           } = hd(home.unpaid_bills)

    assert {member_id, name, session_id} == {a.id, a.display_name, older.id}
    refute Enum.any?(home.unpaid_bills, &Map.has_key?(&1, :pay_token))
  end

  test "kas balance comes from the ledger", %{group: group, host: host, a: a} do
    {:ok, {:ok, _}} =
      Repo.transaction(fn ->
        Ledger.record(
          {:host, user!().id},
          %SessionBilled{
            idempotency_key: "k-#{uniq()}",
            group_id: group.id,
            session_id: 1,
            shares: [{a.id, 34_000}, {host.id, 34_000}, {member!(group).id, 34_000}],
            fronted: [{host.id, 100_000}],
            kas_remainder: 2_000
          }
        )
      end)

    assert Home.for_group(group.id, @now).kas_balance == 2_000
  end
end
