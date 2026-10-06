defmodule Petepete.Ledger.HostActionsTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.Ledger.{Audit, AuditLog, HostActions, Txn}
  alias Petepete.Ledger.Event.Settlement

  setup do
    user = user_fixture()
    group = group_fixture()
    host = member_fixture(group, user_id: user.id, role: "host")
    a = member_fixture(group)
    %{g: group, user: user, host: host, a: a}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  test "a rejected action leaves neither a txn nor an audit row", ctx do
    assert {:error, :insufficient_kas} =
             HostActions.record_kas_spend(ctx.g.id, ctx.user.id, "k1", %{
               member_id: ctx.a.id,
               amount: 1
             })

    assert count(Txn) == 0
    assert count(AuditLog) == 0
  end

  test "the audit row rolls back with the transaction it was written in", ctx do
    {:error, :boom} =
      Repo.transaction(fn ->
        Audit.record(ctx.g.id, ctx.user.id, "x.y", {"txn", 1}, %{})
        Repo.rollback(:boom)
      end)

    assert count(AuditLog) == 0
  end

  test "an audit write failing after the ledger post takes the txn down with it", ctx do
    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn ->
        {:ok, _} =
          Petepete.Ledger.record({:host, ctx.user.id}, %Settlement{
            idempotency_key: "k2",
            group_id: ctx.g.id,
            payer_member_id: ctx.a.id,
            payee_member_id: ctx.host.id,
            amount: 10
          })

        # Unknown group violates audit_log's foreign key.
        Audit.record(-1, ctx.user.id, "settlement.record", {"txn", 1}, %{})
      end)
    end

    assert count(Txn) == 0
  end

  test "Audit.record refuses to run outside a transaction", ctx do
    assert_raise ArgumentError, fn -> Audit.record(ctx.g.id, ctx.user.id, "x", {"txn", 1}) end
  end
end
