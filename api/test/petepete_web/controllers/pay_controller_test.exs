defmodule PetepeteWeb.PayControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.{Billing, Clock, Repo}
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
      body = conn |> get(~p"/api/pay/#{bill.pay_token}") |> json_response(200)

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
      assert %{"error" => "not_found"} = conn |> get(~p"/api/pay/nope") |> json_response(404)
    end

    test "a void bill shows only the cancelled message", %{conn: conn, bill: bill} do
      bill |> Ecto.Changeset.change(status: "void") |> Repo.update!()

      body = conn |> get(~p"/api/pay/#{bill.pay_token}") |> json_response(200)

      assert %{"status" => "void", "message" => "Tagihan dibatalkan", "can_pay" => false} = body
      refute Map.has_key?(body, "amount_due")
      assert Map.get(body, "methods") == nil
    end

    test "a paid bill stays visible after the link's expiry date", %{conn: conn, bill: bill} do
      bill |> Ecto.Changeset.change(status: "paid", paid_via: "cash") |> Repo.update!()
      Clock.advance(40 * 86_400)

      assert %{"status" => "paid", "status_label" => "Lunas", "token_expired" => false} =
               conn |> get(~p"/api/pay/#{bill.pay_token}") |> json_response(200)
    end

    test "an expired link on an unpaid bill cannot be paid", %{conn: conn, bill: bill} do
      Clock.advance(31 * 86_400)

      assert %{"token_expired" => true, "can_pay" => false, "methods" => []} =
               conn |> get(~p"/api/pay/#{bill.pay_token}") |> json_response(200)
    end

    test "marks an overdue attempt expired and reports it", %{conn: conn, bill: bill} do
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      Clock.advance(3_601)

      body = conn |> get(~p"/api/pay/#{bill.pay_token}") |> json_response(200)

      assert %{"attempt_expired" => true, "attempt" => nil} = body
      assert [%{status: "expired"}] = attempts(bill)
    end
  end

  describe "POST /api/pay/:token/payment" do
    test "creates one attempt with the gateway fee and external_id <bill_id>-<seq>",
         %{conn: conn, bill: bill} do
      body =
        conn
        |> post(~p"/api/pay/#{bill.pay_token}/payment", %{method: "va"})
        |> json_response(201)

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

      assert json_response(first, 201)["reused"] == false
      assert %{"reused" => true} = body = json_response(second, 200)
      assert body["action"] == json_response(first, 201)["action"]
      assert length(attempts(bill)) == 1
    end

    test "another method creates a new attempt with the next seq", %{conn: conn, bill: bill} do
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
      post(conn, ~p"/api/pay/#{bill.pay_token}/payment", %{method: "ewallet"})

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

        assert %{"error" => unquote(code), "message" => message} =
                 conn
                 |> post(~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
                 |> json_response(unquote(http))

        assert is_binary(message)
        assert attempts(bill) == []
      end
    end

    test "an expired link is rejected with 410", %{conn: conn, bill: bill} do
      Clock.advance(31 * 86_400)

      assert %{"error" => "token_expired"} =
               conn
               |> post(~p"/api/pay/#{bill.pay_token}/payment", %{method: "qris"})
               |> json_response(410)

      assert attempts(bill) == []
    end

    test "unknown token, unknown method and missing method", %{conn: conn, bill: bill} do
      assert %{"error" => "not_found"} =
               conn |> post(~p"/api/pay/nope/payment", %{method: "qris"}) |> json_response(404)

      assert %{"error" => "unsupported_method"} =
               conn
               |> post(~p"/api/pay/#{bill.pay_token}/payment", %{method: "cash"})
               |> json_response(422)

      assert %{"error" => "invalid_params"} =
               conn |> post(~p"/api/pay/#{bill.pay_token}/payment", %{}) |> json_response(422)

      assert attempts(bill) == []
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
