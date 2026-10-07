defmodule Petepete.Repo.Migrations.CreateLedger do
  use Ecto.Migration

  @cancel_kinds "('session_bills_cancelled', 'cash_payment_cancelled', 'correction')"

  def up do
    create table(:ledger_txns) do
      add :group_id, references(:groups), null: false
      add :kind, :text, null: false
      add :ref_type, :text
      add :ref_id, :bigint
      add :actor_type, :text, null: false
      add :actor_user_id, references(:users)
      add :reverses_txn_id, references(:ledger_txns)
      add :reason, :text
      add :idempotency_key, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ledger_txns, [:group_id, :id])
    create unique_index(:ledger_txns, [:reverses_txn_id])
    create unique_index(:ledger_txns, [:idempotency_key])

    create constraint(:ledger_txns, :kind_allowed,
             check: """
             kind IN ('session_billed', 'gateway_payment_received', 'cash_received',
                      'settlement', 'kas_spend', 'session_bills_cancelled',
                      'cash_payment_cancelled', 'correction')
             """
           )

    create constraint(:ledger_txns, :reverses_only_for_cancel_kinds,
             check: "reverses_txn_id IS NULL OR kind IN #{@cancel_kinds}"
           )

    create constraint(:ledger_txns, :reason_required_for_cancel_kinds,
             check: "kind NOT IN #{@cancel_kinds} OR (reason IS NOT NULL AND reason <> '')"
           )

    create constraint(:ledger_txns, :actor_matches_type,
             check: """
             (actor_type = 'host' AND actor_user_id IS NOT NULL)
             OR (actor_type = 'gateway' AND actor_user_id IS NULL)
             """
           )

    create table(:ledger_entries) do
      add :txn_id, references(:ledger_txns), null: false
      add :group_id, references(:groups), null: false
      add :account_type, :text, null: false
      add :member_id, references(:group_members)
      add :amount, :bigint, null: false
    end

    create index(:ledger_entries, [:txn_id])
    create index(:ledger_entries, [:group_id, :member_id])

    create constraint(:ledger_entries, :account_matches_member,
             check: """
             (account_type = 'member' AND member_id IS NOT NULL)
             OR (account_type = 'kas' AND member_id IS NULL)
             """
           )

    execute """
            CREATE FUNCTION ledger_check_txn_balanced() RETURNS trigger AS $$
            DECLARE
              total bigint;
            BEGIN
              SELECT COALESCE(SUM(amount), 0) INTO total
                FROM ledger_entries WHERE txn_id = NEW.txn_id;

              IF total <> 0 THEN
                RAISE EXCEPTION 'ledger txn % is unbalanced: entries sum to %', NEW.txn_id, total
                  USING ERRCODE = 'check_violation', CONSTRAINT = 'ledger_txn_balanced';
              END IF;

              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION ledger_check_txn_balanced()"

    execute """
            CREATE CONSTRAINT TRIGGER ledger_entries_balanced
              AFTER INSERT ON ledger_entries
              DEFERRABLE INITIALLY DEFERRED
              FOR EACH ROW EXECUTE FUNCTION ledger_check_txn_balanced()
            """,
            "DROP TRIGGER ledger_entries_balanced ON ledger_entries"

    execute """
            CREATE FUNCTION ledger_reject_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION '% on % is not allowed: the ledger is append-only', TG_OP, TG_TABLE_NAME
                USING ERRCODE = 'restrict_violation';
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION ledger_reject_mutation()"

    for table <- ~w(ledger_entries ledger_txns) do
      execute """
              CREATE TRIGGER #{table}_immutable
                BEFORE UPDATE OR DELETE ON #{table}
                FOR EACH ROW EXECUTE FUNCTION ledger_reject_mutation()
              """,
              "DROP TRIGGER #{table}_immutable ON #{table}"
    end
  end

  def down do
    execute "DROP TABLE ledger_entries"
    execute "DROP TABLE ledger_txns"
    execute "DROP FUNCTION ledger_check_txn_balanced()"
    execute "DROP FUNCTION ledger_reject_mutation()"
  end
end
