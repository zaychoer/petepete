defmodule Petepete.Payments.Withdrawals do
  @moduledoc """
  Tarik dana (PAY-07): the balance of a group's gateway sub-account and withdrawals from
  it to the registered bank account. Reached through `Petepete.Payments`.

  Only the payout account's owner (a host) may withdraw. A request holds the payout
  account row lock while it reads the gateway balance and calls the gateway, so two
  requests cannot both spend the same balance.

  ## Durability

  A request is committed as a `pending` withdrawal (unique on `(group_id, idempotency_key)`)
  together with its `withdrawal.request` audit row before the gateway is called, and the
  call happens outside any transaction with the stable reference `withdrawal-<id>`, which
  the adapter passes to the provider as idempotency key. The outcome is then written to the
  row (`submitted`, `managed`, or `failed`) with a `withdrawal.<status>` audit row. While a
  request is `pending` its amount counts against the balance, so concurrent requests
  cannot overspend it.

  The same `Idempotency-Key` returns the stored withdrawal and never calls the gateway
  again, whatever its status (`pending`, `submitted`, `managed`), with one exception: a
  `failed` withdrawal is attempted again, on the same row and reference. A withdrawal left
  `pending` by a crash between commit and outcome is therefore NOT retried automatically
  (the provider may have executed it); it needs a manual check at the provider. The
  Ledger is not touched.
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

  The request is durable before the gateway is asked (see the moduledoc): a replay returns
  the stored withdrawal whatever its status, except that a `failed` one is attempted again.
  """
  @spec withdraw(pos_integer(), Member.t(), pos_integer(), String.t() | nil, term()) ::
          {:ok, %{withdrawal: Withdrawal.t(), replayed: boolean()}} | {:error, error()}
  def withdraw(group_id, %Member{} = member, actor_user_id, key, amount) do
    cond do
      not (is_binary(key) and String.trim(key) != "") ->
        {:error, :idempotency_key_required}

      not (is_integer(amount) and amount > 0) ->
        {:error, :amount_not_positive}

      true ->
        key = String.trim(key)

        with {:ok, step} <- accept_request(group_id, member, actor_user_id, key, amount) do
          run(step, actor_user_id)
        end
    end
  end

  # Under the payout account lock: find the request by its key or record a new `pending`
  # one (with its audit row), then commit. No withdrawal call happens in here.
  defp accept_request(group_id, member, actor_user_id, key, amount) do
    Repo.transaction(fn ->
      account = group_id |> latest_account() |> Ecto.Query.lock("FOR UPDATE") |> Repo.one()

      with %PayoutAccount{} <- account || {:error, :no_payout_account},
           :ok <- check_owner(account, member) do
        case Repo.get_by(Withdrawal, group_id: group_id, idempotency_key: key) do
          %Withdrawal{amount: ^amount, status: "failed"} = failed ->
            {:call, account, retry(failed, account, actor_user_id)}

          %Withdrawal{amount: ^amount} = withdrawal ->
            {:replay, withdrawal}

          %Withdrawal{} ->
            Repo.rollback(:idempotency_key_conflict)

          nil ->
            {:call, account, new_withdrawal(account, actor_user_id, key, amount)}
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp run({:replay, withdrawal}, _actor_user_id),
    do: {:ok, %{withdrawal: withdrawal, replayed: true}}

  defp run({:call, account, {withdrawal, replayed}}, actor_user_id) do
    reference = "withdrawal-#{withdrawal.id}"

    case Payments.gateway().withdraw(account.provider_account_id, withdrawal.amount, reference) do
      {:ok, %{provider_ref: ref}} ->
        settle(withdrawal, actor_user_id, replayed, status: "submitted", provider_ref: ref)

      {:managed, url} ->
        settle(withdrawal, actor_user_id, replayed, status: "managed", managed_url: url)

      {:error, reason} ->
        settle(withdrawal, actor_user_id, replayed, status: "failed")
        {:error, {:gateway_error, reason}}
    end
  end

  defp settle(withdrawal, actor_user_id, replayed, changes) do
    {:ok, updated} =
      Repo.transaction(fn ->
        updated = withdrawal |> Ecto.Changeset.change(changes) |> Repo.update!()

        Audit.record(
          updated.group_id,
          actor_user_id,
          "withdrawal.#{updated.status}",
          {"withdrawal", updated.id},
          %{"amount" => updated.amount, "provider_ref" => updated.provider_ref}
        )

        updated
      end)

    {:ok, %{withdrawal: updated, replayed: replayed}}
  end

  defp check_owner(%PayoutAccount{owner_member_id: id, status: status}, %Member{id: id}) do
    if status == "active", do: :ok, else: {:error, :payout_account_not_active}
  end

  defp check_owner(_account, _member), do: {:error, :forbidden}

  defp new_withdrawal(account, actor_user_id, key, amount) do
    :ok = check_balance(account, amount)

    withdrawal =
      Repo.insert!(%Withdrawal{
        group_id: account.group_id,
        payout_account_id: account.id,
        amount: amount,
        status: "pending",
        idempotency_key: key
      })

    record_request(withdrawal, actor_user_id)
    {withdrawal, false}
  end

  # The same key after a `failed` attempt asks the gateway again, with the same reference.
  defp retry(%Withdrawal{} = failed, account, actor_user_id) do
    :ok = check_balance(account, failed.amount)
    withdrawal = failed |> Ecto.Changeset.change(status: "pending") |> Repo.update!()
    record_request(withdrawal, actor_user_id)
    {withdrawal, true}
  end

  defp record_request(withdrawal, actor_user_id) do
    Audit.record(
      withdrawal.group_id,
      actor_user_id,
      "withdrawal.request",
      {"withdrawal", withdrawal.id},
      %{
        "amount" => withdrawal.amount,
        "payout_account_id" => withdrawal.payout_account_id,
        "status" => withdrawal.status
      }
    )
  end

  # Withdrawals still `pending` have not reached the provider balance yet; they count as spent.
  defp check_balance(account, amount) do
    with {:ok, balance} <- gateway_balance(account),
         :ok <-
           if(amount <= balance - in_flight(account),
             do: :ok,
             else: {:error, :insufficient_balance}
           ) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp in_flight(account) do
    Repo.one(
      from w in Withdrawal,
        where: w.payout_account_id == ^account.id and w.status == "pending",
        select: type(coalesce(sum(w.amount), 0), :integer)
    )
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
