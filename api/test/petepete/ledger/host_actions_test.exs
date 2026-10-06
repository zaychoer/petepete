defmodule Petepete.Ledger.HostActionsTest do
  use Petepete.DataCase, async: true

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.Actor
  alias Petepete.Ledger.{AuditLog, HostActions, Txn}

  setup do
    group = group_fixture()
    {user, host} = host_fixture(group)
    a = member_fixture(group)
    %{g: group, user: user, host: host, a: a, actor: host_actor(group, host)}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp settle(ctx, key) do
    HostActions.record_settlement(ctx.actor, ctx.g.id, key, %{
      payer_member_id: ctx.a.id,
      payee_member_id: ctx.host.id,
      amount: 25_000,
      note: "ganti air"
    })
  end

  defp fund_kas(ctx) do
    {:ok, {:ok, _}} =
      Repo.transaction(fn ->
        Petepete.Ledger.record(ctx.actor, %Petepete.Ledger.Event.SessionBilled{
          idempotency_key: "fund-#{uniq()}",
          group_id: ctx.g.id,
          session_id: 1,
          shares: [{ctx.a.id, 5_000}],
          kas_remainder: 5_000
        })
      end)
  end

  test "settlement posts, audits once as settlement.record and answers {txn, replayed}", ctx do
    assert {:ok, %{txn: txn, replayed: false} = res} = settle(ctx, "k1")
    assert Map.keys(res) |> Enum.sort() == [:replayed, :txn]

    assert [row] = Repo.all(AuditLog)

    assert {row.actor_user_id, row.action, row.subject_type, row.subject_id} ==
             {ctx.user.id, "settlement.record", "txn", txn.id}

    assert row.metadata == %{
             "payer_member_id" => ctx.a.id,
             "payee_member_id" => ctx.host.id,
             "amount" => 25_000,
             "note" => "ganti air"
           }
  end

  test "a replayed settlement answers replayed: true and writes no second audit row", ctx do
    assert {:ok, %{txn: first, replayed: false}} = settle(ctx, "k1")
    assert {:ok, %{txn: again, replayed: true}} = settle(ctx, "k1")

    assert again.id == first.id
    assert count(Txn) == 1
    assert count(AuditLog) == 1
  end

  test "a rejected action leaves neither a txn nor an audit row", ctx do
    assert {:error, :insufficient_kas} =
             HostActions.record_kas_spend(ctx.actor, ctx.g.id, "k1", %{
               member_id: ctx.a.id,
               amount: 1
             })

    assert count(Txn) == 0
    assert count(AuditLog) == 0
  end

  test "kas spend audits as kas_spend.record", ctx do
    fund_kas(ctx)

    assert {:ok, %{txn: txn, replayed: false}} =
             HostActions.record_kas_spend(ctx.actor, ctx.g.id, "k2", %{
               member_id: ctx.host.id,
               amount: 2_000,
               note: "air"
             })

    assert [%{action: "kas_spend.record", subject_id: id}] =
             Repo.all(from a in AuditLog, where: a.action == "kas_spend.record")

    assert id == txn.id
  end

  test "correction reverses a settlement and audits as txn.correct", ctx do
    {:ok, %{txn: original}} = settle(ctx, "k1")

    assert {:ok, %{txn: undo, replayed: false}} =
             HostActions.correct(ctx.actor, ctx.g.id, "k2", original.id, "salah")

    assert undo.reverses_txn_id == original.id

    assert [row] = Repo.all(from a in AuditLog, where: a.action == "txn.correct")

    assert {row.subject_id, row.metadata} ==
             {undo.id, %{"original_txn_id" => original.id, "reason" => "salah"}}

    assert {:error, :already_reversed} =
             HostActions.correct(ctx.actor, ctx.g.id, "k3", original.id, "lagi")
  end

  test "the gateway is not a host actor", ctx do
    assert_raise FunctionClauseError, fn -> settle(%{ctx | actor: Actor.gateway()}, "k1") end
  end
end
