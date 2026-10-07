defmodule Petepete.Reports.Queries do
  @moduledoc """
  Shared cross-context queries for reports. Share, Home and future report modules
  (images, PDF, exports) call these instead of reaching into multiple contexts.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, CostItem, Session}
  alias Petepete.Groups.{Group, Member}
  alias Petepete.Repo

  @type context :: %{
          session: %Session{},
          group: %Group{},
          event: %Petepete.Sessions.Event{}
        }

  @type error :: :not_found | {:conflict, :session_not_issued}

  @doc """
  The session, its group and event. Only issued sessions succeed; a draft or
  cancelled session returns `{:error, {:conflict, :session_not_issued}}`.
  """
  @spec session_context(pos_integer()) :: {:ok, context()} | {:error, error()}
  def session_context(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      %Session{status: "issued"} = session ->
        {:ok,
         %{
           session: session,
           group: Repo.get!(Group, session.group_id),
           event: Repo.preload(session, :event).event
         }}

      %Session{} ->
        {:error, {:conflict, :session_not_issued}}
    end
  end

  @doc """
  Bills with their members and the cost total for an issued session. Returns the
  full context that Share.bills, Share.reminder and Share.summary need so they
  never re-query:

      {:ok, %{session: session, group: group, event: event,
              rows: [{bill, member}], costs: integer}}
  """
  @spec session_bills(pos_integer()) ::
          {:ok,
           %{
             session: %Session{},
             group: %Group{},
             event: %Petepete.Sessions.Event{},
             rows: [{%Bill{}, %Member{}}],
             costs: non_neg_integer()
           }}
          | {:error, error()}
  def session_bills(session_id) do
    with {:ok, ctx} <- session_context(session_id) do
      {:ok, Map.merge(ctx, %{rows: rows(session_id), costs: costs(session_id)})}
    end
  end

  @doc false
  def rows(session_id) do
    Repo.all(
      from b in Bill,
        join: m in Member,
        on: m.id == b.member_id,
        where: b.session_id == ^session_id,
        order_by: b.id,
        select: {b, m}
    )
  end

  @doc false
  def costs(session_id) do
    Repo.one(from c in CostItem, where: c.session_id == ^session_id, select: sum(c.amount))
    |> case do
      nil -> 0
      total -> Decimal.to_integer(total)
    end
  end
end
