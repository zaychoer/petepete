defmodule Petepete.Accounts.OtpSender do
  @moduledoc """
  Seam for delivering an OTP code to a phone (WhatsApp provider, deferred).

  The adapter is chosen by `config :petepete, Petepete.Accounts, otp_sender: Module`.
  `Petepete.Accounts.OtpSender.Fake` is configured in dev and test. Production has
  no default: `config/runtime.exs` reads `OTP_SENDER` (a module name) through
  `Petepete.AdapterPolicy`, which refuses a module that is not loadable, does not
  implement this behaviour, or is the fake (unless `ALLOW_FAKE_ADAPTERS=true`, staging
  only), so the app never starts in production with a sender that cannot deliver.
  `fetch!/0` raises at boot when nothing is configured at all.

  Adapters MUST NOT log the phone number.
  """

  @doc "Delivers `code` to `phone` (62… format). Called synchronously from the request."
  @callback deliver(phone :: String.t(), code :: String.t()) :: :ok | {:error, term()}

  @doc "The configured sender module; raises when none is configured."
  @spec fetch!() :: module()
  def fetch! do
    :petepete
    |> Application.get_env(Petepete.Accounts, [])
    |> Keyword.get(:otp_sender) ||
      raise """
      no OTP sender configured: set config :petepete, Petepete.Accounts, otp_sender: Module.
      In production set OTP_SENDER to the adapter module name (see docs/deploy.md).
      """
  end

  @doc "Delivers through the configured sender."
  @spec deliver(String.t(), String.t()) :: :ok | {:error, term()}
  def deliver(phone, code), do: fetch!().deliver(phone, code)
end
