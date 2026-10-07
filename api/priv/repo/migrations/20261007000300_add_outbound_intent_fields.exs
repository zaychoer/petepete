defmodule Petepete.Repo.Migrations.AddOutboundIntentFields do
  use Ecto.Migration

  def up do
    # payment_attempts: add retry_count
    alter table(:payment_attempts) do
      add :retry_count, :integer, null: false, default: 0
    end

    # withdrawals: add retry_count, extend status check constraint
    alter table(:withdrawals) do
      add :retry_count, :integer, null: false, default: 0
    end

    drop constraint(:withdrawals, :status_allowed)

    create constraint(:withdrawals, :status_allowed,
             check: "status IN ('pending', 'submitted', 'managed', 'failed', 'needs_review')"
           )

    # payout_accounts: add retry_count, make provider_account_id nullable, extend status check
    alter table(:payout_accounts) do
      add :retry_count, :integer, null: false, default: 0
      modify :provider_account_id, :text, null: true, from: {:text, null: false}
    end

    drop constraint(:payout_accounts, :status_allowed)

    create constraint(:payout_accounts, :status_allowed,
             check: "status IN ('pending_kyc', 'active', 'registering', 'failed')"
           )
  end

  def down do
    # payout_accounts: revert
    drop constraint(:payout_accounts, :status_allowed)

    create constraint(:payout_accounts, :status_allowed,
             check: "status IN ('pending_kyc', 'active')"
           )

    alter table(:payout_accounts) do
      remove :retry_count
      modify :provider_account_id, :text, null: false, from: {:text, null: true}
    end

    # withdrawals: revert
    drop constraint(:withdrawals, :status_allowed)

    create constraint(:withdrawals, :status_allowed,
             check: "status IN ('pending', 'submitted', 'managed', 'failed')"
           )

    alter table(:withdrawals) do
      remove :retry_count
    end

    # payment_attempts: revert
    alter table(:payment_attempts) do
      remove :retry_count
    end
  end
end
