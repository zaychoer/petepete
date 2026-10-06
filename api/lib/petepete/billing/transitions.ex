defmodule Petepete.Billing.Transitions do
  @moduledoc """
  The state machine of a Session (draft/issued/cancelled) and a Bill
  (unpaid/paid/needs_review/void), exactly as in the spec's state diagram.

  Every allowed change is a `{from, to}` pair plus the Billing command (trigger) that
  may make it. Anything else is rejected with `Petepete.Billing.TransitionError`.
  `from` is `nil` when a Bill is created. "Selesai" (settled) is never stored: see
  `progress/2`.

  Persistence helpers update one row guarded by its current status
  (`UPDATE ... WHERE status = from`). Callers MUST hold the row lock
  (`Petepete.Billing.Locks`) inside their own transaction and pass the locked row.
  `void` is reachable only through `void_bill/1`, and issued -> draft only through
  `revert_session_to_draft/1`: both belong to `Billing.void_issue/2`.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, Session, TransitionError}
  alias Petepete.Repo

  @session_statuses ~w(draft issued cancelled)
  @bill_statuses ~w(unpaid paid needs_review void)

  @session_triggers [:issue, :cancel, :void_issue]
  @bill_triggers [
    :issue,
    :gateway_payment,
    :gateway_amount_mismatch,
    :mark_paid_cash,
    :cancel_cash,
    :void_issue
  ]

  # {from, to} => triggers allowed to make that change.
  @session_table %{
    {"draft", "issued"} => [:issue],
    {"draft", "cancelled"} => [:cancel],
    {"issued", "draft"} => [:void_issue]
  }

  @bill_table %{
    {nil, "unpaid"} => [:issue],
    {nil, "paid"} => [:issue],
    {"unpaid", "paid"} => [:gateway_payment, :mark_paid_cash],
    {"unpaid", "needs_review"} => [:gateway_amount_mismatch],
    {"needs_review", "paid"} => [:mark_paid_cash],
    {"paid", "unpaid"} => [:cancel_cash],
    {"unpaid", "void"} => [:void_issue],
    {"needs_review", "void"} => [:void_issue],
    {"paid", "void"} => [:void_issue]
  }

  @bill_paid_fields [:paid_via, :paid_txn_id, :paid_at]

  @type session_status :: String.t()
  @type bill_status :: String.t()
  @type progress :: :draft | :issued | :settled | :cancelled

  def session_statuses, do: @session_statuses
  def bill_statuses, do: @bill_statuses
  def session_triggers, do: @session_triggers
  def bill_triggers, do: @bill_triggers

  ## Pure guards

  @doc "Guards a session status change."
  @spec session(session_status(), session_status(), atom()) ::
          :ok | {:error, TransitionError.t()}
  def session(from, to, trigger), do: guard(:session, @session_table, from, to, trigger)

  @doc "Guards a bill status change; `from` is `nil` when the bill is being created."
  @spec bill(bill_status() | nil, bill_status(), atom()) :: :ok | {:error, TransitionError.t()}
  def bill(from, to, trigger), do: guard(:bill, @bill_table, from, to, trigger)

  defp guard(entity, table, from, to, trigger) do
    if trigger in Map.get(table, {from, to}, []) do
      :ok
    else
      {:error, %TransitionError{entity: entity, from: from, to: to, trigger: trigger}}
    end
  end

  @doc "A bill with nothing left to pay (covered by credit) is created paid, any other unpaid."
  @spec initial_bill_status(non_neg_integer()) :: bill_status()
  def initial_bill_status(0), do: "paid"
  def initial_bill_status(amount_due) when is_integer(amount_due) and amount_due > 0, do: "unpaid"

  @doc """
  Derived progress of a session from its stored status and its bills' statuses.

  A session is `:settled` (UI "Selesai") when it is issued, has at least one non-void
  bill, and every non-void bill is paid.
  """
  @spec progress(session_status(), [bill_status()]) :: progress()
  def progress("draft", _bill_statuses), do: :draft
  def progress("cancelled", _bill_statuses), do: :cancelled

  def progress("issued", bill_statuses) do
    case Enum.reject(bill_statuses, &(&1 == "void")) do
      [] -> :issued
      live -> if Enum.all?(live, &(&1 == "paid")), do: :settled, else: :issued
    end
  end

  @doc "Only draft sessions accept cost and attendance edits."
  @spec editable?(session_status()) :: boolean()
  def editable?(status), do: status == "draft"

  ## Session persistence

  @doc "draft -> issued, recording the `session_billed` txn. Called by `Billing.issue/2`."
  @spec issue_session(%Session{}, pos_integer()) ::
          {:ok, %Session{}} | {:error, TransitionError.t()}
  def issue_session(%Session{} = session, issue_txn_id) when is_integer(issue_txn_id) do
    update_status(Session, session, :session, "issued", :issue, issue_txn_id: issue_txn_id)
  end

  @doc "draft -> cancelled."
  @spec cancel_session(%Session{}) :: {:ok, %Session{}} | {:error, TransitionError.t()}
  def cancel_session(%Session{} = session) do
    update_status(Session, session, :session, "cancelled", :cancel, [])
  end

  @doc "issued -> draft. Only `Billing.void_issue/2` calls this. `issue_txn_id` is left as is."
  @spec revert_session_to_draft(%Session{}) ::
          {:ok, %Session{}} | {:error, TransitionError.t()}
  def revert_session_to_draft(%Session{} = session) do
    update_status(Session, session, :session, "draft", :void_issue, [])
  end

  ## Bill persistence

  @doc """
  Moves a bill to `to` on behalf of `trigger`, except to `void`.

  `attrs` may set `:paid_via`, `:paid_txn_id` and `:paid_at` (other keys are ignored).
  `:cancel_cash` (paid -> unpaid) always clears all three.
  """
  @spec transition_bill(%Bill{}, bill_status(), atom(), keyword() | map()) ::
          {:ok, %Bill{}} | {:error, TransitionError.t()}
  def transition_bill(%Bill{} = bill, to, trigger, attrs \\ []) do
    if to == "void" do
      {:error, %TransitionError{entity: :bill, from: bill.status, to: to, trigger: trigger}}
    else
      change_bill(bill, to, trigger, attrs)
    end
  end

  @doc "Any bill -> void. Only `Billing.void_issue/2` calls this."
  @spec void_bill(%Bill{}) :: {:ok, %Bill{}} | {:error, TransitionError.t()}
  def void_bill(%Bill{} = bill), do: change_bill(bill, "void", :void_issue, [])

  defp change_bill(bill, to, :cancel_cash, _attrs) do
    cleared = Enum.map(@bill_paid_fields, &{&1, nil})
    update_status(Bill, bill, :bill, to, :cancel_cash, cleared)
  end

  defp change_bill(bill, to, trigger, attrs) do
    update_status(
      Bill,
      bill,
      :bill,
      to,
      trigger,
      Keyword.take(Enum.to_list(attrs), @bill_paid_fields)
    )
  end

  # The guard runs first; the status-guarded UPDATE then catches a caller that skipped
  # the row lock and passed a stale struct (0 rows -> same typed error).
  defp update_status(schema, row, entity, to, trigger, extra) do
    table = if entity == :session, do: @session_table, else: @bill_table
    error = %TransitionError{entity: entity, from: row.status, to: to, trigger: trigger}

    with :ok <- guard(entity, table, row.status, to, trigger) do
      set = [status: to, updated_at: DateTime.utc_now(:second)] ++ extra
      query = from(r in schema, where: r.id == ^row.id and r.status == ^row.status, select: r)

      case Repo.update_all(query, set: set) do
        {1, [updated]} -> {:ok, updated}
        {0, _} -> {:error, error}
      end
    end
  end
end
