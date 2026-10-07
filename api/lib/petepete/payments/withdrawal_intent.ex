defmodule Petepete.Payments.WithdrawalIntent do
  @moduledoc """
  Outbound intent for withdrawals (ADR-0005).

  `prepare` = the current `accept_request` logic (under HostAction; use with `prepare_only`).
  `request` = `gateway.withdraw`.
  `settle` = write provider data or mark failed (second HostAction transaction).
  `recover` = check `gateway.withdrawal_status(reference)`: `:submitted/:managed` → settle
  immediately, `:not_found` → `:redrive`, `:unsupported` → `:needs_review`.
  """
  @behaviour Petepete.Payments.OutboundIntent

  import Ecto.Query, only: [from: 2]

  alias Petepete.Groups.PayoutAccount
  alias Petepete.Payments
  alias Petepete.Payments.Withdrawal
  alias Petepete.Repo

  @impl true
  def kind, do: "withdrawal"

  @impl true
  def prepare(%{account: account, key: key, amount: amount}) do
    case Repo.get_by(Withdrawal, group_id: account.group_id, idempotency_key: key) do
      %Withdrawal{amount: ^amount, status: "failed"} = failed ->
        withdrawal = retry(failed, account)
        {:ok, withdrawal, "withdrawal-#{withdrawal.id}"}

      %Withdrawal{amount: ^amount} = withdrawal ->
        {:ok, withdrawal, "withdrawal-#{withdrawal.id}"}

      %Withdrawal{} ->
        {:error, :idempotency_key_conflict}

      nil ->
        withdrawal = new_withdrawal(account, key, amount)
        {:ok, withdrawal, "withdrawal-#{withdrawal.id}"}
    end
  end

  @impl true
  def request(row, reference) do
    withdrawal = Repo.get!(Withdrawal, row.id)
    account = Repo.get!(PayoutAccount, withdrawal.payout_account_id)

    case Payments.gateway().withdraw(account.provider_account_id, withdrawal.amount, reference) do
      {:ok, %{provider_ref: ref}} ->
        {:ok, %{status: "submitted", provider_ref: ref}}

      {:managed, url} ->
        {:ok, %{status: "managed", managed_url: url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def settle(row, {:ok, changes}) do
    withdrawal = Repo.get!(Withdrawal, row.id)
    updated = withdrawal |> Ecto.Changeset.change(Map.to_list(changes)) |> Repo.update!()
    {:ok, updated}
  end

  def settle(row, {:error, _reason}) do
    withdrawal = Repo.get!(Withdrawal, row.id)
    updated = withdrawal |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
    {:ok, updated}
  end

  @impl true
  def stuck(threshold) do
    Repo.all(
      from w in Withdrawal,
        where: w.status == "pending" and w.inserted_at < ^threshold,
        order_by: w.id
    )
  end

  @impl true
  def recover(row) do
    reference = "withdrawal-#{row.id}"
    gateway = Payments.gateway()

    if function_exported?(gateway, :withdrawal_status, 1) do
      case gateway.withdrawal_status(reference) do
        {:ok, :submitted} -> :redrive
        {:ok, :managed} -> :redrive
        {:ok, :not_found} -> :redrive
        {:error, :unsupported} -> :needs_review
        {:error, _} -> :needs_review
      end
    else
      :needs_review
    end
  end

  # -- Private helpers (moved from Withdrawals) --

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

  defp retry(%Withdrawal{} = failed, account) do
    :ok = check_balance(account, failed.amount)
    failed |> Ecto.Changeset.change(status: "pending") |> Repo.update!()
  end

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
end
