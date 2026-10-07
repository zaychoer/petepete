defmodule Petepete.Payments.Withdrawals do
  @moduledoc """
  Tarik dana (PAY-07): the balance of a group's gateway sub-account and withdrawals from
  it to the registered bank account. Reached through `Petepete.Payments`.

  Only the payout account's owner (a host, as the `Petepete.Actor` the edge authorized) may
  withdraw. A request holds the payout account row lock while it reads the gateway balance
  and decides, so two requests cannot both spend the same balance.

  ## Durability

  A request is committed as a `pending` withdrawal (unique on `(group_id, idempotency_key)`)
  together with its `withdrawal.request` audit row, in one `Petepete.HostAction` run, before
  the gateway is called. The call happens outside any transaction with the stable reference
  `withdrawal-<id>`, which the adapter passes to the provider as idempotency key. The outcome
  is then written to the row (`submitted`, `managed`, or `failed`) with a
  `withdrawal.<status>` audit row, again through `HostAction`. While a request is `pending`
  its amount counts against the balance, so concurrent requests cannot overspend it.

  The same `Idempotency-Key` returns the stored withdrawal and never calls the gateway
  again, whatever its status (`pending`, `submitted`, `managed`), with one exception: a
  `failed` withdrawal is attempted again, on the same row and reference. A withdrawal left
  `pending` by a crash between commit and outcome is therefore NOT retried automatically
  (the provider may have executed it); it needs a manual check at the provider. The
  Ledger is not touched.

  The gateway request step is delegated to `WithdrawalIntent.request/2` so the
  `IntentReconciler` can re-drive stuck rows through the same code path.
  """
  import Ecto.Query, only: [from: 2]

  alias Petepete.{Actor, HostAction}
  alias Petepete.Groups.PayoutAccount
  alias Petepete.Payments.{WithdrawalIntent, Withdrawal}
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
  Withdraws `amount` (positive rupiah) in `group_id` for the host `actor`, who must own the
  payout account. Returns `{:ok, %{withdrawal: w, replayed: boolean}}`; see `t:error/0`.

  The request is durable before the gateway is asked (see the moduledoc): a replay returns
  the stored withdrawal whatever its status, except that a `failed` one is attempted again.
  """
  @spec withdraw(Actor.t(), pos_integer(), String.t() | nil, term()) ::
          {:ok, %{withdrawal: Withdrawal.t(), replayed: boolean()}} | {:error, error()}
  def withdraw(%Actor{} = actor, group_id, key, amount) do
    cond do
      not (is_binary(key) and String.trim(key) != "") ->
        {:error, :idempotency_key_required}

      not (is_integer(amount) and amount > 0) ->
        {:error, :amount_not_positive}

      true ->
        key = String.trim(key)

        with {:ok, step} <- accept_request(actor, group_id, key, amount) do
          run(step, actor, group_id)
        end
    end
  end

  # First transaction (HostAction): under the payout account lock, find the request by its
  # key or record a new `pending` one. HostAction writes its `withdrawal.request` audit row
  # in the same transaction, unless this is a plain replay. No gateway call happens in here.
  defp accept_request(actor, group_id, key, amount) do
    HostAction.run(actor, group_id, "withdrawal.request", fn ->
      account = group_id |> latest_account() |> Ecto.Query.lock("FOR UPDATE") |> Repo.one()

      with %PayoutAccount{} <- account || {:error, :no_payout_account},
           :ok <- check_owner(account, actor) do
        case Repo.get_by(Withdrawal, group_id: group_id, idempotency_key: key) do
          %Withdrawal{amount: ^amount, status: "failed"} = failed ->
            withdrawal = retry(failed, account)
            {:ok, {:call, account, withdrawal, true}, request_audit(withdrawal)}

          %Withdrawal{amount: ^amount} = withdrawal ->
            {:ok, {:replay, withdrawal}, %{request_audit(withdrawal) | replayed: true}}

          %Withdrawal{} ->
            {:error, :idempotency_key_conflict}

          nil ->
            withdrawal = new_withdrawal(account, key, amount)
            {:ok, {:call, account, withdrawal, false}, request_audit(withdrawal)}
        end
      end
    end)
  end

  defp run({:replay, withdrawal}, _actor, _group_id),
    do: {:ok, %{withdrawal: withdrawal, replayed: true}}

  defp run({:call, _account, withdrawal, replayed}, actor, group_id) do
    reference = "withdrawal-#{withdrawal.id}"

    case WithdrawalIntent.request(withdrawal, reference) do
      {:ok, changes} ->
        settle(actor, group_id, withdrawal, replayed, Map.to_list(changes))

      {:error, reason} ->
        settle(actor, group_id, withdrawal, replayed, status: "failed")
        {:error, {:gateway_error, reason}}
    end
  end

  # Second transaction: the outcome on the row and its `withdrawal.<status>` audit row.
  defp settle(actor, group_id, withdrawal, replayed, changes) do
    action = "withdrawal.#{Keyword.fetch!(changes, :status)}"

    {:ok, updated} =
      HostAction.run(actor, group_id, action, fn ->
        updated = withdrawal |> Ecto.Changeset.change(changes) |> Repo.update!()

        {:ok, updated,
         %{
           subject: {"withdrawal", updated.id},
           metadata: %{"amount" => updated.amount, "provider_ref" => updated.provider_ref},
           replayed: false
         }}
      end)

    {:ok, %{withdrawal: updated, replayed: replayed}}
  end

  defp check_owner(%PayoutAccount{owner_member_id: id, status: status}, %Actor{member_id: id}) do
    if status == "active", do: :ok, else: {:error, :payout_account_not_active}
  end

  defp check_owner(_account, _actor), do: {:error, :forbidden}

  defp new_withdrawal(account, key, amount) do
    :ok = check_balance(account, amount)

    Repo.insert!(%Withdrawal{
      group_id: account.group_id,
      payout_account_id: account.id,
      amount: amount,
      status: "pending",
      idempotency_key: key
    })
  end

  # The same key after a `failed` attempt asks the gateway again, with the same reference.
  defp retry(%Withdrawal{} = failed, account) do
    :ok = check_balance(account, failed.amount)
    failed |> Ecto.Changeset.change(status: "pending") |> Repo.update!()
  end

  defp request_audit(withdrawal) do
    %{
      subject: {"withdrawal", withdrawal.id},
      metadata: %{
        "amount" => withdrawal.amount,
        "payout_account_id" => withdrawal.payout_account_id,
        "status" => withdrawal.status
      },
      replayed: false
    }
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
    case Petepete.Payments.gateway().balance(id) do
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
