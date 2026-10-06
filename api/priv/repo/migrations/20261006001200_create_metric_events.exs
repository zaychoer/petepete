defmodule Petepete.Repo.Migrations.CreateMetricEvents do
  use Ecto.Migration

  # MVP success metrics (PP-REL-02). Deliberately no phone numbers, names or user ids:
  # only the group, the session or bill the event is about, and a duration.
  def change do
    create table(:metric_events) do
      add :group_id, references(:groups), null: false
      add :name, :text, null: false
      # No foreign key on purpose: it would take a KEY SHARE lock on the session row from
      # commands that only hold bill locks (cash, webhook), against the lock order
      # session -> bills and deadlocking with `void_issue`. The bill and group rows are
      # already locked by, or never contended with, those commands.
      add :session_id, :bigint
      add :bill_id, references(:bills)
      add :value_ms, :bigint

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:metric_events, [:name, :inserted_at])

    create constraint(:metric_events, :name_allowed,
             check:
               "name IN ('session_build_duration', 'bills_sent', 'time_to_paid', 'paid_without_install')"
           )

    create constraint(:metric_events, :value_ms_non_negative,
             check: "value_ms IS NULL OR value_ms >= 0"
           )

    # Each event happens once: a retry or a re-run records nothing.
    create unique_index(:metric_events, [:name, :session_id],
             where: "name = 'session_build_duration'",
             name: :metric_events_session_once
           )

    create unique_index(:metric_events, [:name, :bill_id],
             where: "bill_id IS NOT NULL",
             name: :metric_events_bill_once
           )
  end
end
