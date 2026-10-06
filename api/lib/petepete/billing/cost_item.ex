defmodule Petepete.Billing.CostItem do
  @moduledoc "One cost of a session in rupiah; `paid_by_member` fronted it. Scope is all or subset."
  use Ecto.Schema

  schema "cost_items" do
    belongs_to :session, Petepete.Billing.Session
    field :category, :string
    field :label, :string
    field :amount, :integer
    belongs_to :paid_by_member, Petepete.Groups.Member
    field :scope, :string, default: "all"

    timestamps(type: :utc_datetime)
  end
end
