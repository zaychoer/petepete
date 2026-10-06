defmodule Petepete.Groups.Templates do
  @moduledoc """
  The group templates a host picks when creating a group, and the default cost
  categories each one fills in.

  Pure data: a group stores only the template name (`groups.template`); its cost
  categories are looked up here. A category is the label of a cost item chip
  (`cost_items.category`, at most 50 characters).
  """

  @templates [
    {"Futsal", ["Sewa lapangan", "Air minum", "Bola", "Wasit", "Parkir"]},
    {"Badminton", ["Sewa lapangan", "Shuttlecock", "Air minum", "Parkir"]},
    {"Padel", ["Sewa lapangan", "Bola", "Air minum", "Parkir"]},
    {"Mini Soccer", ["Sewa lapangan", "Wasit", "Rompi", "Air minum", "Parkir"]},
    {"Acara Umum", ["Sewa tempat", "Konsumsi", "Perlengkapan", "Lainnya"]}
  ]

  @doc "Template names, in the order they are offered."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@templates, &elem(&1, 0))

  @doc "Whether `name` is one of `names/0`."
  @spec valid?(term()) :: boolean()
  def valid?(name), do: List.keymember?(@templates, name, 0)

  @doc "The default cost categories of template `name`, or `[]` for no/unknown template."
  @spec cost_categories(String.t() | nil) :: [String.t()]
  def cost_categories(name) do
    case List.keyfind(@templates, name, 0) do
      {_, categories} -> categories
      nil -> []
    end
  end
end
