defmodule Petepete.Repo.Migrations.AddIdempotencyKeyToPayoutAccounts do
  use Ecto.Migration

  def change do
    alter table(:payout_accounts) do
      add :idempotency_key, :string
    end

    execute "UPDATE payout_accounts SET idempotency_key = 'legacy-' || id",
            "SELECT 1"

    alter table(:payout_accounts) do
      modify :idempotency_key, :string, null: false, from: {:string, null: true}
    end

    create unique_index(:payout_accounts, [:group_id, :idempotency_key])
  end
end
