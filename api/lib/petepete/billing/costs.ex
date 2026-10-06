defmodule Petepete.Billing.Costs do
  @moduledoc """
  Cost items of a draft session: input, payer (talangan) and the members a `subset` item
  is limited to. Public entry points are the `Petepete.Billing` delegates; they run in
  `Petepete.Billing.Editing` (session locked, draft-only; the caller is a host `Petepete.Actor` authorized at the edge).

  Rules: `amount` is positive integer rupiah (floats and numeric strings are rejected);
  `paid_by` defaults to the acting host and may be any member of the group; a `subset`
  item names at least one member of the group, an `all` item stores none. The check that
  every item has an attending bearer belongs to issuing; `without_bearers/1` feeds it.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Petepete.Actor
  alias Petepete.Billing.{CostItem, CostItemMember, Editing, Participant}
  alias Petepete.Groups.Member
  alias Petepete.Repo

  @max_amount 1_000_000_000_000
  @types %{
    category: :string,
    label: :string,
    amount: :integer,
    paid_by: :integer,
    scope: :string,
    members: {:array, :integer}
  }
  @scopes ~w(all subset)

  @spec create(Actor.t(), integer(), map()) ::
          {:ok, %CostItem{}} | {:error, term()}
  def create(%Actor{} = actor, session_id, attrs) do
    Editing.run(actor, session_id, fn session, actor ->
      with {:ok, params} <- validate(attrs, actor, session.group_id) do
        %CostItem{session_id: session.id} |> save(params)
      end
    end)
  end

  @spec update(Actor.t(), integer(), integer(), map()) ::
          {:ok, %CostItem{}} | {:error, term()}
  def update(%Actor{} = actor, session_id, cost_item_id, attrs) do
    Editing.run(actor, session_id, fn session, actor ->
      with {:ok, item} <- fetch(session.id, cost_item_id),
           {:ok, params} <- validate(attrs, actor, session.group_id) do
        save(item, params)
      end
    end)
  end

  @spec delete(Actor.t(), integer(), integer()) ::
          {:ok, %CostItem{}} | {:error, term()}
  def delete(%Actor{} = actor, session_id, cost_item_id) do
    Editing.run(actor, session_id, fn session, _actor ->
      with {:ok, item} <- fetch(session.id, cost_item_id) do
        # cost_item_members rows go with it (ON DELETE CASCADE)
        {:ok, Repo.delete!(item)}
      end
    end)
  end

  @doc "The session's cost items in input order with `member_ids`, `bearer_ids` and payer loaded."
  @spec list(integer()) :: [%CostItem{}]
  def list(session_id) do
    items =
      Repo.all(
        from c in CostItem,
          where: c.session_id == ^session_id,
          order_by: c.id,
          preload: :paid_by_member
      )

    selected =
      from(cm in CostItemMember,
        where: cm.cost_item_id in ^Enum.map(items, & &1.id),
        order_by: cm.member_id,
        select: {cm.cost_item_id, cm.member_id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    attending =
      from(p in Participant,
        where: p.session_id == ^session_id and p.attended,
        order_by: p.member_id,
        select: p.member_id
      )
      |> Repo.all()

    Enum.map(items, fn item ->
      member_ids = Map.get(selected, item.id, [])
      %{item | member_ids: member_ids, bearer_ids: bearers(item.scope, member_ids, attending)}
    end)
  end

  @doc "Items nobody attending bears; issuing is blocked while this is not empty."
  @spec without_bearers(integer()) :: [%CostItem{}]
  def without_bearers(session_id), do: Enum.filter(list(session_id), &(&1.bearer_ids == []))

  defp bearers("all", _member_ids, attending), do: attending
  defp bearers("subset", member_ids, attending), do: Enum.filter(attending, &(&1 in member_ids))

  defp fetch(session_id, cost_item_id) when is_integer(cost_item_id) do
    case Repo.get_by(CostItem, id: cost_item_id, session_id: session_id) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  defp fetch(_session_id, _cost_item_id), do: {:error, :not_found}

  defp save(item, params) do
    item =
      item
      |> Changeset.change(%{
        category: params.category,
        label: params.label,
        amount: params.amount,
        paid_by_member_id: params.paid_by,
        scope: params.scope
      })
      |> Repo.insert_or_update!()

    from(cm in CostItemMember, where: cm.cost_item_id == ^item.id) |> Repo.delete_all()

    Repo.insert_all(
      CostItemMember,
      Enum.map(params.members, &%{cost_item_id: item.id, member_id: &1})
    )

    {:ok, Enum.find(list(item.session_id), &(&1.id == item.id))}
  end

  # `attrs` come from JSON: only real integers pass as rupiah amounts and member ids.
  defp validate(attrs, actor, group_id) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.update("scope", "all", &(&1 || "all"))
      |> strict("amount", &is_integer/1)
      |> strict("paid_by", &is_integer/1)
      |> strict("members", &(is_list(&1) and Enum.all?(&1, fn id -> is_integer(id) end)))

    {%{}, @types}
    |> Changeset.cast(attrs, Map.keys(@types))
    |> Changeset.update_change(:category, &String.trim/1)
    |> Changeset.validate_required([:category, :amount])
    |> Changeset.validate_length(:category, max: 50)
    |> Changeset.validate_length(:label, max: 100)
    |> Changeset.validate_number(:amount, greater_than: 0, less_than_or_equal_to: @max_amount)
    |> Changeset.validate_inclusion(:scope, @scopes)
    |> validate_members(group_id)
    |> validate_payer(group_id)
    |> case do
      %Changeset{valid?: true} = cs -> {:ok, params(cs, actor)}
      cs -> {:error, cs}
    end
  end

  defp strict(attrs, key, valid?) do
    value = Map.get(attrs, key)
    if is_nil(value) or valid?.(value), do: attrs, else: Map.put(attrs, key, :invalid)
  end

  defp params(cs, %Actor{member_id: host_member_id}) do
    scope = Changeset.get_field(cs, :scope)

    %{
      category: Changeset.get_field(cs, :category),
      label: Changeset.get_field(cs, :label),
      amount: Changeset.get_field(cs, :amount),
      paid_by: Changeset.get_field(cs, :paid_by) || host_member_id,
      scope: scope,
      members: if(scope == "subset", do: Enum.uniq(Changeset.get_field(cs, :members)), else: [])
    }
  end

  defp validate_members(%Changeset{valid?: false} = cs, _group_id), do: cs

  defp validate_members(cs, group_id) do
    case {Changeset.get_field(cs, :scope), Enum.uniq(Changeset.get_field(cs, :members) || [])} do
      {"subset", []} ->
        Changeset.add_error(cs, :members, "must name at least one member for a subset cost",
          validation: :members_required
        )

      {"subset", ids} ->
        if all_in_group?(ids, group_id),
          do: cs,
          else:
            Changeset.add_error(cs, :members, "must all belong to the group",
              validation: :members_not_in_group
            )

      _ ->
        cs
    end
  end

  defp validate_payer(%Changeset{valid?: false} = cs, _group_id), do: cs

  defp validate_payer(cs, group_id) do
    case Changeset.get_field(cs, :paid_by) do
      nil ->
        cs

      id ->
        if all_in_group?([id], group_id),
          do: cs,
          else:
            Changeset.add_error(cs, :paid_by, "must be a member of the group",
              validation: :not_in_group
            )
    end
  end

  defp all_in_group?(ids, group_id) do
    Repo.aggregate(from(m in Member, where: m.group_id == ^group_id and m.id in ^ids), :count) ==
      length(ids)
  end
end
