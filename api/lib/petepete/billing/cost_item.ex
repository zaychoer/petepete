defmodule Petepete.Billing.CostItem do
  @moduledoc """
  One cost of a session in rupiah; `paid_by_member` fronted it. Scope is all or subset.

  `member_ids` and `bearer_ids` are filled by `Petepete.Billing.list_cost_items/1`:
  `member_ids` are the selected members of a `subset` item (empty for `all`), `bearer_ids`
  the members who actually bear the cost, that is the attending ones in scope.
  """
  use Ecto.Schema

  schema "cost_items" do
    belongs_to :session, Petepete.Billing.Session
    field :category, :string
    field :label, :string
    field :amount, :integer
    belongs_to :paid_by_member, Petepete.Groups.Member
    field :scope, :string, default: "all"
    field :member_ids, {:array, :integer}, virtual: true, default: []
    field :bearer_ids, {:array, :integer}, virtual: true, default: []

    timestamps(type: :utc_datetime)
  end
end
