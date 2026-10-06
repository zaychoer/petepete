defmodule PetepeteWeb.WebhookControllerTest do
  # Not async: the crash test sets an application-wide fault hook.
  use PetepeteWeb.ConnCase, async: false

  import Ecto.Query
  import Petepete.BillingScenario

  alias Petepete.{Billing, Ledger, Repo}
  alias Petepete.Billing.Session
  alias Petepete.Ledger.Txn
  alias Petepete.Payments.Gateway.Fake
  alias Petepete.Payments.{GatewayNotification, PaymentAttempt}

  setup do
    ctx = issued()
    bill = ctx.bills[ctx.a.id]
    on_exit(fn -> Application.delete_env(:petepete, :webhook_fault_hook) end)
    {:ok, Map.merge(ctx, %{bill: bill, attempt: attempt!(bill)})}
  end

  defp webhook(conn, attrs, opts \\ []) do
    {headers, body} = Fake.webhook(attrs, opts)

    conn = put_req_header(conn, "content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    post(conn, ~p"/api/webhooks/fake", body)
  end

  defp notif(ctx, status, extra \\ %{}) do
    Map.merge(
      %{
        provider_txn_id: "txn-1",
        external_id: ctx.attempt.external_id,
        status: status,
        paid_amount: ctx.attempt.gross_amount
      },
      extra
    )
  end

  defp gateway_txns(ctx),
    do:
      Repo.aggregate(
        from(t in Txn,
          where: t.group_id == ^ctx.group.id and t.kind == "gateway_payment_received"
        ),
        :count
      )

  defp txns(ctx), do: Repo.aggregate(from(t in Txn, where: t.group_id == ^ctx.group.id), :count)
  defp attempt(ctx), do: Repo.get!(PaymentAttempt, ctx.attempt.id)
  defp notifications, do: Repo.all(from n in GatewayNotification, order_by: n.id)

  test "a paid webhook pays the bill once; the same delivery again posts nothing more", ctx do
    assert %{"outcome" => "paid"} = ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(200)
    assert %{"outcome" => "paid"} = ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(200)

    bill = reload(ctx.bill)
    assert bill.status == "paid" and bill.paid_via == "gateway"
    assert gateway_txns(ctx) == 1

    assert bill.paid_txn_id ==
             Repo.one(from t in Txn, where: t.kind == "gateway_payment_received", select: t.id)

    assert attempt(ctx).status == "paid"
    assert attempt(ctx).paid_amount == ctx.attempt.gross_amount
    assert [%{outcome: "paid", processed_at: %DateTime{}}] = notifications()
    assert balance(ctx, ctx.a) == 0
  end

  test "pending then paid are two notifications; only the paid one posts", ctx do
    assert %{"outcome" => "pending"} =
             ctx.conn |> webhook(notif(ctx, :pending, %{paid_amount: nil})) |> json_response(200)

    assert attempt(ctx).status == "pending"
    assert gateway_txns(ctx) == 0

    assert %{"outcome" => "paid"} = ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(200)

    assert [%{provider_status: "pending"}, %{provider_status: "paid"}] = notifications()
    assert gateway_txns(ctx) == 1
  end

  test "expired and failed only update the attempt", ctx do
    before = txns(ctx)

    assert %{"outcome" => "expired"} =
             ctx.conn |> webhook(notif(ctx, :expired, %{paid_amount: nil})) |> json_response(200)

    assert attempt(ctx).status == "expired"
    assert reload(ctx.bill).status == "unpaid"
    assert txns(ctx) == before

    other = attempt!(ctx.bill, seq: 2)

    assert %{"outcome" => "failed"} =
             ctx.conn
             |> webhook(
               notif(ctx, :failed, %{
                 external_id: other.external_id,
                 paid_amount: nil,
                 provider_txn_id: "txn-2"
               })
             )
             |> json_response(200)

    assert Repo.get!(PaymentAttempt, other.id).status == "failed"
  end

  test "a wrong signature is rejected and nothing is written", ctx do
    before = txns(ctx)

    assert %{"error" => "invalid_signature"} =
             ctx.conn |> webhook(notif(ctx, :paid), signature: "nope") |> json_response(401)

    assert notifications() == []
    assert txns(ctx) == before
    assert reload(ctx.bill).status == "unpaid"
  end

  test "a body altered after signing is rejected", ctx do
    {headers, _body} = Fake.webhook(notif(ctx, :paid))
    {_, forged} = Fake.webhook(notif(ctx, :paid, %{paid_amount: 1}))

    conn = put_req_header(ctx.conn, "content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    assert post(conn, ~p"/api/webhooks/fake", forged).status == 401
  end

  test "a provider other than the configured gateway is 404", ctx do
    {headers, body} = Fake.webhook(notif(ctx, :paid))
    conn = put_req_header(ctx.conn, "content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    assert conn |> post(~p"/api/webhooks/midtrans", body) |> json_response(404)
    assert notifications() == []
  end

  test "a verified but unreadable payload is 400", ctx do
    body = Jason.encode!(%{"hello" => "world"})
    {headers, _} = Fake.webhook(notif(ctx, :paid))

    signature =
      :crypto.mac(:hmac, :sha256, "fake-webhook-secret", body) |> Base.encode16(case: :lower)

    [{name, _}] = headers

    conn =
      ctx.conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header(name, signature)

    assert conn |> post(~p"/api/webhooks/fake", body) |> json_response(400)
  end

  test "an amount that differs puts the bill in needs_review and posts nothing", ctx do
    before = txns(ctx)
    paid = ctx.attempt.gross_amount - 1000

    assert %{"outcome" => "needs_review"} =
             ctx.conn |> webhook(notif(ctx, :paid, %{paid_amount: paid})) |> json_response(200)

    assert reload(ctx.bill).status == "needs_review"
    assert txns(ctx) == before
    assert attempt(ctx).paid_amount == paid
    assert attempt(ctx).status == "pending"
  end

  test "a payment on a void bill is credit and the bill stays void", ctx do
    {:ok, _} = Billing.void_issue(ctx.session.id, opts(ctx, reason: "salah"))
    before = balance(ctx, ctx.a)

    assert %{"outcome" => "overpaid"} =
             ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(200)

    assert reload(ctx.bill).status == "void"
    assert balance(ctx, ctx.a) == before + ctx.bill.amount_due
    assert gateway_txns(ctx) == 1
  end

  test "paying a bill that is already paid becomes credit (overpaid)", ctx do
    ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(200)
    other = attempt!(ctx.bill, seq: 2)

    assert %{"outcome" => "overpaid"} =
             ctx.conn
             |> webhook(
               notif(ctx, :paid, %{
                 external_id: other.external_id,
                 provider_txn_id: "txn-2",
                 paid_amount: other.gross_amount
               })
             )
             |> json_response(200)

    assert reload(ctx.bill).status == "paid"
    assert balance(ctx, ctx.a) == ctx.bill.amount_due
    assert gateway_txns(ctx) == 2
  end

  test "an unknown external_id is 200 with outcome unknown", ctx do
    before = txns(ctx)

    assert %{"outcome" => "unknown"} =
             ctx.conn
             |> webhook(notif(ctx, :paid, %{external_id: "999999-1"}))
             |> json_response(200)

    assert [%{outcome: "unknown", processed_at: %DateTime{}}] = notifications()
    assert txns(ctx) == before
  end

  @tag :capture_log
  test "a crash after the ledger post rolls everything back; the retry posts exactly once", ctx do
    Application.put_env(:petepete, :webhook_fault_hook, fn -> raise "boom" end)

    assert %{"error" => "processing_failed"} =
             ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(500)

    assert notifications() == []
    assert gateway_txns(ctx) == 0
    assert reload(ctx.bill).status == "unpaid"
    assert attempt(ctx).status == "pending"
    assert attempt(ctx).paid_amount == nil

    Application.delete_env(:petepete, :webhook_fault_hook)
    assert %{"outcome" => "paid"} = ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(200)
    assert gateway_txns(ctx) == 1
    assert [%{processed_at: %DateTime{}}] = notifications()
  end

  test "the session becomes Selesai when the last bill is paid by webhook", ctx do
    session = fn -> Billing.session_progress(Repo.get!(Session, ctx.session.id)) end
    assert session.() == :issued

    ctx.conn |> webhook(notif(ctx, :paid)) |> json_response(200)
    assert session.() == :issued

    bill_b = ctx.bills[ctx.b.id]
    attempt_b = attempt!(bill_b)

    ctx.conn
    |> webhook(%{
      provider_txn_id: "txn-b",
      external_id: attempt_b.external_id,
      status: :paid,
      paid_amount: attempt_b.gross_amount
    })
    |> json_response(200)

    assert session.() == :settled
    assert Ledger.balances(ctx.group.id).members[ctx.b.id] == 0
  end
end
