defmodule PetepeteWeb.PayoutAccountController do
  @moduledoc """
  Rekening pencairan: the host registers themself as the group's payout account owner.
  The `audit_log` row commits in the same transaction as the `payout_accounts` row.
  """
  use PetepeteWeb, :controller

  alias Petepete.{Payments, Repo}
  alias Petepete.Groups.Group
  alias Petepete.Ledger.Audit
  alias PetepeteWeb.{LedgerError, Plugs.GroupAccess}

  plug GroupAccess, role: :host

  def create(conn, params) do
    member = conn.assigns.member
    group = Repo.get!(Group, member.group_id)
    user_id = conn.assigns.current_scope.user.id

    result =
      Repo.transaction(fn ->
        case Payments.register_payout_account(group, member, params) do
          {:ok, account} ->
            Audit.record(
              group.id,
              user_id,
              "payout_account.register",
              {"payout_account", account.id},
              %{
                "owner_member_id" => member.id,
                "provider" => account.provider,
                "bank_name" => account.bank_name,
                "account_last4" => account.account_last4
              }
            )

            account

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, account} ->
        conn
        |> put_status(201)
        |> json(%{payout_account_id: account.id, status: account.status})

      {:error, %Ecto.Changeset{} = changeset} ->
        LedgerError.render_invalid(conn, changeset_errors(changeset))

      {:error, _reason} ->
        conn
        |> put_status(502)
        |> json(%{error: "gateway_error", message: "Gateway sedang bermasalah. Coba lagi nanti."})
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
