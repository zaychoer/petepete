defmodule Petepete.Billing.InvoicingConcurrencyTest do
  # Needs real, committed transactions on separate connections, so it runs outside the sandbox
  # and wipes what it wrote (ledger rows are append-only; TRUNCATE bypasses the row triggers).
  use ExUnit.Case, async: false

  import Petepete.Fixtures

  alias Petepete.{Billing, Ledger, Repo}
  alias Petepete.Billing.{Bill, TransitionError}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.query!(
        "TRUNCATE ledger_entries, ledger_txns, bills, session_participants, cost_item_members, " <>
          "cost_items, sessions, events, group_members, groups, users CASCADE"
      )

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    group = group_fixture()
    {_user, host} = host_fixture(group)
    others = for _ <- 1..3, do: member_fixture(group, role: "member")
    session = session_fixture(event_fixture(group))
    for m <- [host | others], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 120_000, paid_by: host)

    {:ok, group: group, session: session, actor: host_actor(group, host)}
  end

  defp issue_concurrently(ctx, keys) do
    keys
    |> Enum.map(fn key ->
      Task.async(fn ->
        Billing.issue(ctx.session.id, actor: ctx.actor, idempotency_key: key)
      end)
    end)
    |> Task.await_many(10_000)
  end

  test "two issues with different keys: one wins, the other sees a session that is no longer draft",
       ctx do
    results = issue_concurrently(ctx, ["a", "b"])

    assert [{:ok, %{replayed: false}}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, %TransitionError{from: "issued"}}] =
             Enum.reject(results, &match?({:ok, _}, &1))

    assert length(Ledger.txns(ctx.group.id)) == 1
    assert Repo.aggregate(Bill, :count) == 4
  end

  test "two issues with one key: one txn, one set of bills, the loser gets the same answer",
       ctx do
    results = issue_concurrently(ctx, ["same", "same"])

    assert [{:ok, %{replayed: false} = first}, {:ok, %{replayed: true} = second}] =
             Enum.sort_by(results, fn {:ok, r} -> r.replayed end)

    assert first.txn.id == second.txn.id
    assert Enum.map(first.bills, & &1.id) == Enum.map(second.bills, & &1.id)
    assert length(Ledger.txns(ctx.group.id)) == 1
    assert Repo.aggregate(Bill, :count) == 4
  end
end
