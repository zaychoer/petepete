defmodule Petepete.Payments.PayLinkTest do
  # Not async: the fake gateway's behaviour is application config.
  use Petepete.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Petepete.{BillingScenario, Clock, FakeGateway, Payments}
  alias Petepete.Payments.Gateway.Spy
  alias Petepete.Payments.PaymentAttempt

  setup do
    Clock.freeze(~U[2026-10-06 03:00:00Z])
    FakeGateway.configure(notify: self())
    ctx = BillingScenario.issued()
    %{bill: ctx.bills[ctx.a.id]}
  end

  defp attempts(bill),
    do: Repo.all(from a in PaymentAttempt, where: a.bill_id == ^bill.id, order_by: a.seq)

  test "the attempt is committed pending, without provider data, before the gateway is asked",
       %{bill: bill} do
    test = self()

    Spy.install(fn :create_payment, request ->
      send(test, {:seen_at_call, Repo.get_by(PaymentAttempt, external_id: request.external_id)})
    end)

    assert {:ok, %{attempt: attempt, reused: false}} =
             Payments.start_payment(bill.pay_token, "qris")

    assert_received {:seen_at_call,
                     %PaymentAttempt{status: "pending", provider_ref: nil, action: nil}}

    assert attempt.provider_ref == "fake-#{bill.id}-1"
    assert %{"type" => "qr_string"} = attempt.action
  end

  test "a refused gateway call leaves a failed attempt and a retry takes the next seq",
       %{bill: bill} do
    FakeGateway.configure(create_payment: {:error, :provider_down})
    assert {:error, :gateway_error} = Payments.start_payment(bill.pay_token, "qris")
    assert [%{seq: 1, status: "failed", provider_ref: nil, action: nil}] = attempts(bill)

    FakeGateway.configure(create_payment: :api)

    assert {:ok, %{attempt: retry, reused: false}} =
             Payments.start_payment(bill.pay_token, "qris")

    assert retry.seq == 2 and retry.external_id == "#{bill.id}-2" and retry.status == "pending"
    assert [%{seq: 1, status: "failed"}, %{seq: 2, status: "pending"}] = attempts(bill)
  end

  test "a crash between the commit and the provider call is finished by the retry", %{bill: bill} do
    # What a crash after the first transaction leaves behind.
    stuck =
      BillingScenario.attempt!(bill, expires_at: DateTime.add(Clock.now(), 600, :second))

    assert stuck.provider_ref == nil

    assert {:ok, %{attempt: done, reused: false}} = Payments.start_payment(bill.pay_token, "qris")

    assert done.id == stuck.id and done.seq == 1
    assert done.provider_ref == "fake-#{bill.id}-1"
    assert %{"type" => "qr_string"} = done.action
    assert [%{id: id}] = attempts(bill)
    assert id == stuck.id

    external_id = "#{bill.id}-1"
    assert_received {:fake_gateway, :create_payment, ^external_id}

    # Now that the provider data is stored, the same method is a plain reuse.
    assert {:ok, %{attempt: %{id: ^id}, reused: true}} =
             Payments.start_payment(bill.pay_token, "qris")

    refute_received {:fake_gateway, :create_payment, _}
  end

  test "a pending attempt of another method does not block a new one", %{bill: bill} do
    BillingScenario.attempt!(bill, expires_at: DateTime.add(Clock.now(), 600, :second))

    assert {:ok, %{attempt: va}} = Payments.start_payment(bill.pay_token, "va")
    assert va.seq == 2 and va.method == "va" and va.provider_ref == "fake-#{bill.id}-2"
  end
end
