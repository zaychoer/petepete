defmodule Petepete.Billing.Attendance do
  @moduledoc """
  Who attended a draft session and with which weight. Public entry points are the
  `Petepete.Billing` delegates; they run in `Petepete.Billing.Editing` (session locked,
  draft-only; the caller is a host `Petepete.Actor` authorized at the edge).

  The participant must already be on the group's roster (members and guests alike);
  creating a guest is the Groups side. `weight` is integer per mil, 1000 = 1x, and must be
  positive. Without `weight` a new participant starts from the member's `default_weight`
  and an existing one keeps the weight set for this session.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Petepete.Actor
  alias Petepete.Billing.{Editing, Participant}
  alias Petepete.Groups.Member
  alias Petepete.Repo

  @max_weight 100_000
  @types %{member_id: :integer, attended: :boolean, weight: :integer}

  @spec set(Actor.t(), integer(), map()) ::
          {:ok, %Participant{}} | {:error, term()}
  def set(%Actor{} = actor, session_id, attrs) do
    Editing.run(actor, session_id, fn session, _actor ->
      with {:ok, params} <- validate(attrs),
           {:ok, member} <- fetch_member(params.member_id, session.group_id) do
        upsert(session.id, member, params)
      end
    end)
  end

  @doc "The session's participants with `member` loaded, ordered by member id."
  @spec list(integer()) :: [%Participant{}]
  def list(session_id) do
    Repo.all(
      from p in Participant,
        where: p.session_id == ^session_id,
        order_by: p.member_id,
        preload: :member
    )
  end

  defp upsert(session_id, member, params) do
    existing = Repo.get_by(Participant, session_id: session_id, member_id: member.id)

    weight = params[:weight] || (existing && existing.weight) || member.default_weight

    participant =
      (existing || %Participant{session_id: session_id, member_id: member.id})
      |> Changeset.change(%{attended: params.attended, weight: weight})
      |> Repo.insert_or_update!()

    {:ok, %{participant | member: member}}
  end

  defp fetch_member(member_id, group_id) do
    case Repo.one(from m in Member, where: m.id == ^member_id and m.group_id == ^group_id) do
      nil ->
        {:error,
         Changeset.add_error(
           {%{}, @types} |> Changeset.change(),
           :member_id,
           "must be a member of the group",
           validation: :not_in_group
         )}

      member ->
        {:ok, member}
    end
  end

  # `attrs` come from JSON: `attended` must be a real boolean, ids and weight real integers.
  defp validate(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> strict("member_id", &is_integer/1)
      |> strict("weight", &is_integer/1)
      |> strict("attended", &is_boolean/1)

    {%{}, @types}
    |> Changeset.cast(attrs, Map.keys(@types))
    |> Changeset.validate_required([:member_id, :attended])
    |> Changeset.validate_number(:weight, greater_than: 0, less_than_or_equal_to: @max_weight)
    |> case do
      %Changeset{valid?: true} = cs -> {:ok, Changeset.apply_changes(cs)}
      cs -> {:error, cs}
    end
  end

  defp strict(attrs, key, valid?) do
    value = Map.get(attrs, key)
    if is_nil(value) or valid?.(value), do: attrs, else: Map.put(attrs, key, :invalid)
  end
end
