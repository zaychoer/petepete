defmodule Petepete.Repo.Migrations.AddOutboundIntentFields do
  use Ecto.Migration

  # ADR-0005: outbound intent pattern – schema changes for retry tracking and new statuses.
  def up do
    # payment_attempts: add retry_count
    alter table(:payment_attempts) do
      add :retry_count, :integer, null: false, default: 0
    end

    # withdrawals: add retry_count, add needs_review status, add updated_at
    alter table(:withdrawals) do
      add :retry_count, :integer, null: false, default: 0
      add :updated_at, :utc_datetime
    end

    execute "UPDATE withdrawals SET updated_at = inserted_at"

    drop constraint(:withdrawals, :status_allowed)

    create constraint(:withdrawals, :status_allowed,
             check: "status IN ('pending', 'submitted', 'managed', 'failed', 'needs_review')"
           )

    # payout_accounts: add retry_count, add registering/failed statuses,
    # make provider_account_id nullable
    alter table(:payout_accounts) do
      add :retry_count, :integer, null: false, default: 0
      modify :provider_account_id, :text, null: true, from: {:text, null: false}
    end

    drop constraint(:payout_accounts, :status_allowed)

    create constraint(:payout_accounts, :status_allowed,
             check: "status IN ('registering', 'pending_kyc', 'active', 'failed')"
           )
  end

  def down do
    alter table(:payment_attempts) do
      remove :retry_count
    end

    alter table(:withdrawals) do
      remove :retry_count
      remove :updated_at
    end

    drop constraint(:withdrawals, :status_allowed)

    create constraint(:withdrawals, :status_allowed,
             check: "status IN ('pending', 'submitted', 'managed', 'failed')"
           )

    alter table(:payout_accounts) do
      remove :retry_count
      modify :provider_account_id, :text, null: false, from: {:text, null: true}
    end

    drop constraint(:payout_accounts, :status_allowed)

    create constraint(:payout_accounts, :status_allowed,
             check: "status IN ('pending_kyc', 'active')"
           )
  end
end
