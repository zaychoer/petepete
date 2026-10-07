defmodule Petepete.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :name, :text, null: false
      add :template, :text
      add :rounding_unit, :integer, null: false, default: 1000
      add :invite_token, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:invite_token])
    create constraint(:groups, :rounding_unit_allowed, check: "rounding_unit IN (500, 1000)")

    create table(:group_members) do
      add :group_id, references(:groups), null: false
      add :user_id, references(:users)
      add :claim_user_id, references(:users)
      add :display_name, :text, null: false
      add :phone, :text
      add :role, :text, null: false
      add :default_weight, :integer, null: false, default: 1000

      timestamps(type: :utc_datetime)
    end

    create index(:group_members, [:group_id])
    create index(:group_members, [:user_id])

    create unique_index(:group_members, [:group_id, :user_id], where: "user_id IS NOT NULL")

    create constraint(:group_members, :role_allowed, check: "role IN ('host', 'member', 'guest')")
    create constraint(:group_members, :default_weight_positive, check: "default_weight > 0")

    create table(:payout_accounts) do
      add :group_id, references(:groups), null: false
      add :owner_member_id, references(:group_members), null: false
      add :provider, :text, null: false
      add :provider_account_id, :text, null: false
      add :status, :text, null: false, default: "pending_kyc"
      add :bank_name, :text
      add :account_last4, :text

      timestamps(type: :utc_datetime)
    end

    create index(:payout_accounts, [:group_id])

    create constraint(:payout_accounts, :status_allowed,
             check: "status IN ('pending_kyc', 'active')"
           )
  end
end
