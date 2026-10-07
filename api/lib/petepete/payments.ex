defmodule Petepete.Payments do
  @moduledoc """
  Gateway payment requests, notifications and payout accounts.

  Schemas: `Petepete.Payments.PaymentAttempt` (`payment_attempts`),
  `Petepete.Payments.GatewayNotification` (`gateway_notifications`). The group's
  `Petepete.Groups.PayoutAccount` is written here because creating it is a gateway call.
  `Petepete.Payments.Withdrawal` (`withdrawals`) records PAY-07 withdrawals; the unauthenticated
  pay link is `Petepete.Payments.PayLink`; `Petepete.Payments.CancelAttemptsJob` cancels
  voided attempts at the gateway.

  Everything provider-shaped goes through the adapter behind
  `Petepete.Payments.Gateway`, chosen by `config :petepete, :gateway`.
  """
  import Ecto.Changeset

  alias Petepete.{Actor, HostAction}
  alias Petepete.Groups.{Group, Member, PayoutAccount}
  alias Petepete.Payments.{IntentRunner, PayoutRegistrationIntent}
  alias Petepete.Repo

  @doc "The configured `Petepete.Payments.Gateway` adapter module."
  @spec gateway() :: module()
  def gateway, do: Application.fetch_env!(:petepete, :gateway)

  @doc """
  The gateway fee a payer adds to `amount_due` so the host nets exactly `amount_due`;
  `gross_amount` is `amount_due + fee`. `method` is `"qris"`, `"va"` or `"ewallet"`.
  The per-method table belongs to the configured adapter.
  """
  @spec fee_for(String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :unsupported_method | :invalid_amount}
  def fee_for(method, amount_due), do: gateway().fee_for(method, amount_due)

  @bank_types %{bank_name: :string, account_number: :string, account_holder_name: :string}

  @doc """
  Registers the host `actor` as the payout account owner of `group_id` (PAY-07): commits a
  `registering` row first (via HostAction + audit), then asks the gateway for a sub-account
  outside the transaction, then settles the row with the gateway's outcome.

  `key` is the request's `Idempotency-Key`, unique per group. A repeat of a key that
  already registered an account returns that account (`replayed: true`) without asking the
  gateway again and without a second audit row.

  `bank_details` takes `bank_name`, `account_number` and `account_holder_name`. Only the
  last four digits of the account number are kept.
  """
  @spec register_payout_account(Actor.t(), pos_integer(), String.t(), map()) ::
          {:ok, %{payout_account: PayoutAccount.t(), replayed: boolean()}}
          | {:error, Ecto.Changeset.t() | term()}
  def register_payout_account(%Actor{} = actor, group_id, key, bank_details)
      when is_binary(key) do
    with {:ok, bank} <- validate_bank(bank_details) do
      group = Repo.get!(Group, group_id)
      owner = Repo.get!(Member, actor.member_id)
      gw = gateway()

      # Prepare: insert registering row or find existing, inside HostAction for audit.
      case prepare_registration(actor, group, owner, gw, key, bank) do
        {:ok, %{payout_account: account, replayed: true}} ->
          {:ok, %{payout_account: account, replayed: true}}

        {:ok, %{payout_account: account, replayed: false}} ->
          # Request: call gateway outside any transaction.
          # Store bank details in process dict for the intent's request callback.
          Process.put({PayoutRegistrationIntent, :bank_details}, bank)
          result = PayoutRegistrationIntent.request(account, "payout-reg-#{account.id}")
          Process.delete({PayoutRegistrationIntent, :bank_details})

          # Settle: update the row with the gateway result.
          case Repo.transaction(fn ->
                 PayoutRegistrationIntent.settle(account, result)
               end) do
            {:ok, {:ok, settled}} ->
              {:ok, %{payout_account: settled, replayed: false}}

            {:ok, {:error, {:registration_failed, _failed, reason}}} ->
              {:error, reason}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepare_registration(actor, group, owner, gateway, key, bank) do
    # Check for existing account first (cheap, no HostAction needed for replay)
    case Repo.get_by(PayoutAccount, group_id: group.id, idempotency_key: key) do
      %PayoutAccount{status: "registering"} = account ->
        # In-progress registration: treat as new (complete the request)
        {:ok, %{payout_account: account, replayed: false}}

      %PayoutAccount{} = account ->
        {:ok, %{payout_account: account, replayed: true}}

      nil ->
        # New registration: create inside HostAction for audit
        case HostAction.run(actor, group.id, "payout_account.register", fn ->
               {:ok, account, _ref} =
                 IntentRunner.prepare_only(PayoutRegistrationIntent, %{
                   group_id: group.id,
                   owner_member_id: owner.id,
                   bank: bank,
                   idempotency_key: key,
                   gateway: gateway
                 })

               {:ok, account,
                %{
                  subject: {"payout_account", account.id},
                  metadata: %{
                    "owner_member_id" => owner.id,
                    "provider" => account.provider,
                    "bank_name" => account.bank_name,
                    "account_last4" => account.account_last4
                  },
                  replayed: false
                }}
             end) do
          {:ok, account} ->
            {:ok, %{payout_account: account, replayed: false}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp validate_bank(attrs) do
    {%{}, @bank_types}
    |> cast(attrs, Map.keys(@bank_types))
    |> update_change(:account_number, &String.replace(&1, ~r/[\s-]/, ""))
    |> validate_required(Map.keys(@bank_types))
    |> validate_change(:account_number, fn :account_number, number ->
      if number =~ ~r/^\d{6,}$/,
        do: [],
        else: [account_number: {"must be digits only", validation: :digits_only, min: 6}]
    end)
    |> apply_action(:validate)
  end

  @doc """
  Asks the gateway for the current KYC status of `account` and stores it.
  """
  @spec refresh_payout_account(PayoutAccount.t()) :: {:ok, PayoutAccount.t()} | {:error, term()}
  def refresh_payout_account(%PayoutAccount{} = account) do
    with {:ok, status} <- gateway().payout_account_status(account.provider_account_id) do
      account |> change(status: Atom.to_string(status)) |> Repo.update()
    end
  end

  @doc """
  `Billing.void_issue/2` plus the gateway cancellation of the attempts it cancelled, in one
  transaction: the `Petepete.Payments.CancelAttemptsJob` row is inserted before the commit
  (Oban runs it after), so a void that committed always has its job. A replay (same
  `Idempotency-Key`) cancels no attempt and enqueues nothing. Returns what
  `Billing.void_issue/2` returns; any error rolls everything back, the job included.
  """
  @spec void_issue(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def void_issue(session_id, opts) do
    Repo.transaction(fn ->
      case Petepete.Billing.void_issue(session_id, opts) do
        {:ok, result} ->
          enqueue_cancellation(result.cancelled_attempt_ids)
          result

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp enqueue_cancellation([]), do: :ok

  defp enqueue_cancellation(ids) do
    {:ok, _job} =
      %{"attempt_ids" => ids} |> Petepete.Payments.CancelAttemptsJob.new() |> Oban.insert()

    :ok
  end

  ## Pay link (unauthenticated, addressed by `bills.pay_token`); see `Petepete.Payments.PayLink`

  defdelegate pay_page(token), to: Petepete.Payments.PayLink, as: :show
  defdelegate start_payment(token, method), to: Petepete.Payments.PayLink

  ## Withdrawals (PAY-07); see `Petepete.Payments.Withdrawals`

  defdelegate payout_account_balance(group_id), to: Petepete.Payments.Withdrawals, as: :balance

  defdelegate withdraw(actor, group_id, idempotency_key, amount),
    to: Petepete.Payments.Withdrawals

  defdelegate list_withdrawals(group_id), to: Petepete.Payments.Withdrawals, as: :list
end
