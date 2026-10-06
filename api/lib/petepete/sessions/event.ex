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
  canonical text including the time of day.
  """
  def create_changeset(%__MODULE__{} = event, %{id: group_id, name: group_name}, params) do
    event
    |> cast(params, [:name, :type, :split_rule])
    |> put_change(:group_id, group_id)
    |> default_name(group_name)
    |> validate_required([:type])
    |> validate_inclusion(:type, ["recurring", "one_off"])
    |> validate_length(:name, max: 120)
    |> validate_length(:split_rule, max: 50)
    |> put_schedule(params)
    |> put_cost_template(params, group_id)
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
        |> reject_param(params, :starts_at, "is for one-off events; give rrule and time")
        |> put_rrule(params)

      "one_off" ->
        changeset
        |> reject_param(params, :rrule, "is for recurring events; give starts_at")
        |> reject_param(params, :time, "is for recurring events; give starts_at")
        |> put_starts_at(params)

      _ ->
        changeset
    end
  end

  defp reject_param(changeset, params, field, message) do
    if is_nil(params[Atom.to_string(field)]),
      do: changeset,
      else: add_error(changeset, field, message)
  end

  defp put_rrule(changeset, params) do
    with {:ok, rule} <- RRule.parse(params["rrule"]),
         {:ok, rule} <- add_time(rule, params["time"]) do
      put_change(changeset, :rrule, RRule.to_string(rule))
    else
      {:error, :time_required} ->
        add_error(
          changeset,
          :time,
          "is required (HH:MM in WIB), or give BYHOUR/BYMINUTE in rrule"
        )

      {:error, message} when is_binary(message) ->
        field = if String.starts_with?(message, "time "), do: :time, else: :rrule
        add_error(changeset, field, message)
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
        add_error(changeset, :starts_at, "is required for a one-off event")

      {:error, :missing_offset} ->
        add_error(changeset, :starts_at, "needs a UTC offset, e.g. 2026-10-08T19:00:00+07:00")

      _ ->
        add_error(
          changeset,
          :starts_at,
          "must be an ISO 8601 date and time, e.g. 2026-10-08T19:00:00+07:00"
        )
    end
  end

  defp put_cost_template(changeset, params, group_id) do
    case CostTemplate.cast(params["cost_template"], group_id) do
      {:ok, template} ->
        put_change(changeset, :cost_template, template)

      {:error, messages} ->
        Enum.reduce(messages, changeset, &add_error(&2, :cost_template, &1))
    end
  end
end
