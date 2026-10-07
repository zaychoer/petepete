defmodule Petepete.Sessions.Event do
  @moduledoc """
  What a group does, regularly (`rrule`) or once (`starts_at`).

  A recurring event carries its schedule in `rrule` (see `Petepete.Sessions.RRule`,
  time of day included as `BYHOUR`/`BYMINUTE` in WIB) and leaves `starts_at` empty; a
  one-off event has `starts_at` and no `rrule`. `cost_template` is described in
  `Petepete.Sessions.CostTemplate`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Petepete.Sessions.{CostTemplate, RRule}

  schema "events" do
    belongs_to :group, Petepete.Groups.Group
    field :name, :string
    field :type, :string
    field :rrule, :string
    field :starts_at, :utc_datetime
    field :cost_template, :map, default: %{}
    field :split_rule, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a new event of `group`, from request params (string keys).

  Params: `name` (defaults to the group's name), `type` (`recurring` | `one_off`),
  `rrule` and `time` (`"HH:MM"` WIB) for recurring, `starts_at` (ISO 8601 with a UTC
  offset) for one-off, `cost_template`, `split_rule`. The stored `rrule` is the
  canonical text including the time of day. A template item without `paid_by_member_id`
  is stored as paid by `host_member_id`, the creating host.
  """
  def create_changeset(
        %__MODULE__{} = event,
        %{id: group_id, name: group_name},
        host_member_id,
        params
      ) do
    event
    |> cast(params, [:name, :type, :split_rule])
    |> put_change(:group_id, group_id)
    |> default_name(group_name)
    |> validate_required([:type])
    |> validate_inclusion(:type, ["recurring", "one_off"])
    |> validate_length(:name, max: 120)
    |> validate_length(:split_rule, max: 50)
    |> put_schedule(params)
    |> put_cost_template(params, group_id, host_member_id)
  end

  defp default_name(changeset, group_name) do
    case get_field(changeset, :name) do
      name when is_binary(name) and name != "" -> changeset
      _ -> put_change(changeset, :name, group_name)
    end
  end

  defp put_schedule(changeset, params) do
    case get_field(changeset, :type) do
      "recurring" ->
        changeset
        |> reject_param(params, :starts_at, :one_off_only)
        |> put_rrule(params)

      "one_off" ->
        changeset
        |> reject_param(params, :rrule, :recurring_only)
        |> reject_param(params, :time, :recurring_only)
        |> put_starts_at(params)

      _ ->
        changeset
    end
  end

  defp reject_param(changeset, params, field, kind) do
    if is_nil(params[Atom.to_string(field)]),
      do: changeset,
      else: add_error(changeset, field, Atom.to_string(kind), validation: kind)
  end

  defp put_rrule(changeset, params) do
    with {:ok, rule} <- RRule.parse(params["rrule"]),
         {:ok, rule} <- add_time(rule, params["time"]) do
      put_change(changeset, :rrule, RRule.to_string(rule))
    else
      {:error, :time_required} ->
        add_error(changeset, :time, "time_required", validation: :time_required)

      {:error, {kind, opts}} ->
        field = if kind in [:time_format, :time_conflict], do: :time, else: :rrule
        add_error(changeset, field, Atom.to_string(kind), [validation: kind] ++ opts)
    end
  end

  defp add_time(%RRule{time: nil}, nil), do: {:error, :time_required}
  defp add_time(%RRule{time: %Time{}} = rule, nil), do: {:ok, rule}
  defp add_time(%RRule{} = rule, time), do: RRule.put_time(rule, time)

  defp put_starts_at(changeset, params) do
    with raw when is_binary(raw) <- params["starts_at"],
         {:ok, utc, _offset} <- DateTime.from_iso8601(raw) do
      put_change(changeset, :starts_at, DateTime.truncate(utc, :second))
    else
      nil ->
        add_error(changeset, :starts_at, "starts_at_required", validation: :starts_at_required)

      {:error, :missing_offset} ->
        add_error(changeset, :starts_at, "starts_at_offset", validation: :starts_at_offset)

      _ ->
        add_error(changeset, :starts_at, "starts_at_format", validation: :starts_at_format)
    end
  end

  defp put_cost_template(changeset, params, group_id, host_member_id) do
    case CostTemplate.cast(params["cost_template"], group_id, host_member_id) do
      {:ok, template} ->
        put_change(changeset, :cost_template, template)

      {:error, messages} ->
        Enum.reduce(messages, changeset, fn {kind, opts}, acc ->
          add_error(acc, :cost_template, Atom.to_string(kind), [validation: kind] ++ opts)
        end)
    end
  end
end
