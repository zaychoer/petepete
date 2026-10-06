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

  alias Petepete.Billing.{
    Attendance,
    Bill,
    Costs,
    CostItem,
    CostItemMember,
    Locks,
    Participant,
    Session,
    Transitions,
    TransitionError
  }

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

  @doc """
  `create_session/1` for the scheduler: `{:ok, session}` when it inserted a draft,
  `:exists` when the event already has a session at `starts_at`, `{:error, changeset}` for
  invalid attributes.

  A cancelled session counts as existing, so a host who cancelled a generated draft does
  not get it back on the next run. The insert is `ON CONFLICT DO NOTHING`, so a concurrent
  run that wins the race also yields `:exists` and never aborts the caller's transaction.
  """
  @spec create_session_if_absent(map()) ::
          {:ok, %Session{}} | :exists | {:error, Ecto.Changeset.t()}
  def create_session_if_absent(attrs) do
    changeset = Session.create_changeset(%Session{}, attrs)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      session_exists?(
        Ecto.Changeset.get_field(changeset, :event_id),
        Ecto.Changeset.get_field(changeset, :starts_at)
      ) ->
        :exists

      true ->
        case Repo.insert(changeset, on_conflict: :nothing) do
          {:ok, %Session{id: nil}} -> :exists
          {:ok, session} -> {:ok, session}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp session_exists?(event_id, starts_at) do
    Repo.exists?(from s in Session, where: s.event_id == ^event_id and s.starts_at == ^starts_at)
  end

  @doc """
  Fills a fresh draft session with its starting inputs: `cost_items` (attribute maps with
  `:category`, `:amount`, `:scope`, and optionally `:label`, `:paid_by_member_id`,
  `:member_ids` for a subset) and the participants (attended, weight, guests included) of
  the event's previous session.

  The previous session is the latest earlier non-cancelled session of the same event that
  has participants; with none, no participants are copied. Run it in the transaction that
  created the session. Returns `{:ok, %{cost_items: n, participants: n}}`, or
  `{:error, {:session_not_editable, status}}` for a session that is not a draft.
  """
  @spec copy_session_inputs(%Session{}, [map()]) ::
          {:ok, %{cost_items: non_neg_integer(), participants: non_neg_integer()}}
          | {:error, {:session_not_editable, String.t()}}
  def copy_session_inputs(%Session{} = session, cost_items) when is_list(cost_items) do
    with :ok <- ensure_editable(session) do
      Repo.transaction(fn ->
        Enum.each(cost_items, &insert_cost_item(session, &1))
        %{cost_items: length(cost_items), participants: copy_participants(session)}
      end)
    end
  end

  defp insert_cost_item(session, attrs) do
    item =
      Repo.insert!(%CostItem{
        session_id: session.id,
        category: attrs.category,
        label: attrs[:label],
        amount: attrs.amount,
        paid_by_member_id: attrs[:paid_by_member_id],
        scope: attrs.scope
      })

    if attrs.scope == "subset" do
      rows =
        for member_id <- Enum.uniq(attrs.member_ids),
            do: %{cost_item_id: item.id, member_id: member_id}

      Repo.insert_all(CostItemMember, rows)
    end
  end

  defp copy_participants(%Session{id: id, event_id: event_id, starts_at: starts_at}) do
    previous =
      from s in Session,
        as: :session,
        where:
          s.event_id == ^event_id and s.starts_at < ^starts_at and s.status != "cancelled" and
            exists(from p in Participant, where: p.session_id == parent_as(:session).id),
        order_by: [desc: s.starts_at],
        limit: 1,
        select: s.id

    case Repo.one(previous) do
      nil ->
        0

      previous_id ->
        {count, _} =
          Repo.insert_all(
            Participant,
            from(p in Participant,
              where: p.session_id == ^previous_id,
              select: %{
                session_id: type(^id, :integer),
                member_id: p.member_id,
                attended: p.attended,
                weight: p.weight
              }
            )
          )

        count
    end
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

  ## Reads for the group home

  @doc """
  The earliest non-cancelled session of the group starting at or after `from`, as a
  card: the session, its event's name, the total of its cost items and how many
  participants are marked attended. `nil` when none is scheduled.
  """
  @spec next_session(pos_integer(), DateTime.t()) ::
          %{
            session: %Session{},
            event_name: String.t(),
            cost_total: non_neg_integer(),
            attended_count: non_neg_integer(),
            progress: Transitions.progress()
          }
          | nil
  def next_session(group_id, %DateTime{} = from) do
    row =
      Repo.one(
        from s in Session,
          join: e in assoc(s, :event),
          where: s.group_id == ^group_id and s.status != "cancelled" and s.starts_at >= ^from,
          order_by: [asc: s.starts_at, asc: s.id],
          limit: 1,
          select: {s, e.name}
      )

    with {session, event_name} <- row do
      %{
        session: session,
        event_name: event_name,
        cost_total: cost_total(session.id),
        attended_count:
          Repo.aggregate(
            from(p in Participant, where: p.session_id == ^session.id and p.attended),
            :count
          ),
        progress: session_progress(session)
      }
    end
  end

  defp cost_total(session_id) do
    Repo.one(
      from c in CostItem,
        where: c.session_id == ^session_id,
        select: fragment("coalesce(sum(?), 0)::bigint", c.amount)
    )
  end

  @doc """
  The group's bills still open: status `unpaid` or `needs_review`, oldest session first.
  Each entry has the bill id, status, `amount_due`, the member's id and display name, and
  the session's id, start and event name. The `pay_token` is deliberately not included.
  """
  @spec open_bills(pos_integer()) :: [map()]
  def open_bills(group_id) do
    Repo.all(
      from b in Bill,
        join: s in Session,
        on: s.id == b.session_id,
        join: e in assoc(s, :event),
        join: m in assoc(b, :member),
        where: s.group_id == ^group_id and b.status in ["unpaid", "needs_review"],
        order_by: [asc: s.starts_at, asc: b.id],
        select: %{
          id: b.id,
          status: b.status,
          amount_due: b.amount_due,
          member_id: m.id,
          member_name: m.display_name,
          session_id: s.id,
          session_starts_at: s.starts_at,
          event_name: e.name
        }
    )
  end

  ## Pay link (unauthenticated; the `pay_token` is the credential)

  @doc "The bill addressed by `pay_token`, or `nil` (unknown token). Reads only, no lock."
  @spec bill_by_token(term()) :: Bill.t() | nil
  defdelegate bill_by_token(pay_token), to: Petepete.Billing.PayPage

  @doc """
  The pay page content of `bill`: `:group_name`, `:event_name`, `:session_starts_at`, the
  per-item `:lines` of its share and the `:rounding` that completes them to `bill.share`.
  Lines are recomputed from the session's stored inputs; see `Petepete.Billing.PayPage`.
  """
  @spec pay_page(Bill.t()) :: Petepete.Billing.PayPage.t()
  defdelegate pay_page(bill), to: Petepete.Billing.PayPage, as: :for_bill

  ## Locks (call inside the caller's transaction, session first)

  defdelegate lock_session(session_id), to: Locks
  defdelegate lock_bills(bill_ids), to: Locks
  defdelegate lock_session_and_bills(session_id), to: Locks
end
