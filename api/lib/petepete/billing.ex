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

  alias Petepete.Accounts.Scope
  alias Petepete.Billing.{Attendance, Bill, Costs, CostItem, Locks, Participant, Session}
  alias Petepete.Billing.{Transitions, TransitionError}
  alias Petepete.Groups
  alias Petepete.Repo

  @type edit_error ::
          :not_found
          | :forbidden
          | {:session_not_editable, String.t()}
          | Ecto.Changeset.t()

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

  ## Cost items and attendance (host-only edits of a draft session)

  @doc """
  Adds a cost item to a draft session. `attrs` (string or atom keys): `category`, `amount`
  (positive integer rupiah), optional `label`, `paid_by` (member id of the group, default
  the acting host), `scope` (`"all"` default, or `"subset"`) and `members` (member ids,
  at least one when subset). The caller must be the host of the session's group.
  """
  @spec create_cost_item(Scope.t(), integer(), map()) ::
          {:ok, %CostItem{}} | {:error, edit_error()}
  defdelegate create_cost_item(scope, session_id, attrs), to: Costs, as: :create

  @doc """
  Replaces a cost item of the session with `attrs` (same shape as `create_cost_item/3`;
  an omitted `paid_by` becomes the acting host again, an `all` item keeps no members).
  """
  @spec update_cost_item(Scope.t(), integer(), integer(), map()) ::
          {:ok, %CostItem{}} | {:error, edit_error()}
  defdelegate update_cost_item(scope, session_id, cost_item_id, attrs), to: Costs, as: :update

  @doc "Removes a cost item of the draft session."
  @spec delete_cost_item(Scope.t(), integer(), integer()) ::
          {:ok, %CostItem{}} | {:error, edit_error()}
  defdelegate delete_cost_item(scope, session_id, cost_item_id), to: Costs, as: :delete

  @doc """
  The session's cost items with `member_ids` (who a subset item is limited to) and
  `bearer_ids` (who bears it: the attending members in scope) loaded.
  """
  @spec list_cost_items(integer()) :: [%CostItem{}]
  defdelegate list_cost_items(session_id), to: Costs, as: :list

  @doc """
  Cost items nobody attending bears (no attending member in scope). Issuing a bill is
  blocked while this is not empty; the validation itself is `Billing.preview/1`'s.
  """
  @spec cost_items_without_bearers(integer() | %Session{}) :: [%CostItem{}]
  def cost_items_without_bearers(%Session{id: id}), do: Costs.without_bearers(id)

  def cost_items_without_bearers(session_id) when is_integer(session_id),
    do: Costs.without_bearers(session_id)

  @doc """
  Marks a roster member (host, member or guest) attended or not at a draft session.
  `attrs`: `member_id`, `attended` (boolean), optional `weight` (positive integer per
  mil; a new participant defaults to the member's `default_weight`, an existing one keeps
  its weight).
  """
  @spec set_attendance(Scope.t(), integer(), map()) ::
          {:ok, %Participant{}} | {:error, edit_error()}
  defdelegate set_attendance(scope, session_id, attrs), to: Attendance, as: :set

  @doc "The session's participants with `member` loaded."
  @spec list_participants(integer()) :: [%Participant{}]
  defdelegate list_participants(session_id), to: Attendance, as: :list

  @doc """
  A session as the host's screens need it: the session, its derived `progress`, cost items
  and participants. Any member of the session's group may read it.
  """
  @spec get_session(Scope.t(), integer()) ::
          {:ok,
           %{
             session: %Session{},
             progress: Transitions.progress(),
             cost_items: [%CostItem{}],
             participants: [%Participant{}]
           }}
          | {:error, :not_found}
  def get_session(%Scope{} = scope, session_id) when is_integer(session_id) do
    with group_id when not is_nil(group_id) <- Groups.group_id_for(:session, session_id),
         {:ok, _member} <- Groups.authorize(scope, group_id, :member),
         %Session{} = session <- Repo.get(Session, session_id) do
      {:ok,
       %{
         session: session,
         progress: session_progress(session),
         cost_items: list_cost_items(session.id),
         participants: list_participants(session.id)
       }}
    else
      _ -> {:error, :not_found}
    end
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

  ## Preview and issue (one computation path, `Petepete.Billing.Calculation`)

  @doc """
  The per-person, per-item breakdown of a draft session, from its stored attendance and
  cost items (spec "Aturan hitung"). Reads credit from `Ledger.balances/1` without a lock.

  Returns `{:ok, preview}` with `:session_id`, `:rounding_unit`, `:total_cost`,
  `:total_billed`, `:kas_remainder` ("Masuk kas"), `:credit_used`, `:total_due`, `:items`,
  `:fronted` and `:members`; each member has `:member_id`, `:display_name`, `:weight`,
  `:lines` (per cost item, with the exact `:fraction`), `:raw_share`, `:share`, `:rounding`,
  `:fronted`, `:credit_balance`, `:credit_available`, `:credit_applied` and `:amount_due`.
  See `Petepete.Billing.Calculation` for the exact meaning.

  Errors: `{:error, :not_found}`; `{:error, %TransitionError{}}` when the session is not a
  draft; `{:error, {:invalid, errors}}` when step 7 fails, so the bills cannot be sent.
  """
  defdelegate preview(session_id), to: Petepete.Billing.Invoicing

  @doc """
  Issues a draft session: posts one `session_billed` txn, creates a bill per participant
  with a positive share, and moves the session draft -> issued, all in one transaction.

  Options (both required): `actor: {:host, user_id}` and `idempotency_key: String.t()`
  (passed to the Ledger as the txn's `idempotency_key`). The same key again on the issued
  session returns the same txn and bills with `replayed: true`. `credit_applied` and
  `amount_due` come from the balances the Ledger saw just before posting; a bill with
  `amount_due` 0 is created `paid` with `paid_via` credit and no extra txn. Each bill gets
  a url-safe 192-bit `pay_token` expiring 30 days after issue.

  Returns `{:ok, %{session: session, txn: txn, bills: [bill], replayed: boolean}}` (bills
  have `:member` preloaded) or `{:error, reason}`: everything `preview/1` returns, a
  `%TransitionError{}` for a session that is not draft (or issued by another key), and the
  Ledger's typed errors; `:idempotency_key_required` for a blank key. Any error rolls
  everything back.
  """
  defdelegate issue(session_id, opts), to: Petepete.Billing.Invoicing

  ## Locks (call inside the caller's transaction, session first)

  defdelegate lock_session(session_id), to: Locks
  defdelegate lock_bills(bill_ids), to: Locks
  defdelegate lock_session_and_bills(session_id), to: Locks
end
