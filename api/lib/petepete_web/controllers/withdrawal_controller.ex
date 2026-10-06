defmodule PetepeteWeb.WithdrawalController do
  @moduledoc """
  Tarik dana (PAY-07), host only. The sub-account balance and the withdrawal history may
  be read by any host of the group; only the payout account's owner can withdraw (others
  get 403). Withdrawals never touch the ledger.

    * `GET /groups/:group_id/payout-account/balance`: `balance`, `payout_account_id`,
      `status`, `bank_name`, `account_last4`, `owner` (the caller owns the account) and
      `can_withdraw` (owner and the account is active).
    * `POST /groups/:group_id/withdrawals` `{"amount": rupiah}` with `Idempotency-Key`:
      `withdrawal_id`, `status` (`pending | submitted | managed | failed`), `status_label`, `managed_url`
      (set when the gateway only offers its dashboard), `replayed`; 201 or 200 on replay.
      The same key returns the stored withdrawal without asking the gateway again, except
      after `failed` (502 `gateway_error`), which is attempted again. `pending` means the
      outcome is not stored yet (the request is never repeated automatically).
    * `GET /groups/:group_id/withdrawals`: history, newest first.
  """
  use PetepeteWeb, :controller

  alias Petepete.Payments
  alias Petepete.Payments.Withdrawal
  alias PetepeteWeb.{FallbackController, LedgerError}
  alias PetepeteWeb.Plugs.{GroupAccess, IdempotencyKey}

  plug GroupAccess, role: :host
  plug IdempotencyKey when action == :create

  @status_labels %{
    "pending" => "Penarikan lagi diproses",
    "failed" => "Penarikan gagal. Coba lagi.",
    "submitted" => "Penarikan diajukan",
    "managed" => "Selesaikan di dashboard gateway"
  }

  def balance(conn, _params) do
    actor = conn.assigns.actor

    case Payments.payout_account_balance(conn.assigns.group_id) do
      {:ok, %{balance: balance, payout_account: account}} ->
        owner? = account.owner_member_id == actor.member_id

        json(conn, %{
          balance: balance,
          payout_account_id: account.id,
          status: account.status,
          bank_name: account.bank_name,
          account_last4: account.account_last4,
          owner: owner?,
          can_withdraw: owner? and account.status == "active"
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def create(conn, %{"amount" => amount}) when is_integer(amount) do
    actor = conn.assigns.actor

    case Payments.withdraw(actor, conn.assigns.group_id, conn.assigns.idempotency_key, amount) do
      {:ok, %{withdrawal: withdrawal, replayed: replayed}} ->
        conn
        |> put_status(if replayed, do: 200, else: 201)
        |> json(%{
          withdrawal_id: withdrawal.id,
          status: withdrawal.status,
          status_label: Map.fetch!(@status_labels, withdrawal.status),
          managed_url: withdrawal.managed_url,
          replayed: replayed
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def create(conn, _params) do
    LedgerError.render_invalid(conn, %{"amount" => "harus angka bulat dalam rupiah"})
  end

  def index(conn, _params) do
    withdrawals = Payments.list_withdrawals(conn.assigns.group_id)
    json(conn, %{withdrawals: Enum.map(withdrawals, &withdrawal_data/1)})
  end

  defp withdrawal_data(%Withdrawal{} = w) do
    %{
      id: w.id,
      amount: w.amount,
      status: w.status,
      status_label: Map.fetch!(@status_labels, w.status),
      provider_ref: w.provider_ref,
      managed_url: w.managed_url,
      inserted_at: w.inserted_at
    }
  end

  defp render_error(conn, :forbidden), do: FallbackController.call(conn, {:error, :forbidden})

  defp render_error(conn, {:gateway_error, _reason}) do
    conn
    |> put_status(502)
    |> json(%{error: "gateway_error", message: "Gateway sedang bermasalah. Coba lagi nanti."})
  end

  defp render_error(conn, reason), do: LedgerError.render(conn, reason)
end
