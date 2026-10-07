defmodule Petepete.Payments.Gateway.Spy do
  @moduledoc """
  The Fake gateway with a hook: `config :petepete, Petepete.Payments.Gateway.Spy,
  on_call: fn call, arg -> ... end` runs before `create_payment/1` (`:create_payment`, the
  request) and `withdraw/3` (`:withdraw`, the reference). Tests use it to look at the
  database at the moment the provider is asked. Everything else is the Fake.
  """
  @behaviour Petepete.Payments.Gateway

  alias Petepete.Payments.Gateway.Fake

  @impl true
  def provider, do: Fake.provider()

  @impl true
  def create_payment(request) do
    hook(:create_payment, request)
    Fake.create_payment(request)
  end

  @impl true
  defdelegate verify_webhook(headers, raw_body), to: Fake

  @impl true
  defdelegate normalize_webhook(payload), to: Fake

  @impl true
  defdelegate fee_for(method, amount_due), to: Fake

  @impl true
  defdelegate cancel_payment(provider_ref), to: Fake

  @impl true
  defdelegate register_payout_account(request), to: Fake

  @impl true
  defdelegate payout_account_status(provider_account_id), to: Fake

  @impl true
  defdelegate balance(provider_account_id), to: Fake

  @impl true
  def withdraw(provider_account_id, amount, reference) do
    hook(:withdraw, reference)
    Fake.withdraw(provider_account_id, amount, reference)
  end

  @impl true
  defdelegate withdrawal_status(reference), to: Fake

  @doc "Makes the Spy the gateway of the calling test and runs `on_call` on each call."
  @spec install(function()) :: :ok
  def install(on_call) when is_function(on_call, 2) do
    original = Application.fetch_env!(:petepete, :gateway)
    Application.put_env(:petepete, :gateway, __MODULE__)
    Application.put_env(:petepete, __MODULE__, on_call: on_call)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:petepete, :gateway, original)
      Application.delete_env(:petepete, __MODULE__)
    end)
  end

  defp hook(call, arg) do
    :petepete
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:on_call)
    |> then(& &1.(call, arg))
  end
end
