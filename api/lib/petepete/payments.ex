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
  Registers `owner` (a host of `group`) as the group's payout account owner: asks the
  gateway for a sub-account and records it in `payout_accounts` with the status the
  gateway returns (`pending_kyc` until KYC finishes, see `refresh_payout_account/1`).

  `bank_details` takes `bank_name`, `account_number` and `account_holder_name`. Only the
  last four digits of the account number are kept.
  """
  @spec register_payout_account(Group.t(), Member.t(), map()) ::
          {:ok, PayoutAccount.t()}
          | {:error, Ecto.Changeset.t() | :owner_not_in_group | :owner_not_host | term()}
  def register_payout_account(%Group{} = group, %Member{} = owner, bank_details) do
    with :ok <- check_owner(group, owner),
         {:ok, bank} <- validate_bank(bank_details),
         gateway = gateway(),
         {:ok, account} <-
           gateway.register_payout_account(%{
             group_id: group.id,
             group_name: group.name,
             owner_member_id: owner.id,
             owner_name: owner.display_name,
             bank: bank
           }) do
      Repo.insert(%PayoutAccount{
        group_id: group.id,
        owner_member_id: owner.id,
        provider: gateway.provider(),
        provider_account_id: account.provider_account_id,
        status: Atom.to_string(account.status),
        bank_name: bank.bank_name,
        account_last4: String.slice(bank.account_number, -4, 4)
      })
    end
  end

  defp check_owner(%Group{id: group_id}, %Member{group_id: group_id, role: "host"}), do: :ok

  defp check_owner(%Group{id: group_id}, %Member{group_id: group_id}),
    do: {:error, :owner_not_host}

  defp check_owner(_group, _owner), do: {:error, :owner_not_in_group}

  defp validate_bank(attrs) do
    {%{}, @bank_types}
    |> cast(attrs, Map.keys(@bank_types))
    |> update_change(:account_number, &String.replace(&1, ~r/[\s-]/, ""))
    |> validate_required(Map.keys(@bank_types))
    |> validate_format(:account_number, ~r/^\d{6,}$/, message: "must be digits only")
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

  defdelegate withdraw(group_id, member, actor_user_id, idempotency_key, amount),
    to: Petepete.Payments.Withdrawals

  defdelegate list_withdrawals(group_id), to: Petepete.Payments.Withdrawals, as: :list
end
