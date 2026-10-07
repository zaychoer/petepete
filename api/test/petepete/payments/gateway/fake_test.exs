defmodule Petepete.Payments.Gateway.FakeTest do
  use ExUnit.Case, async: true

  alias Petepete.Payments.Gateway.Fake

  @expires ~U[2026-10-07 10:00:00Z]

  describe "create_payment/1" do
    test "returns the action payload each method needs, deterministically" do
      request = fn method ->
        %{external_id: "12-1", method: method, gross_amount: 45_354, expires_at: @expires}
      end

      assert {:ok, %{provider_ref: "fake-12-1", expires_at: @expires, action: qris}} =
               Fake.create_payment(request.("qris"))

      assert %{"type" => "qr_string", "qr_string" => qr} = qris
      assert qr =~ "12-1"

      assert {:ok, %{action: %{"type" => "va_number", "va_number" => _}}} =
               Fake.create_payment(request.("va"))

      assert {:ok, %{action: %{"type" => "redirect_url", "redirect_url" => _}}} =
               Fake.create_payment(request.("ewallet"))

      assert Fake.create_payment(request.("qris")) == Fake.create_payment(request.("qris"))
      assert {:error, :unsupported_method} = Fake.create_payment(request.("cheque"))
    end
  end

  describe "webhooks" do
    @paid %{provider_txn_id: "txn-1", external_id: "12-1", status: :paid, paid_amount: 45_354}

    test "a signed webhook verifies and normalizes" do
      {headers, body} = Fake.webhook(@paid)

      assert :ok = Fake.verify_webhook(headers, body)

      assert {:ok, @paid} = body |> Jason.decode!() |> Fake.normalize_webhook()
    end

    test "non-paid statuses carry no paid amount" do
      for status <- [:pending, :expired, :failed] do
        {_headers, body} = Fake.webhook(%{@paid | status: status})

        assert {:ok, %{status: ^status, paid_amount: nil}} =
                 body |> Jason.decode!() |> Fake.normalize_webhook()
      end
    end

    test "rejects a wrong, missing or stale signature" do
      {headers, body} = Fake.webhook(@paid)
      {_, forged_body} = Fake.webhook(%{@paid | paid_amount: 1})

      assert {:error, :invalid_signature} = Fake.verify_webhook(headers, forged_body)

      {bad_headers, ^body} = Fake.webhook(@paid, signature: "nope")
      assert {:error, :invalid_signature} = Fake.verify_webhook(bad_headers, body)

      assert {:error, :invalid_signature} = Fake.verify_webhook([], body)
    end

    test "rejects a payload it cannot read" do
      assert {:error, :malformed_payload} = Fake.normalize_webhook(%{"txn_id" => "t"})

      assert {:error, :malformed_payload} =
               Fake.normalize_webhook(%{"txn_id" => "t", "order_id" => "o", "state" => "WAT"})
    end
  end

  test "cancel_payment/1 is unsupported" do
    assert {:error, :unsupported} = Fake.cancel_payment("fake-12-1")
  end

  describe "withdrawal_status/1" do
    test "returns :submitted for references starting with withdrawal-" do
      assert {:ok, :submitted} = Fake.withdrawal_status("withdrawal-abc123")
    end

    test "returns :not_found for other references" do
      assert {:ok, :not_found} = Fake.withdrawal_status("payment-xyz")
      assert {:ok, :not_found} = Fake.withdrawal_status("unknown")
    end
  end
end
