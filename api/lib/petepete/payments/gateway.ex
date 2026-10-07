defmodule Petepete.Payments.Gateway do
  @moduledoc """
  Everything provider-shaped about the payment gateway, behind one seam.

  The adapter is chosen by `config :petepete, :gateway, Module` (see
  `Petepete.Payments.gateway/0`). No real provider is wired yet: dev and test use
  `Petepete.Payments.Gateway.Fake`, and prod must name its adapter explicitly or the
  release refuses to boot.

  Conventions shared by all callbacks:

    * Money is integer rupiah, never floats.
    * A *method* is the string stored in `payment_attempts.method`:
      `"qris"`, `"va"` or `"ewallet"`.
    * A *status* of a notification is `:pending | :paid | :expired | :failed`, the
      same vocabulary as `payment_attempts.status` (without `:cancelled`, which only
      Petepete decides).
    * Adapters do no database work; Payments owns every write.
  """

  @type method :: String.t()
  @type status :: :pending | :paid | :expired | :failed

  @type payment_request :: %{
          external_id: String.t(),
          method: method(),
          gross_amount: pos_integer(),
          expires_at: DateTime.t()
        }

  @typedoc """
  What the payer is shown: a map with a `"type"` key of `"qr_string"`, `"va_number"`
  or `"redirect_url"` plus the matching value, stored as `payment_attempts.action`.
  """
  @type action :: %{required(String.t()) => term()}

  @type payment :: %{provider_ref: String.t(), action: action(), expires_at: DateTime.t()}

  @type notification :: %{
          provider_txn_id: String.t(),
          status: status(),
          external_id: String.t(),
          paid_amount: non_neg_integer() | nil
        }

  @type bank_details :: %{
          bank_name: String.t(),
          account_number: String.t(),
          account_holder_name: String.t()
        }

  @type payout_account_request :: %{
          group_id: integer(),
          group_name: String.t() | nil,
          owner_member_id: integer(),
          owner_name: String.t(),
          bank: bank_details()
        }

  @type payout_account :: %{
          provider_account_id: String.t(),
          status: :pending_kyc | :active
        }

  @doc "Provider name stored in `payment_attempts.provider`, `payout_accounts.provider` and the `/webhooks/:provider` path."
  @callback provider() :: String.t()

  @doc """
  Asks the provider for a payment the payer can complete. `gross_amount` is
  `amount_due + fee`; `external_id` is `<bill_id>-<seq>` and is never reused for another
  request. It is also the idempotency key: the call happens after the attempt row is
  committed and is repeated with the same `external_id` if the first outcome was never
  stored, so a repeated `external_id` MUST return the same payment (or fail), never create
  a second one.
  """
  @callback create_payment(payment_request()) :: {:ok, payment()} | {:error, term()}

  @doc "Checks a webhook's authenticity from its raw, unparsed body and request headers (lowercase names)."
  @callback verify_webhook(headers :: [{String.t(), String.t()}], raw_body :: binary()) ::
              :ok | {:error, :invalid_signature}

  @doc "Turns a verified, decoded webhook payload into the fields the webhook flow needs."
  @callback normalize_webhook(payload :: map()) ::
              {:ok, notification()} | {:error, :malformed_payload}

  @doc """
  The fee the payer adds on top of `amount_due` so the host nets exactly `amount_due`
  after the provider takes its own cut (PPN included) from the gross amount.
  The per-method table lives in config, never in code.
  """
  @callback fee_for(method(), amount_due :: pos_integer()) ::
              {:ok, non_neg_integer()} | {:error, :unsupported_method | :invalid_amount}

  @doc "Cancels a pending payment at the provider. `{:error, :unsupported}` when the provider has no such API."
  @callback cancel_payment(provider_ref :: String.t()) :: :ok | {:error, :unsupported | term()}

  @doc "Creates the sub-account that will receive a group's payments."
  @callback register_payout_account(payout_account_request()) ::
              {:ok, payout_account()} | {:error, term()}

  @doc "Current KYC status of a sub-account."
  @callback payout_account_status(provider_account_id :: String.t()) ::
              {:ok, :pending_kyc | :active} | {:error, term()}

  @doc "Sub-account balance in rupiah, for PAY-07."
  @callback balance(provider_account_id :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Withdraws `amount` from the sub-account to its registered bank account, for PAY-07.
  `reference` identifies the request (`withdrawal-<id>`, stable across retries): the adapter
  passes it to the provider as the idempotency key so a repeated call cannot withdraw twice.
  `{:managed, url}` means the provider offers no API and the host withdraws on the
  provider's dashboard at `url`.
  """
  @callback withdraw(
              provider_account_id :: String.t(),
              amount :: pos_integer(),
              reference :: String.t()
            ) ::
              {:ok, %{provider_ref: String.t()}}
              | {:managed, dashboard_url :: String.t()}
              | {:error, term()}

  @doc """
  Checks the status of a withdrawal at the provider by its reference.
  Returns `{:error, :unsupported}` when the adapter has no such API.
  """
  @callback withdrawal_status(reference :: String.t()) ::
              {:ok, :submitted | :managed | :not_found} | {:error, :unsupported | term()}

  @optional_callbacks [withdrawal_status: 1]
end
