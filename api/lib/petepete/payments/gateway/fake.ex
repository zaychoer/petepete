defmodule Petepete.Payments.Gateway.Fake do
  @moduledoc """
  Deterministic stand-in for a real provider; the adapter in dev, test and any
  environment without real money.

  Configured under `config :petepete, Petepete.Payments.Gateway.Fake`:

    * `:fees` (required) - per-method table for `Petepete.Payments.Gateway.FeeTable`.
    * `:webhook_secret` (required) - HMAC key for webhook signatures.
    * `:register_status` - status `register_payout_account/1` returns, `:pending_kyc`
      (default) or `:active`.
    * `:kyc_status` - status `payout_account_status/1` returns afterwards, default `:active`.
    * `:balance` - what `balance/1` returns, default `0`.
    * `:withdraw` - `:api` (default), `{:managed, dashboard_url}` or `{:error, reason}`.
    * `:create_payment` - `:api` (default) or `{:error, reason}`.
    * `:notify` - a pid that gets `{:fake_gateway, :create_payment | :withdraw | :register_payout_account, key}` for every
      call that reaches the provider (`key` is the `external_id` or the withdrawal
      `reference`, or the `group_id` of a registration), so tests can count them. Default none.

  Tests build signed webhooks with `webhook/2`.
  """
  @behaviour Petepete.Payments.Gateway

  alias Petepete.Payments.Gateway.FeeTable

  @signature_header "x-fake-signature"

  @statuses %{
    "PENDING" => :pending,
    "PAID" => :paid,
    "EXPIRED" => :expired,
    "FAILED" => :failed
  }

  @impl true
  def provider, do: "fake"

  @impl true
  def create_payment(%{external_id: external_id, method: method, gross_amount: gross} = request) do
    notify(:create_payment, external_id)

    with :api <- config(:create_payment, :api),
         {:ok, action} <- action(method, external_id, gross) do
      {:ok,
       %{provider_ref: "fake-#{external_id}", action: action, expires_at: request.expires_at}}
    else
      {:error, _} = error -> error
    end
  end

  defp action("qris", external_id, gross) do
    {:ok, %{"type" => "qr_string", "qr_string" => "FAKEQRIS|#{external_id}|#{gross}"}}
  end

  defp action("va", external_id, _gross) do
    {:ok, %{"type" => "va_number", "va_number" => "88000#{digits(external_id)}"}}
  end

  defp action("ewallet", external_id, _gross) do
    {:ok,
     %{"type" => "redirect_url", "redirect_url" => "https://fake-gateway.test/pay/#{external_id}"}}
  end

  defp action(_method, _external_id, _gross), do: {:error, :unsupported_method}

  defp digits(string), do: String.replace(string, ~r/\D/, "")

  @impl true
  def verify_webhook(headers, raw_body) do
    with {_, given} <- List.keyfind(headers, @signature_header, 0),
         true <- Plug.Crypto.secure_compare(given, sign(raw_body)) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @impl true
  def normalize_webhook(
        %{
          "txn_id" => txn_id,
          "state" => state,
          "order_id" => order_id
        } = payload
      )
      when is_binary(txn_id) and is_binary(order_id) do
    case @statuses do
      %{^state => status} ->
        {:ok,
         %{
           provider_txn_id: txn_id,
           status: status,
           external_id: order_id,
           paid_amount: if(status == :paid, do: payload["paid_amount"])
         }}

      _ ->
        {:error, :malformed_payload}
    end
  end

  def normalize_webhook(_payload), do: {:error, :malformed_payload}

  @impl true
  def fee_for(method, amount_due), do: FeeTable.fee_for(fees(), method, amount_due)

  @doc "What the fake provider keeps from a `gross` payment; tests use it to prove the host nets `amount_due`."
  @spec provider_fee(String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :unsupported_method}
  def provider_fee(method, gross), do: FeeTable.provider_fee(fees(), method, gross)

  @impl true
  def cancel_payment(_provider_ref), do: {:error, :unsupported}

  @impl true
  def register_payout_account(%{group_id: group_id, owner_member_id: member_id}) do
    notify(:register_payout_account, group_id)

    {:ok,
     %{
       provider_account_id: "fake-acct-g#{group_id}-m#{member_id}",
       status: config(:register_status, :pending_kyc)
     }}
  end

  @impl true
  def payout_account_status(_provider_account_id), do: {:ok, config(:kyc_status, :active)}

  @impl true
  def balance(_provider_account_id), do: {:ok, config(:balance, 0)}

  @impl true
  def withdraw(provider_account_id, _amount, reference) do
    notify(:withdraw, reference)

    case config(:withdraw, :api) do
      :api -> {:ok, %{provider_ref: "fake-withdrawal-#{provider_account_id}-#{reference}"}}
      {:managed, url} -> {:managed, url}
      {:error, _} = error -> error
    end
  end

  defp notify(call, key) do
    if pid = config(:notify, nil), do: send(pid, {:fake_gateway, call, key})
  end

  @doc """
  A webhook as the fake provider would send it: `{headers, raw_body}`, signed unless
  `signature:` overrides the header value.

  `attrs`: `:provider_txn_id`, `:external_id`, `:status` (`:pending | :paid | :expired | :failed`),
  and `:paid_amount` (sent for `:paid` only).
  """
  @spec webhook(map(), keyword()) :: {[{String.t(), String.t()}], binary()}
  def webhook(attrs, opts \\ []) do
    body =
      Jason.encode!(%{
        "txn_id" => attrs.provider_txn_id,
        "order_id" => attrs.external_id,
        "state" => state(attrs.status),
        "paid_amount" => Map.get(attrs, :paid_amount)
      })

    {[{@signature_header, Keyword.get_lazy(opts, :signature, fn -> sign(body) end)}], body}
  end

  defp state(status), do: Enum.find_value(@statuses, fn {k, v} -> v == status && k end)

  defp sign(raw_body) do
    :hmac
    |> :crypto.mac(:sha256, config!(:webhook_secret), raw_body)
    |> Base.encode16(case: :lower)
  end

  defp fees, do: config!(:fees)

  defp config!(key), do: Keyword.fetch!(env(), key)
  defp config(key, default), do: Keyword.get(env(), key, default)
  defp env, do: Application.fetch_env!(:petepete, __MODULE__)
end
