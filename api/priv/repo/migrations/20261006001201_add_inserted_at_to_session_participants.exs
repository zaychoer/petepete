defmodule Petepete.Repo.Migrations.AddInsertedAtToSessionParticipants do
  use Ecto.Migration

  # `session_build_duration` (PP-REL-02) starts at the first cost or attendance edit of a
  # draft session; attendance rows need a creation time for that.
  def change do
    alter table(:session_participants) do
      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end
  end
end
