defmodule Petepete.Repo.Migrations.CreateBilling do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :group_id, references(:groups), null: false
      add :name, :text, null: false
      add :type, :text, null: false
      add :rrule, :text
      add :starts_at, :utc_datetime
      add :cost_template, :map, null: false, default: %{}
      add :split_rule, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:events, [:group_id])
    create constraint(:events, :type_allowed, check: "type IN ('recurring', 'one_off')")

    create table(:sessions) do
      add :event_id, references(:events), null: false
      add :group_id, references(:groups), null: false
      add :starts_at, :utc_datetime, null: false
      add :status, :text, null: false, default: "draft"
      add :issue_txn_id, references(:ledger_txns)

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:group_id, :starts_at])
    create unique_index(:sessions, [:event_id, :starts_at], where: "status <> 'cancelled'")

    create constraint(:sessions, :status_allowed,
             check: "status IN ('draft', 'issued', 'cancelled')"
           )

    create table(:cost_items) do
      add :session_id, references(:sessions), null: false
      add :category, :text, null: false
      add :label, :text
      add :amount, :bigint, null: false
      add :paid_by_member_id, references(:group_members)
      add :scope, :text, null: false, default: "all"

      timestamps(type: :utc_datetime)
    end

    create index(:cost_items, [:session_id])
    create constraint(:cost_items, :amount_positive, check: "amount > 0")
    create constraint(:cost_items, :scope_allowed, check: "scope IN ('all', 'subset')")

    create table(:cost_item_members, primary_key: false) do
      add :cost_item_id, references(:cost_items, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :member_id, references(:group_members), null: false, primary_key: true
    end

    create table(:session_participants, primary_key: false) do
      add :session_id, references(:sessions), null: false, primary_key: true
      add :member_id, references(:group_members), null: false, primary_key: true
      add :attended, :boolean, null: false, default: false
      add :weight, :integer, null: false, default: 1000
    end

    create constraint(:session_participants, :weight_positive, check: "weight > 0")

    create table(:bills) do
      add :session_id, references(:sessions), null: false
      add :member_id, references(:group_members), null: false
      add :share, :bigint, null: false
      add :credit_applied, :bigint, null: false, default: 0
      add :amount_due, :bigint, null: false
      add :status, :text, null: false, default: "unpaid"
      add :paid_via, :text
      add :paid_txn_id, references(:ledger_txns)
      add :paid_at, :utc_datetime
      add :pay_token, :text, null: false
      add :token_expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bills, [:session_id, :member_id], where: "status <> 'void'")
    create unique_index(:bills, [:pay_token])
    create index(:bills, [:member_id])

    create constraint(:bills, :amounts_non_negative,
             check: "share >= 0 AND credit_applied >= 0 AND amount_due >= 0"
           )

    create constraint(:bills, :status_allowed,
             check: "status IN ('unpaid', 'paid', 'void', 'needs_review')"
           )

    create constraint(:bills, :paid_via_allowed,
             check: "paid_via IS NULL OR paid_via IN ('gateway', 'cash', 'credit')"
           )

    create table(:payment_attempts) do
      add :bill_id, references(:bills), null: false
      add :seq, :integer, null: false
      add :external_id, :text, null: false
      add :provider, :text, null: false
      add :method, :text, null: false
      add :provider_ref, :text
      add :amount_due, :bigint, null: false
      add :fee, :bigint, null: false
      add :gross_amount, :bigint, null: false
      add :paid_amount, :bigint
      add :status, :text, null: false, default: "pending"
      add :action, :map
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_attempts, [:external_id])
    create unique_index(:payment_attempts, [:bill_id, :seq])

    create constraint(:payment_attempts, :status_allowed,
             check: "status IN ('pending', 'paid', 'expired', 'failed', 'cancelled')"
           )

    create table(:gateway_notifications) do
      add :provider, :text, null: false
      add :provider_txn_id, :text, null: false
      add :provider_status, :text, null: false
      add :payload, :map, null: false
      add :outcome, :text
      add :processed_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:gateway_notifications, [:provider, :provider_txn_id, :provider_status])

    create table(:audit_log) do
      add :group_id, references(:groups), null: false
      add :actor_user_id, references(:users)
      add :action, :text, null: false
      add :subject_type, :text
      add :subject_id, :bigint
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_log, [:group_id, :id])
  end
end
