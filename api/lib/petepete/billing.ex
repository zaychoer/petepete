defmodule Petepete.Billing do
  @moduledoc """
  Session status, cost items, attendance and bills.

  Schemas: `Petepete.Billing.Session` (`sessions`), `Petepete.Billing.CostItem`
  (`cost_items`), `Petepete.Billing.CostItemMember` (`cost_item_members`),
  `Petepete.Billing.Participant` (`session_participants`), `Petepete.Billing.Bill`
  (`bills`). Money is bigint rupiah; weights are integer per mil.

  Billing is the only owner of session and bill status. The state machine lives in
  `Petepete.Billing.Transitions`, the lock order (session, bills by id, then Ledger)
  in `Petepete.Billing.Locks`.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, Locks, Session, Transitions, TransitionError}
  alias Petepete.Repo

  ## Session lifecycle owned by the state machine

  @doc """
  Creates a draft session of an event. `attrs` takes `:event_id`, `:group_id` and
  `:starts_at`; the event must belong to the group and the event may have only one
  non-cancelled session per `starts_at`.
  """
  @spec create_session(map()) :: {:ok, %Session{}} | {:error, Ecto.Changeset.t()}
  def create_session(attrs) do
    %Session{} |> Session.create_changeset(attrs) |> Repo.insert()
  end

  @doc "Cancels a draft session (draft -> cancelled), under the session row lock."
  @spec cancel_session(pos_integer()) ::
          {:ok, %Session{}} | {:error, :not_found | TransitionError.t()}
  def cancel_session(session_id) do
    Repo.transaction(fn ->
      with {:ok, session} <- Locks.lock_session(session_id),
           {:ok, cancelled} <- Transitions.cancel_session(session) do
        cancelled
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Edit guard for costs and attendance: only a draft session accepts edits (an issued one
  only after Batalkan tagihan, which returns it to draft). Pass the session row locked
  by the editing command.
  """
  @spec ensure_editable(%Session{}) :: :ok | {:error, {:session_not_editable, String.t()}}
  def ensure_editable(%Session{status: status}) do
    if Transitions.editable?(status), do: :ok, else: {:error, {:session_not_editable, status}}
  end

  ## Derived Selesai

  @doc """
  Progress of a session: `:draft`, `:cancelled`, `:issued` (UI "Ditagih") or `:settled`
  (UI "Selesai": issued, at least one non-void bill, all non-void bills paid).
  Derived from the bills on every call, never stored.
  """
  @spec session_progress(%Session{}) :: Transitions.progress()
  def session_progress(%Session{} = session) do
    session_progresses([session]) |> Map.fetch!(session.id)
  end

  @doc "`session_progress/1` for many sessions in one query: `%{session_id => progress}`."
  @spec session_progresses([%Session{}]) :: %{pos_integer() => Transitions.progress()}
  def session_progresses(sessions) do
    issued_ids = for %Session{status: "issued", id: id} <- sessions, do: id

    statuses =
      Repo.all(
        from b in Bill, where: b.session_id in ^issued_ids, select: {b.session_id, b.status}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(sessions, fn %Session{id: id, status: status} ->
      {id, Transitions.progress(status, Map.get(statuses, id, []))}
    end)
  end

  ## Locks (call inside the caller's transaction, session first)

  defdelegate lock_session(session_id), to: Locks
  defdelegate lock_bills(bill_ids), to: Locks
  defdelegate lock_session_and_bills(session_id), to: Locks
end
