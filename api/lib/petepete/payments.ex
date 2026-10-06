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
  Registers the host `actor` as the payout account owner of `group_id` (PAY-07): asks the
  gateway for a sub-account, then records it in `payout_accounts` with the status the
  gateway returns (`pending_kyc` until KYC finishes, see `refresh_payout_account/1`).

  `key` is the request's `Idempotency-Key`, unique per group. A repeat of a key that
  already registered an account returns that account (`replayed: true`) without asking the
  gateway again and without a second audit row.

  The gateway is asked first, outside any transaction; the `payout_accounts` row and its
  `payout_account.register` audit row then commit together through `Petepete.HostAction`,
  so a gateway failure or invalid bank data leaves no audit row.

  `bank_details` takes `bank_name`, `account_number` and `account_holder_name`. Only the
  last four digits of the account number are kept.
  """
  @spec register_payout_account(Actor.t(), pos_integer(), String.t(), map()) ::
          {:ok, %{payout_account: PayoutAccount.t(), replayed: boolean()}}
          | {:error, Ecto.Changeset.t() | term()}
  def register_payout_account(%Actor{} = actor, group_id, key, bank_details)
      when is_binary(key) do
    case Repo.get_by(PayoutAccount, group_id: group_id, idempotency_key: key) do
      %PayoutAccount{} = account -> {:ok, %{payout_account: account, replayed: true}}
      nil -> register_new(actor, group_id, key, bank_details)
    end
  end

  defp register_new(actor, group_id, key, bank_details) do
    with {:ok, bank} <- validate_bank(bank_details),
         group = Repo.get!(Group, group_id),
         owner = Repo.get!(Member, actor.member_id),
         gateway = gateway(),
         {:ok, account} <-
           gateway.register_payout_account(%{
             group_id: group.id,
             group_name: group.name,
             owner_member_id: owner.id,
             owner_name: owner.display_name,
             bank: bank
           }),
         {:ok, payout_account} <-
           HostAction.run(actor, group.id, "payout_account.register", fn ->
             with {:ok, payout_account} <-
                    Repo.insert(%PayoutAccount{
                      group_id: group.id,
                      owner_member_id: owner.id,
                      provider: gateway.provider(),
                      provider_account_id: account.provider_account_id,
                      status: Atom.to_string(account.status),
                      bank_name: bank.bank_name,
                      account_last4: String.slice(bank.account_number, -4, 4),
                      idempotency_key: key
                    }) do
               {:ok, payout_account,
                %{
                  subject: {"payout_account", payout_account.id},
                  metadata: %{
                    "owner_member_id" => owner.id,
                    "provider" => payout_account.provider,
                    "bank_name" => payout_account.bank_name,
                    "account_last4" => payout_account.account_last4
                  },
                  replayed: false
                }}
             end
           end) do
      {:ok, %{payout_account: payout_account, replayed: false}}
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
