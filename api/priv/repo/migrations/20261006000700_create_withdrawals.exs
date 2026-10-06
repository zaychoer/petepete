defmodule Petepete.Repo.Migrations.CreateWithdrawals do
  use Ecto.Migration

  def change do
    create table(:withdrawals) do
      add :group_id, references(:groups), null: false
      add :payout_account_id, references(:payout_accounts), null: false
      add :amount, :bigint, null: false
      add :status, :text, null: false
      add :provider_ref, :text
      add :managed_url, :text
      add :idempotency_key, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:withdrawals, [:group_id, :id])
    create unique_index(:withdrawals, [:group_id, :idempotency_key])
    create constraint(:withdrawals, :amount_positive, check: "amount > 0")

    create constraint(:withdrawals, :status_allowed, check: "status IN ('submitted', 'managed')")
  end
end
