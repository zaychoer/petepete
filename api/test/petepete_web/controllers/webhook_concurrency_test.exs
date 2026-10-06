defmodule PetepeteWeb.WebhookConcurrencyTest do
  # Real, committed transactions on separate connections, outside the sandbox (see
  # Petepete.Billing.CommandsConcurrencyTest).
  use PetepeteWeb.ConnCase, async: false

  import Ecto.Query
  import Petepete.BillingScenario

  alias Petepete.Repo
  alias Petepete.Ledger.Txn
  alias Petepete.Payments.Gateway.Fake
  alias Petepete.Payments.GatewayNotification

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.query!(
        "TRUNCATE audit_log, gateway_notifications, ledger_entries, ledger_txns, " <>
          "payment_attempts, bills, session_participants, cost_item_members, cost_items, " <>
          "sessions, events, payout_accounts, group_members, groups, users CASCADE"
      )

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    ctx = issued()
    {:ok, Map.put(ctx, :attempt, attempt!(ctx.bills[ctx.a.id]))}
  end

  test "two simultaneous deliveries of the same notification post one txn", ctx do
    {headers, body} =
      Fake.webhook(%{
        provider_txn_id: "txn-race",
        external_id: ctx.attempt.external_id,
        status: :paid,
        paid_amount: ctx.attempt.gross_amount
      })

    deliver = fn ->
      conn = put_req_header(build_conn(), "content-type", "application/json")
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      post(conn, ~p"/api/webhooks/fake", body).status
    end

    statuses =
      for _ <- 1..2, do: Task.async(deliver)

    assert Task.await_many(statuses, 10_000) == [200, 200]

    assert Repo.aggregate(from(t in Txn, where: t.kind == "gateway_payment_received"), :count) ==
             1

    assert [%{outcome: "paid"}] = Repo.all(GatewayNotification)
  end
end
