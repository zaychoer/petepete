defmodule Petepete.Payments.CancelAttemptsJobTest do
  # Not async: swaps the configured gateway.
  use Petepete.DataCase, async: false
  use Oban.Testing, repo: Petepete.Repo

  import Petepete.Fixtures

  alias Petepete.Payments.{CancelAttemptsJob, PaymentAttempt}
  alias Petepete.Repo

  defmodule RecordingGateway do
    @moduledoc false
    def cancel_payment("ref-fail"), do: {:error, :timeout}
    def cancel_payment(ref), do: send(self(), {:cancelled, ref}) && :ok
  end

  setup do
    original = Application.fetch_env!(:petepete, :gateway)
    on_exit(fn -> Application.put_env(:petepete, :gateway, original) end)

    group = group_fixture()
    session = session_fixture(event_fixture(group))
    bill = bill_fixture(session, member_fixture(group, role: "member"))
    %{bill: bill}
  end

  defp attempt(bill, seq, ref) do
    Repo.insert!(%PaymentAttempt{
      bill_id: bill.id,
      seq: seq,
      external_id: "#{bill.id}-#{seq}",
      provider: "fake",
      method: "qris",
      provider_ref: ref,
      amount_due: 10_000,
      fee: 100,
      gross_amount: 10_100,
      status: "cancelled"
    })
  end

  test "a gateway without a cancel API is fine", %{bill: bill} do
    a = attempt(bill, 1, "ref-1")

    assert :ok = perform_job(CancelAttemptsJob, %{"attempt_ids" => [a.id]})
  end

  test "cancels every attempt that reached the gateway and fails on a gateway error",
       %{bill: bill} do
    Application.put_env(:petepete, :gateway, __MODULE__.RecordingGateway)
    ok = attempt(bill, 1, "ref-ok")
    failing = attempt(bill, 2, "ref-fail")
    never_sent = attempt(bill, 3, nil)

    assert {:error, {:cancel_failed, 1, :timeout}} =
             perform_job(CancelAttemptsJob, %{
               "attempt_ids" => [ok.id, failing.id, never_sent.id]
             })

    assert_received {:cancelled, "ref-ok"}
    refute_received {:cancelled, nil}
  end
end
