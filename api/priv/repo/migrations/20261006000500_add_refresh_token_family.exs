defmodule Petepete.Repo.Migrations.AddRefreshTokenFamily do
  use Ecto.Migration

  def change do
    alter table(:refresh_tokens) do
      add :family_id, :uuid, null: false, default: fragment("gen_random_uuid()")
    end

    create index(:refresh_tokens, [:family_id])
  end
end
