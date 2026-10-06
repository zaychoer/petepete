defmodule Petepete.Sessions.CostTemplate do
  @moduledoc """
  The cost items an event starts each session with (`events.cost_template`, jsonb).

  Stored shape, after `cast/2` normalises it:

      %{"items" => [
        %{"category" => "lapangan", "label" => nil, "amount" => 350_000,
          "scope" => "all", "paid_by_member_id" => 12, "member_ids" => []}
      ]}

  `amount` is integer rupiah (a float or string is rejected), `scope` is `"all"` or
  `"subset"`; a subset item needs `member_ids`. `paid_by_member_id` and every member id
  must be on the event's group roster. An item without `paid_by_member_id` is paid by the
  host who creates the event (the default payer). An empty template (`%{}`) is valid.
  """
  import Ecto.Query, only: [from: 2]

  alias Petepete.Groups.Member
  alias Petepete.Repo

  @doc """
  Validates and normalises a template for `group_id`; an item that names no payer is paid
  by `default_payer_id`. Errors are `{kind, opts}` pairs worded for clients by `PetepeteWeb.FieldErrors`.
  """
  @spec cast(term(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, [{atom(), keyword()}]}
  def cast(nil, _group_id, _default_payer_id), do: {:ok, %{"items" => []}}

  def cast(template, _group_id, _default_payer_id) when template == %{},
    do: {:ok, %{"items" => []}}

  def cast(%{"items" => items}, group_id, default_payer_id) when is_list(items) do
    {normalised, errors} =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, n} -> cast_item(item, n, default_payer_id) end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    errors = Enum.flat_map(errors, fn {:error, messages} -> messages end)
    normalised = Enum.map(normalised, fn {:ok, item} -> item end)

    with [] <- errors,
         [] <- roster_errors(normalised, group_id) do
      {:ok, %{"items" => normalised}}
    else
      messages -> {:error, messages}
    end
  end

  def cast(_other, _group_id, _default_payer_id),
    do: {:error, [{:cost_template_shape, []}]}

  defp cast_item(%{} = item, n, default_payer_id) do
    category = item["category"]
    amount = item["amount"]
    scope = Map.get(item, "scope", "all")
    paid_by = Map.get(item, "paid_by_member_id") || default_payer_id
    member_ids = Map.get(item, "member_ids") || []
    label = item["label"]

    errors =
      Enum.reject(
        [
          not (is_binary(category) and String.trim(category) != "") &&
            {:cost_item_category, item: n},
          not (is_integer(amount) and amount > 0) &&
            {:cost_item_amount, item: n},
          scope not in ["all", "subset"] && {:cost_item_scope, item: n},
          not (is_nil(label) or is_binary(label)) && {:cost_item_label, item: n},
          not (is_nil(paid_by) or is_integer(paid_by)) &&
            {:cost_item_paid_by, item: n},
          not (is_list(member_ids) and Enum.all?(member_ids, &is_integer/1)) &&
            {:cost_item_member_ids, item: n},
          (scope == "subset" and member_ids == []) && {:cost_item_subset_members, item: n}
        ],
        &(&1 == false)
      )

    case errors do
      [] ->
        {:ok,
         %{
           "category" => String.trim(category),
           "label" => label,
           "amount" => amount,
           "scope" => scope,
           "paid_by_member_id" => paid_by,
           "member_ids" => if(scope == "subset", do: Enum.uniq(member_ids), else: [])
         }}

      errors ->
        {:error, errors}
    end
  end

  defp cast_item(_other, n, _default_payer_id), do: {:error, [{:cost_item_not_object, item: n}]}

  defp roster_errors([], _group_id), do: []

  defp roster_errors(items, group_id) do
    wanted =
      items
      |> Enum.flat_map(&[&1["paid_by_member_id"] | &1["member_ids"]])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    on_roster =
      Repo.all(from m in Member, where: m.group_id == ^group_id and m.id in ^wanted, select: m.id)

    case wanted -- on_roster do
      [] -> []
      missing -> [{:cost_template_members_not_in_group, ids: Enum.sort(missing)}]
    end
  end

  @doc "The template's items as attribute maps for `Petepete.Billing.copy_session_inputs/2`."
  @spec items(map() | nil) :: [map()]
  def items(%{"items" => items}) when is_list(items) do
    for item <- items do
      %{
        category: item["category"],
        label: item["label"],
        amount: item["amount"],
        scope: item["scope"],
        paid_by_member_id: item["paid_by_member_id"],
        member_ids: item["member_ids"]
      }
    end
  end

  def items(_template), do: []
end
