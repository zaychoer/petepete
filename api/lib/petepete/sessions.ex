defmodule Petepete.Sessions do
  @moduledoc """
  Scheduling only: events, their recurrence and creating draft sessions.

  Schema: `Petepete.Sessions.Event` (`events`). The `sessions` table itself is
  owned by Billing (`Petepete.Billing.Session`), which holds session status; this
  module asks `Petepete.Billing` to create draft sessions and to fill them with their
  starting cost items and participants.

  Two ways a session comes to exist:

    * a one-off event creates its single draft session when the event is created;
    * the daily `Petepete.Sessions.SessionScheduler` job calls `generate_upcoming/1`,
      which creates the draft sessions of every active recurring event that fall in the
      next 3 days (H-3), so a Thursday event gets its draft on Monday.

  All times of day are WIB (UTC+7); see `Petepete.Sessions.RRule`.
  """
  import Ecto.Query, only: [from: 2]

  alias Petepete.{Billing, Repo, Wib}
  alias Petepete.Groups.Group
  alias Petepete.Sessions.{CostTemplate, Event, RRule}

  require Logger

  @days_ahead 3

  @doc """
  Creates an event in `group_id` from request params (see `Event.create_changeset/3`).

  A one-off event also gets its draft session at once, with the template's cost items;
  a recurring event gets none here, the scheduler creates them. Returns the event and
  its session (`nil` for recurring), or `{:error, changeset}` with field errors.
  """
  @spec create_event(pos_integer(), map()) ::
          {:ok, %{event: %Event{}, session: struct() | nil}} | {:error, Ecto.Changeset.t()}
  def create_event(group_id, params) when is_map(params) do
    group = Repo.get!(Group, group_id)

    Repo.transaction(fn ->
      with {:ok, event} <- Repo.insert(Event.create_changeset(%Event{}, group, params)),
           {:ok, session} <- create_one_off_session(event) do
        %{event: event, session: session}
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp create_one_off_session(%Event{type: "recurring"}), do: {:ok, nil}

  defp create_one_off_session(%Event{type: "one_off"} = event) do
    with {:ok, session} <-
           Billing.create_session(%{
             event_id: event.id,
             group_id: event.group_id,
             starts_at: event.starts_at
           }),
         {:ok, _copied} <-
           Billing.copy_session_inputs(session, CostTemplate.items(event.cost_template)) do
      {:ok, session}
    end
  end

  @doc """
  Creates the draft sessions of active recurring events for the WIB dates from `now`'s date
  through #{@days_ahead} days later, and returns how many were `:created`, `:existing`
  already and `:failed`.

  Safe to run any number of times: a session that already exists for an event at that
  start, in any status (a host-cancelled draft is not revived), is left alone, and a
  concurrent run can at worst lose the `ON CONFLICT DO NOTHING` insert. Each new session
  is created together with its cost items (from the event's template) and participants
  (from the event's previous session that had any) in one transaction.

  The window starts at today, not at H-3 exactly, so an occurrence missed because the job
  did not run, or because the event was created less than 3 days ahead, is picked up on
  the next run.
  """
  @spec generate_upcoming(DateTime.t()) ::
          %{created: non_neg_integer(), existing: non_neg_integer(), failed: non_neg_integer()}
  def generate_upcoming(%DateTime{} = now) do
    today = Wib.date(now)
    dates = Date.range(today, Date.add(today, @days_ahead))

    from(e in Event, where: e.type == "recurring" and e.active, order_by: e.id)
    |> Repo.all()
    |> Enum.flat_map(&occurrences(&1, dates))
    |> Enum.map(fn {event, starts_at} -> generate_occurrence(event, starts_at) end)
    |> Enum.frequencies()
    |> then(&Map.merge(%{created: 0, existing: 0, failed: 0}, &1))
  end

  defp occurrences(%Event{} = event, dates) do
    case RRule.parse(event.rrule) do
      {:ok, %RRule{time: %Time{}} = rule} ->
        for date <- dates, starts_at = RRule.occurrence_on(rule, date), do: {event, starts_at}

      _ ->
        Logger.error("event #{event.id} has an rrule the scheduler cannot read")
        [{event, nil}]
    end
  end

  defp generate_occurrence(_event, nil), do: :failed

  defp generate_occurrence(%Event{} = event, starts_at) do
    result =
      Repo.transaction(fn ->
        case Billing.create_session_if_absent(%{
               event_id: event.id,
               group_id: event.group_id,
               starts_at: starts_at
             }) do
          {:ok, session} ->
            {:ok, _} =
              Billing.copy_session_inputs(session, CostTemplate.items(event.cost_template))

            :created

          :exists ->
            :existing

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, outcome} ->
        outcome

      {:error, changeset} ->
        Logger.error(
          "could not create session for event #{event.id}: #{inspect(changeset.errors)}"
        )

        :failed
    end
  end
end
