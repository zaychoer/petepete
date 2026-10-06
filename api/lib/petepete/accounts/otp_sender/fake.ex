defmodule Petepete.Accounts.OtpSender.Fake do
  @moduledoc """
  Development and test sender: nothing leaves the machine.

  Each delivery is recorded as a `{:otp_sent, phone, code}` message to the calling
  process (delivery is synchronous, so tests `assert_received` it) and logged at
  info level with the code but without the phone number. Never use in production.
  """
  @behaviour Petepete.Accounts.OtpSender

  require Logger

  @impl true
  def deliver(phone, code) do
    send(self(), {:otp_sent, phone, code})
    Logger.info("[OtpSender.Fake] OTP code #{code}")
    :ok
  end
end
