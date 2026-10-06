defmodule Petepete.Metrics do
  @moduledoc """
  The four MVP metrics (PP-REL-02), written server-side inside the transaction of the
  Billing command that owns the domain change, so a rolled-back command leaves no event
  and a replayed command (same idempotency key) records nothing.

    * `:session_build_duration`: first cost or attendance edit of a draft session to issue,
      `value_ms`, one per session. Recorded by `Billing.issue/2`.
    * `:bills_sent`: one event per bill created by `Billing.issue/2`; the count is the
      number of rows.
    * `:time_to_paid`: issue to paid, `value_ms`, one per bill. Recorded when a bill
      becomes paid by gateway or cash (not by credit, which pays it at issue).
    * `:paid_without_install`: a bill paid through the gateway whose member has no linked
      user account; one per bill.

  An event is recorded once per subject (unique indexes), so cancelling a cash payment
  and taking it again does not count the bill twice. Reporting lives in
  `Petepete.Metrics.Report`.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.Bill
  alias Petepete.Clock
  alias Petepete.Groups.Member
  alias Petepete.Metrics.Event
  alias Petepete.Repo

  @names [:session_build_duration, :bills_sent, :time_to_paid, :paid_without_install]

  @type name :: :session_build_duration | :bills_sent | :time_to_paid | :paid_without_install

  @doc """
  Records metric `name`. `attrs` takes `:group_id` (required), `:session_id`, `:bill_id`
  and `:value_ms`. Must run inside the caller's transaction; an event already recorded for
  the same session or bill is left as it is.
  """
  @spec record(name(), keyword() | map()) :: :ok
  def record(name, attrs) when name in @names do
    unless Repo.in_transaction?() do
      raise ArgumentError, "Metrics.record/2 must run inside the domain change's transaction"
    end

    attrs = Map.new(attrs)

    row = %{
      group_id: Map.fetch!(attrs, :group_id),
      name: Atom.to_string(name),
      session_id: attrs[:session_id],
      bill_id: attrs[:bill_id],
      value_ms: attrs[:value_ms],
      inserted_at: Clock.now()
    }

    Repo.insert_all(Event, [row], on_conflict: :nothing)
    :ok
  end

  @doc "Milliseconds from `from` to `to`, never negative."
  @spec duration_ms(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def duration_ms(%DateTime{} = from, %DateTime{} = to) do
    max(DateTime.diff(to, from, :millisecond), 0)
  end

  @doc """
  Records what a bill becoming paid (by `:cash` or `:gateway`, not credit) means for the
  metrics: `:time_to_paid` from the bill's creation at issue to `paid_at`, and for a
  gateway payment by a member without a linked user account `:paid_without_install`.
  Call it once, in the transaction that marks the bill paid.
  """
  @spec record_paid(%Bill{}, pos_integer(), DateTime.t(), :cash | :gateway) :: :ok
  def record_paid(%Bill{} = bill, group_id, %DateTime{} = paid_at, via)
      when via in [:cash, :gateway] do
    ref = [group_id: group_id, session_id: bill.session_id, bill_id: bill.id]
    record(:time_to_paid, [value_ms: duration_ms(bill.inserted_at, paid_at)] ++ ref)

    if via == :gateway and without_account?(bill.member_id) do
      record(:paid_without_install, ref)
    end

    :ok
  end

  defp without_account?(member_id) do
    Repo.exists?(from m in Member, where: m.id == ^member_id and is_nil(m.user_id))
  end
end
