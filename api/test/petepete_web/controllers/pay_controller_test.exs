defmodule PetepeteWeb.PayControllerTest do
  # Not async: the gateway-error tests change the fake gateway's application config.
  use PetepeteWeb.ConnCase, async: false

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.{Billing, Clock, Contract, FakeGateway, Repo}
  alias Petepete.Billing.Bill
  alias Petepete.Groups.Member
  alias Petepete.Payments.PaymentAttempt

  @phones ["6281234500001", "6281234500002", "6281234500003"]

  setup do
    Clock.freeze(~U[2026-10-06 03:00:00Z])

    group = group_fixture(name: "Futsal Kamis")
    host_user = user_fixture()
    host = member_fixture(group, role: "host", user: host_user)
    others = for _ <- 1..2, do: member_fixture(group, role: "member")

    for {m, phone} <- Enum.zip([host | others], @phones) do
      m |> Ecto.Changeset.change(phone: phone) |> Repo.update!()
    end

    session = session_fixture(event_fixture(group), starts_at: ~U[2026-10-06 03:00:00Z])
    for m <- [host | others], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 100_000, paid_by: host, label: "Sewa lapangan")

    {:ok, %{bills: bills}} =
      Billing.issue(session.id,
        actor: host_actor(group, host),
        idempotency_key: "issue-#{uniq()}"
      )

    bill = Enum.find(bills, &(&1.member_id == hd(others).id))
    %{group: group, session: session, bill: bill, bills: bills, host: host}
  end

  defp attempts(bill), do: Repo.all(from a in PaymentAttempt, where: a.bill_id == ^bill.id)

  describe "GET /api/pay/:token" do
    test "shows the bill without any phone number", %{conn: conn, bill: bill} do
      conn = get(conn, ~p"/api/pay/#{bill.pay_token}")
      body = json_response(conn, 200)
      Contract.check!("pay_page.unpaid", conn)

      assert %{
               "group_name" => "Futsal Kamis",
               "session_date" => "2026-10-06",
               "status" => "unpaid",
               "status_label" => "Belum bayar",
               "share" => 34_000,
               "credit_applied" => 0,
               "amount_due" => 34_000,
               "token_expired" => false,
               "can_pay" => true,
               "attempt" => nil,
               "attempt_expired" => false,
               "rounding" => 667,
               "lines" => [%{"label" => "Sewa lapangan", "amount" => 33_333}]
             } = body

      assert [
               %{"method" => "qris", "fee" => qris_fee, "gross_amount" => qris_gross},
               %{"method" => "va", "fee" => 4_440, "gross_amount" => 38_440},
               %{"method" => "ewallet"}
             ] = body["methods"]

      assert qris_gross == 34_000 + qris_fee
      assert qris_fee > 0

      encoded = Jason.encode!(body)
      for phone <- @phones, do: refute(encoded =~ phone)
    end

    test "an unknown token is 404", %{conn: conn} do
      conn = get(conn, ~p"/api/pay/nope")

      assert %{"error" => "not_found", "message" => message} = body = json_response(conn, 404)
      assert is_binary(message)
      # The same keys as the Fallback's not_found, so clients parse one shape.
      assert Map.keys(body) == ["error", "message"]
    end

    test "a void bill shows only the cancelled message", %{conn: conn, bill: bill} do
      bill |> Ecto.Changeset.change(status: "void") |> Repo.update!()

      conn = get(conn, ~p"/api/pay/#{bill.pay_token}")
      body = json_response(conn, 200)
      Contract.check!("pay_page.void", conn)

      assert %{
               "status" => "void",
               "status_label" => "Dibatalkan",
               "message" => "Tagihan dibatalkan",
               "can_pay" => false
             } = body

      refute Map.has_key?(body, "amount_due")
      assert Map.get(body, "methods") == nil
    end

    test "a bill waiting for the host's check shows the review message", %{
      conn: conn,
      bill: bill
    } do
      bill |> Ecto.Changeset.change(status: "needs_review") |> Repo.update!()

      conn = get(conn, ~p"/api/pay/#{bill.pay_token}")
      Contract.check!("pay_page.needs_review", conn)

      assert %{
               "status" => "needs_review",
               "status_label" => "Perlu dicek",
               "message" => "Pembayaranmu lagi dicek host. Tunggu sebentar ya.",
               "can_pay" => false
             } = json_response(conn, 200)
    end

    test "shows the active attempt", %{conn: conn, bill: bill} do
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})

      conn = get(conn, ~p"/api/pay/#{bill.pay_token}")
      Contract.check!("pay_page.attempt", conn)

      assert %{"attempt" => %{"method" => "qris"}, "attempt_expired" => false} =
               json_response(conn, 200)
    end

    test "a paid bill stays visible after the link's expiry date", %{conn: conn, bill: bill} do
      bill |> Ecto.Changeset.change(status: "paid", paid_via: "cash") |> Repo.update!()
      Clock.advance(40 * 86_400)

      conn = get(conn, ~p"/api/pay/#{bill.pay_token}")
      Contract.check!("pay_page.paid", conn)

      assert %{"status" => "paid", "status_label" => "Lunas", "token_expired" => false} =
               json_response(conn, 200)
    end

    test "an expired link on an unpaid bill cannot be paid", %{conn: conn, bill: bill} do
      Clock.advance(31 * 86_400)

      assert %{"token_expired" => true, "can_pay" => false, "methods" => []} =
               conn |> get(~p"/api/pay/#{bill.pay_token}") |> json_response(200)
    end

    test "marks an overdue attempt expired and reports it", %{conn: conn, bill: bill} do
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      Clock.advance(3_601)

      conn = get(conn, ~p"/api/pay/#{bill.pay_token}")
      Contract.check!("pay_page.attempt_expired", conn)
      body = json_response(conn, 200)

      assert %{"attempt_expired" => true, "expired_method" => "qris", "attempt" => nil} = body
      assert [%{status: "expired"}] = attempts(bill)
    end
  end

  describe "POST /api/pay/:token/payment" do
    test "creates one attempt with the gateway fee and external_id <bill_id>-<seq>",
         %{conn: conn, bill: bill} do
      conn = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "va"})
      Contract.check!("payment_attempt.va", conn)
      body = json_response(conn, 201)

      assert %{
               "method" => "va",
               "amount_due" => 34_000,
               "fee" => 4_440,
               "gross_amount" => 38_440,
               "reused" => false,
               "action" => %{"type" => "va_number", "va_number" => _},
               "expires_at" => "2026-10-06T04:00:00Z"
             } = body

      assert [attempt] = attempts(bill)
      assert attempt.external_id == "#{bill.id}-1"
      assert attempt.seq == 1
      assert attempt.status == "pending"
      assert attempt.provider_ref == "fake-#{bill.id}-1"
      assert attempt.gross_amount == attempt.amount_due + attempt.fee
      refute Jason.encode!(body) =~ "6281234"
    end

    test "the same method again returns the active attempt", %{conn: conn, bill: bill} do
      first = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      second = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      # A reused attempt (200) has the shape of a new one (201): one sample for both.
      Contract.check!("payment_attempt.qris", first)
      Contract.check!("payment_attempt.qris", second)

      assert json_response(first, 201)["reused"] == false
      assert %{"reused" => true} = body = json_response(second, 200)
      assert body["action"] == json_response(first, 201)["action"]
      assert length(attempts(bill)) == 1
    end

    test "another method creates a new attempt with the next seq", %{conn: conn, bill: bill} do
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      ewallet = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "ewallet"})
      Contract.check!("payment_attempt.ewallet", ewallet)

      assert ["#{bill.id}-1", "#{bill.id}-2"] ==
               attempts(bill) |> Enum.sort_by(& &1.seq) |> Enum.map(& &1.external_id)
    end

    test "an expired attempt is regenerated as a new attempt", %{conn: conn, bill: bill} do
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      Clock.advance(3_601)

      assert %{"reused" => false, "expires_at" => "2026-10-06T05:00:01Z"} =
               conn
               |> post(~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
               |> json_response(201)

      assert [{1, "expired"}, {2, "pending"}] =
               attempts(bill) |> Enum.sort_by(& &1.seq) |> Enum.map(&{&1.seq, &1.status})

      assert %{"attempt_expired" => false, "attempt" => %{"method" => "qris"}} =
               conn |> get(~p"/api/pay/#{bill.pay_token}") |> json_response(200)
    end

    test "an attempt never outlives the link", %{conn: conn, bill: bill} do
      expires_at = ~U[2026-10-06 03:10:00Z]
      bill |> Ecto.Changeset.change(token_expires_at: expires_at) |> Repo.update!()

      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})

      assert [%{expires_at: ^expires_at}] = attempts(bill)
    end

    for {status, code, http} <- [
          {"paid", "bill_paid", 409},
          {"void", "bill_void", 409},
          {"needs_review", "bill_needs_review", 409}
        ] do
      test "a #{status} bill is rejected as #{code}", %{conn: conn, bill: bill} do
        bill |> Ecto.Changeset.change(status: unquote(status)) |> Repo.update!()

        conn = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
        Contract.check!("errors/#{unquote(code)}", conn)
        assert %{"error" => unquote(code)} = json_response(conn, unquote(http))
        assert attempts(bill) == []
      end
    end

    test "an expired link is rejected with 410", %{conn: conn, bill: bill} do
      Clock.advance(31 * 86_400)

      conn = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      Contract.check!("errors/token_expired", conn)
      assert %{"error" => "token_expired"} = json_response(conn, 410)

      assert attempts(bill) == []
    end

    test "unknown token, unknown method and missing method", %{conn: conn, bill: bill} do
      assert %{"error" => "not_found", "message" => _} =
               conn |> post(~p"/api/pay/nope/payment", %{method: "qris"}) |> json_response(404)

      unsupported = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "cash"})
      Contract.check!("errors/unsupported_method", unsupported)
      assert %{"error" => "unsupported_method"} = json_response(unsupported, 422)

      missing = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{})
      assert %{"error" => "invalid_params"} = json_response(missing, 422)

      assert attempts(bill) == []
    end

    test "a gateway failure is 502 and leaves a failed attempt", %{conn: conn, bill: bill} do
      FakeGateway.configure(create_payment: {:error, :provider_down})

      conn = post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      Contract.check!("errors/gateway_error", conn)

      assert %{"error" => "gateway_error"} = json_response(conn, 502)
      assert [%{status: "failed"}] = attempts(bill)
    end

    test "creating a payment touches neither the ledger nor the bill", %{conn: conn, bill: bill} do
      ledger_before = Repo.aggregate(Petepete.Ledger.Txn, :count)
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})

      assert Repo.aggregate(Petepete.Ledger.Txn, :count) == ledger_before
      assert Repo.get!(Bill, bill.id).status == "unpaid"
    end
  end

  test "no response of the pay link mentions a member's phone", %{conn: conn, bills: bills} do
    assert Repo.aggregate(from(m in Member, where: not is_nil(m.phone)), :count) == 3

    for bill <- bills do
      get_body = conn |> get(~p"/api/pay/#{bill.pay_token}") |> response(200)
      for phone <- @phones, do: refute(get_body =~ phone)
    end
  end
end
