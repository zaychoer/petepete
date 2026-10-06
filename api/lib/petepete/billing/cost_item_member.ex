defmodule Petepete.Billing.CostItemMember do
  @moduledoc "A member who bears a `subset`-scoped cost item."
  use Ecto.Schema

  @primary_key false
  schema "cost_item_members" do
    belongs_to :cost_item, Petepete.Billing.CostItem, primary_key: true
    belongs_to :member, Petepete.Groups.Member, primary_key: true
  end
end
