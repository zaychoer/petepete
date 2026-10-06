defmodule Petepete.AccountsDeliveryTest do
  # Swaps the global sender, so it cannot run async.
  use PetepeteWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Petepete.Repo
  alias Petepete.Accounts.OtpChallenge

  defmodule FailingSender do
    @behaviour Petepete.Accounts.OtpSender
    @impl true
    def deliver(_phone, _code), do: {:error, :provider_down}
  end

  setup do
    config = Application.fetch_env!(:petepete, Petepete.Accounts)

    Application.put_env(
      :petepete,
      Petepete.Accounts,
      Keyword.put(config, :otp_sender, FailingSender)
    )

    on_exit(fn -> Application.put_env(:petepete, Petepete.Accounts, config) end)
  end

  test "a failed delivery is a 502 and does not use up the phone's quota", %{conn: conn} do
    log =
      capture_log(fn ->
        for _ <- 1..6 do
          conn = post(conn, ~p"/api/auth/otp", %{phone: "628123400001"})
          assert json_response(conn, 502) == %{"error" => "delivery_failed"}
        end
      end)

    refute log =~ "628123400001"

    assert Repo.aggregate(OtpChallenge, :count) == 0
  end

  test "boot fails when no sender is configured" do
    config = Application.fetch_env!(:petepete, Petepete.Accounts)
    Application.put_env(:petepete, Petepete.Accounts, Keyword.delete(config, :otp_sender))

    assert_raise RuntimeError, ~r/no OTP sender configured/, fn ->
      Petepete.Accounts.OtpSender.fetch!()
    end
  end
end
