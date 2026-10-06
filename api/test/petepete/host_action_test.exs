defmodule Petepete.HostActionTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.{Actor, HostAction, Ledger}
  alias Petepete.Ledger.{AuditLog, Txn}
  alias Petepete.Ledger.Event.Settlement

  # Host actions still writing their own audit row; each moves onto HostAction.run/4 and
  # leaves this list. Nothing else may call the low-level writer.
  @unmigrated [
    "lib/petepete/billing/cash_payments.ex",
    "lib/petepete/billing/invoicing.ex",
    "lib/petepete/billing/voiding.ex",
    "lib/petepete/payments/withdrawals.ex",
    "lib/petepete_web/controllers/payout_account_controller.ex"
  ]

  setup do
    group = group_fixture()
    {user, host} = host_fixture(group)
    a = member_fixture(group)
    %{group: group, user: user, host: host, a: a, actor: host_actor(group, host)}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp settle(ctx, key \\ "k-#{uniq()}") do
    HostAction.run(ctx.actor, ctx.group.id, "settlement.record", fn ->
      event = %Settlement{
        idempotency_key: key,
        group_id: ctx.group.id,
        payer_member_id: ctx.a.id,
        payee_member_id: ctx.host.id,
        amount: 10
      }

      with {:ok, %{txn: txn, replayed: replayed} = res} <- Ledger.record(ctx.actor, event) do
        {:ok, res, %{subject: {"txn", txn.id}, metadata: %{"amount" => 10}, replayed: replayed}}
      end
    end)
  end

  test "returns the action's result and writes one audit row with the actor, subject and metadata",
       ctx do
    assert {:ok, %{txn: txn, replayed: false}} = settle(ctx)

    assert [row] = Repo.all(AuditLog)

    assert {row.group_id, row.actor_user_id, row.action, row.subject_type, row.subject_id,
            row.metadata} ==
             {ctx.group.id, ctx.user.id, "settlement.record", "txn", txn.id, %{"amount" => 10}}
  end

  test "an idempotent replay returns the result and writes no second audit row", ctx do
    assert {:ok, %{txn: first, replayed: false}} = settle(ctx, "same")
    assert {:ok, %{txn: again, replayed: true}} = settle(ctx, "same")

    assert again.id == first.id
    assert count(Txn) == 1
    assert count(AuditLog) == 1
  end

  test "{:error, reason} rolls the action back and writes no audit row", ctx do
    result =
      HostAction.run(ctx.actor, ctx.group.id, "settlement.record", fn ->
        {:ok, %{txn: txn}} =
          Ledger.record(ctx.actor, %Settlement{
            idempotency_key: "k-#{uniq()}",
            group_id: ctx.group.id,
            payer_member_id: ctx.a.id,
            payee_member_id: ctx.host.id,
            amount: 10
          })

        assert txn.id
        {:error, :boom}
      end)

    assert result == {:error, :boom}
    assert count(Txn) == 0
    assert count(AuditLog) == 0
  end

  test "a raise rolls the action back and propagates", ctx do
    assert_raise RuntimeError, "boom", fn ->
      HostAction.run(ctx.actor, ctx.group.id, "settlement.record", fn ->
        {:ok, _} =
          Ledger.record(ctx.actor, %Settlement{
            idempotency_key: "k-#{uniq()}",
            group_id: ctx.group.id,
            payer_member_id: ctx.a.id,
            payee_member_id: ctx.host.id,
            amount: 10
          })

        raise "boom"
      end)
    end

    assert count(Txn) == 0
    assert count(AuditLog) == 0
  end

  test "a failing audit write takes the action down with it", ctx do
    assert_raise Ecto.ConstraintError, fn ->
      # Unknown group violates audit_log's foreign key.
      HostAction.run(ctx.actor, -1, "settlement.record", fn ->
        {:ok, _} =
          Ledger.record(ctx.actor, %Settlement{
            idempotency_key: "k-#{uniq()}",
            group_id: ctx.group.id,
            payer_member_id: ctx.a.id,
            payee_member_id: ctx.host.id,
            amount: 10
          })

        {:ok, :done, %{subject: {"txn", 1}, metadata: %{}, replayed: false}}
      end)
    end

    assert count(Txn) == 0
  end

  test "refuses any Actor that is not a host", ctx do
    for actor <- [
          Actor.gateway(),
          %Actor{type: :system, user_id: ctx.user.id, member_id: ctx.host.id}
        ] do
      assert_raise FunctionClauseError, fn ->
        HostAction.run(actor, ctx.group.id, "settlement.record", fn ->
          flunk("the action must not run")
        end)
      end
    end

    assert count(AuditLog) == 0
  end

  test "refuses a host Actor without a user to attribute the audit row to", ctx do
    actor = %Actor{type: :host, user_id: nil, member_id: ctx.host.id}

    assert_raise FunctionClauseError, fn ->
      HostAction.run(actor, ctx.group.id, "x.y", fn ->
        {:ok, :done, %{subject: {"txn", 1}, metadata: %{}, replayed: false}}
      end)
    end

    assert count(AuditLog) == 0
  end

  test "only HostAction writes audit rows (besides the host actions not yet migrated)" do
    callers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ ~r/\bAudit\.record\(/))
      |> Enum.sort()

    assert callers -- @unmigrated == ["lib/petepete/host_action.ex"]
  end
end
