defmodule Petepete.LedgerConcurrencyTest do
  # Needs real, committed transactions on separate connections, so it runs outside the sandbox
  # and wipes what it wrote (ledger rows are append-only; TRUNCATE bypasses the row triggers).
  use ExUnit.Case, async: false

  import Petepete.Fixtures

  alias Petepete.Ledger
  alias Petepete.Ledger.Event.{KasSpend, Settlement}
  alias Petepete.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.query!(
        "TRUNCATE ledger_entries, ledger_txns, payout_accounts, group_members, groups, users CASCADE"
      )

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    user = user!()
    group = group!()
    host = member!(group, user_id: user.id, role: "host")
    other = member!(group)
    {:ok, g: group.id, actor: {:host, user.id}, host: host.id, other: other.id}
  end

  defp concurrently(fun, n) do
    1..n |> Enum.map(fn _ -> Task.async(fn -> Repo.transaction(fun) end) end) |> Task.await_many()
  end

  test "two processes with one key and one group post exactly one txn", ctx do
    ev = %Settlement{
      idempotency_key: "dup",
      group_id: ctx.g,
      payer_member_id: ctx.host,
      payee_member_id: ctx.other,
      amount: 5_000
    }

    results = concurrently(fn -> Ledger.record(ctx.actor, ev) end, 2)

    assert [{:ok, {:ok, %{replayed: false} = a}}, {:ok, {:ok, %{replayed: true} = b}}] =
             Enum.sort_by(results, fn {:ok, {:ok, r}} -> r.replayed end)

    assert a.txn.id == b.txn.id
    assert length(Ledger.txns(ctx.g)) == 1
  end

  test "the group lock stops two kas spends from overdrawing the kas", ctx do
    {:ok, {:ok, _}} =
      Repo.transaction(fn ->
        Ledger.record(ctx.actor, %Petepete.Ledger.Event.SessionBilled{
          idempotency_key: "bill",
          group_id: ctx.g,
          session_id: 1,
          shares: [{ctx.other, 100}],
          fronted: [],
          kas_remainder: 100
        })
      end)

    spend = fn n ->
      Repo.transaction(fn ->
        Ledger.record(ctx.actor, %KasSpend{
          idempotency_key: "spend#{n}",
          group_id: ctx.g,
          member_id: ctx.other,
          amount: 60
        })
      end)
    end

    results = [1, 2] |> Enum.map(&Task.async(fn -> spend.(&1) end)) |> Task.await_many()

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:error, :insufficient_kas}}, &1)) == 1
    assert Ledger.balances(ctx.g).kas == 40
  end
end
