defmodule Petepete.Ledger.AuditLog do
  @moduledoc "Record of every host action that changes money."
  use Ecto.Schema

  schema "audit_log" do
    belongs_to :group, Petepete.Groups.Group
    belongs_to :actor_user, Petepete.Accounts.User
    field :action, :string
    field :subject_type, :string
    field :subject_id, :integer
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
