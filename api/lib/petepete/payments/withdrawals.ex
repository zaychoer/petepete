defmodule Petepete.Payments.Withdrawals do
  @moduledoc """
  Tarik dana (PAY-07): the balance of a group's gateway sub-account and withdrawals from
  it to the registered bank account. Reached through `Petepete.Payments`.

  Only the payout account's owner (a host) may withdraw. A request holds the payout
  account row lock while it reads the gateway balance and calls the gateway, so two
  requests cannot both spend the same balance. The same `Idempotency-Key` returns the
  first withdrawal without calling the gateway again. Each new withdrawal writes an
  `audit_log` row in the same transaction. The Ledger is not touched.
  """
  import Ecto.Query, only: [from: 2]

  alias Petepete.Groups.{Member, PayoutAccount}
  alias Petepete.Ledger.Audit
  alias Petepete.Payments
  alias Petepete.Payments.Withdrawal
  alias Petepete.Repo

  @type error ::
          :no_payout_account
          | :forbidden
          | :payout_account_not_active
          | :idempotency_key_required
          | :idempotency_key_conflict
          | :amount_not_positive
          | :insufficient_balance
          | {:gateway_error, term()}

  @doc "The group's payout account (the latest registered one, as the Ledger resolves it), or `nil`."
  @spec payout_account(pos_integer()) :: PayoutAccount.t() | nil
  def payout_account(group_id), do: Repo.one(latest_account(group_id))

  defp latest_account(group_id) do
    from a in PayoutAccount, where: a.group_id == ^group_id, order_by: [desc: a.id], limit: 1
  end

  @doc """
  The sub-account balance in rupiah from the gateway, with the account. Errors:
  `:no_payout_account`, `{:gateway_error, reason}`.
  """
  @spec balance(pos_integer()) ::
          {:ok, %{balance: non_neg_integer(), payout_account: PayoutAccount.t()}}
          | {:error, :no_payout_account | {:gateway_error, term()}}
  def balance(group_id) do
    with %PayoutAccount{} = account <- payout_account(group_id) || {:error, :no_payout_account},
         {:ok, balance} <- gateway_balance(account) do
      {:ok, %{balance: balance, payout_account: account}}
    end
  end

  @doc """
  Withdraws `amount` (positive rupiah) for the host `member` of the group, who acts as
  `actor_user_id`. Returns `{:ok, %{withdrawal: w, replayed: boolean}}`; see `t:error/0`.
  """
  @spec withdraw(pos_integer(), Member.t(), pos_integer(), String.t() | nil, term()) ::
          {:ok, %{withdrawal: Withdrawal.t(), replayed: boolean()}} | {:error, error()}
  def withdraw(group_id, %Member{} = member, actor_user_id, key, amount) do
    cond do
      not (is_binary(key) and String.trim(key) != "") -> {:error, :idempotency_key_required}
      not (is_integer(amount) and amount > 0) -> {:error, :amount_not_positive}
      true -> locked_withdraw(group_id, member, actor_user_id, String.trim(key), amount)
    end
  end

  defp locked_withdraw(group_id, member, actor_user_id, key, amount) do
    Repo.transaction(fn ->
      account = group_id |> latest_account() |> Ecto.Query.lock("FOR UPDATE") |> Repo.one()

      with %PayoutAccount{} <- account || {:error, :no_payout_account},
           :ok <- check_owner(account, member) do
        case Repo.get_by(Withdrawal, group_id: group_id, idempotency_key: key) do
          %Withdrawal{amount: ^amount} = withdrawal ->
            %{withdrawal: withdrawal, replayed: true}

          %Withdrawal{} ->
            Repo.rollback(:idempotency_key_conflict)

          nil ->
            new_withdrawal(account, actor_user_id, key, amount)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp check_owner(%PayoutAccount{owner_member_id: id, status: status}, %Member{id: id}) do
    if status == "active", do: :ok, else: {:error, :payout_account_not_active}
  end

  defp check_owner(_account, _member), do: {:error, :forbidden}

  defp new_withdrawal(account, actor_user_id, key, amount) do
    gateway = Payments.gateway()

    with {:ok, balance} <- gateway_balance(account),
         :ok <- if(amount <= balance, do: :ok, else: {:error, :insufficient_balance}),
         {:ok, outcome} <- request_withdrawal(gateway, account, amount) do
      withdrawal =
        Repo.insert!(%Withdrawal{
          group_id: account.group_id,
          payout_account_id: account.id,
          amount: amount,
          status: outcome.status,
          provider_ref: outcome.provider_ref,
          managed_url: outcome.managed_url,
          idempotency_key: key
        })

      Audit.record(
        account.group_id,
        actor_user_id,
        "withdrawal.request",
        {"withdrawal", withdrawal.id},
        %{
          "amount" => amount,
          "payout_account_id" => account.id,
          "status" => withdrawal.status,
          "provider_ref" => withdrawal.provider_ref
        }
      )

      %{withdrawal: withdrawal, replayed: false}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp request_withdrawal(gateway, account, amount) do
    case gateway.withdraw(account.provider_account_id, amount) do
      {:ok, %{provider_ref: ref}} ->
        {:ok, %{status: "submitted", provider_ref: ref, managed_url: nil}}

      {:managed, url} ->
        {:ok, %{status: "managed", provider_ref: nil, managed_url: url}}

      {:error, reason} ->
        {:error, {:gateway_error, reason}}
    end
  end

  defp gateway_balance(%PayoutAccount{provider_account_id: id}) do
    case Payments.gateway().balance(id) do
      {:ok, balance} -> {:ok, balance}
      {:error, reason} -> {:error, {:gateway_error, reason}}
    end
  end

  @doc "The group's withdrawals, newest first."
  @spec list(pos_integer()) :: [Withdrawal.t()]
  def list(group_id) do
    Repo.all(from w in Withdrawal, where: w.group_id == ^group_id, order_by: [desc: w.id])
  end
end
