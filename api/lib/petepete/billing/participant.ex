defmodule Petepete.Billing.Participant do
  @moduledoc "A member's attendance and weight (integer per mil) at a session."
  use Ecto.Schema

  @primary_key false
  schema "session_participants" do
    belongs_to :session, Petepete.Billing.Session, primary_key: true
    belongs_to :member, Petepete.Groups.Member, primary_key: true
    field :attended, :boolean, default: false
    field :weight, :integer, default: 1000

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
