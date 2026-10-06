defmodule Petepete.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :phone, :text, null: false
      add :display_name, :text, null: false
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:phone])

    create table(:otp_challenges) do
      add :phone_hash, :binary, null: false
      add :code_hash, :binary, null: false
      add :ip, :text
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:otp_challenges, [:phone_hash])
    create index(:otp_challenges, [:expires_at])

    create table(:refresh_tokens) do
      add :user_id, references(:users), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:refresh_tokens, [:token_hash])
    create index(:refresh_tokens, [:user_id])
  end
end
