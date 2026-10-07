defmodule Petepete.Payments.PayoutRegistrationIntent do
  @moduledoc """
  Outbound intent for payout account registration (ADR-0005).

  `prepare` = find by idempotency key or insert a `registering` row (no provider_account_id).
  `request` = `gateway.register_payout_account`.
  `settle` = update status to `pending_kyc`/`active` and set `provider_account_id`.
  `recover` = always `:fail` (no full account number stored to re-drive).
  """
  @behaviour Petepete.Payments.OutboundIntent

  alias Petepete.Groups.PayoutAccount
  alias Petepete.Payments
  alias Petepete.Repo

  @impl true
  def kind, do: "payout_registration"

  @impl true
  def prepare(%{
        group_id: group_id,
        owner_member_id: owner_member_id,
        bank: bank,
        idempotency_key: key,
        gateway: gateway
      }) do
    case Repo.get_by(PayoutAccount, group_id: group_id, idempotency_key: key) do
      %PayoutAccount{} = account ->
        {:ok, account, "payout-reg-#{account.id}"}

      nil ->
        account =
          Repo.insert!(%PayoutAccount{
            group_id: group_id,
            owner_member_id: owner_member_id,
            provider: gateway.provider(),
            status: "registering",
            bank_name: bank.bank_name,
            account_last4: String.slice(bank.account_number, -4, 4),
            idempotency_key: key
          })

        {:ok, account, "payout-reg-#{account.id}"}
    end
  end

  @impl true
  def request(row, _reference) do
    gateway = Payments.gateway()
    account = Repo.get!(PayoutAccount, row.id)

    # We need the original registration request data. The gateway module receives the
    # same request shape; we reconstruct it from what we stored plus look up names.
    group = Repo.get!(Petepete.Groups.Group, account.group_id)
    owner = Repo.get!(Petepete.Groups.Member, account.owner_member_id)

    # The bank details need the full account number which we don't store (only last4).
    # For the initial request this is passed through args; for re-drives it's unavailable.
    # We use the request_data stored in process dict by the caller for the initial call.
    bank = Process.get({__MODULE__, :bank_details})

    if bank do
      gateway.register_payout_account(%{
        group_id: group.id,
        group_name: group.name,
        owner_member_id: owner.id,
        owner_name: owner.display_name,
        bank: bank
      })
    else
      # Cannot re-drive without the full account number
      {:error, :cannot_redrive_registration}
    end
  end

  @impl true
  def settle(row, {:ok, result}) do
    account = Repo.get!(PayoutAccount, row.id)

    updated =
      account
      |> Ecto.Changeset.change(
        provider_account_id: result.provider_account_id,
        status: Atom.to_string(result.status)
      )
      |> Repo.update!()

    {:ok, updated}
  end

  def settle(row, {:error, reason}) do
    account = Repo.get!(PayoutAccount, row.id)
    updated = account |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
    {:error, {:registration_failed, updated, reason}}
  end

  @impl true
  def stuck(threshold) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from a in PayoutAccount,
        where: a.status == "registering" and a.inserted_at < ^threshold,
        order_by: a.id
    )
  end

  @impl true
  def recover(_row), do: :fail
end
