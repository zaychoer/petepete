defmodule Petepete.BillingTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.Billing
  alias Petepete.Billing.{Session, TransitionError, Transitions}

  describe "create_session/2" do
    setup do
      group = group_fixture()
      {:ok, group: group, event: event_fixture(group)}
    end

    test "creates a draft session in the event's group, whatever else the attrs say", ctx do
      starts_at = ~U[2026-10-15 12:00:00Z]
      other = group_fixture()

      assert {:ok, %Session{} = session} =
               Billing.create_session(ctx.event, %{
                 starts_at: starts_at,
                 status: "issued",
                 group_id: other.id
               })

      assert %{status: "draft", issue_txn_id: nil, starts_at: ^starts_at} = session
      assert session.event_id == ctx.event.id
      assert session.group_id == ctx.group.id
    end

    test "one non-cancelled session per event and time; cancelling frees the slot", ctx do
      attrs = %{starts_at: ~U[2026-10-15 12:00:00Z]}

      {:ok, first} = Billing.create_session(ctx.event, attrs)

      assert {:error, changeset} = Billing.create_session(ctx.event, attrs)
      assert %{event_id: [_]} = errors_on(changeset)

      assert {:ok, _} = Billing.cancel_session(first.id)
      assert {:ok, _} = Billing.create_session(ctx.event, attrs)
    end
  end

  describe "cancel_session/1" do
    test "cancels a draft session" do
      {_, _, session} = group_event_session_fixture()
      assert {:ok, %Session{status: "cancelled"}} = Billing.cancel_session(session.id)
      assert Repo.get!(Session, session.id).status == "cancelled"
    end

    test "rejects an issued or an already cancelled session" do
      {_, _, issued} = group_event_session_fixture(status: "issued")

      assert {:error, %TransitionError{from: "issued", to: "cancelled"}} =
               Billing.cancel_session(issued.id)

      {_, _, session} = group_event_session_fixture()
      {:ok, _} = Billing.cancel_session(session.id)

      assert {:error, %TransitionError{from: "cancelled", to: "cancelled"}} =
               Billing.cancel_session(session.id)

      assert Repo.get!(Session, issued.id).status == "issued"
    end

    test "unknown session" do
      assert {:error, :not_found} = Billing.cancel_session(-1)
    end
  end

  describe "ensure_editable/1" do
    test "only draft sessions accept cost and attendance edits" do
      assert Billing.ensure_editable(%Session{status: "draft"}) == :ok

      assert Billing.ensure_editable(%Session{status: "issued"}) ==
               {:error, {:session_not_editable, "issued"}}

      assert Billing.ensure_editable(%Session{status: "cancelled"}) ==
               {:error, {:session_not_editable, "cancelled"}}
    end

    test "an issued session is editable again once its bills are voided and it reverts to draft" do
      {_, _, session} = group_event_session_fixture(status: "issued")
      assert {:error, _} = Billing.ensure_editable(session)

      {:ok, draft} = Transitions.revert_session_to_draft(session)
      assert Billing.ensure_editable(draft) == :ok
    end
  end

  describe "session_progress/1 (derived Selesai)" do
    setup do
      {group, _event, session} = group_event_session_fixture(status: "issued")
      {:ok, group: group, session: session}
    end

    test "issued with no bills is not settled", %{session: session} do
      assert Billing.session_progress(session) == :issued
    end

    test "one unpaid bill is issued, all paid is settled", ctx do
      bill = bill_fixture(ctx.session, member_fixture(ctx.group))
      assert Billing.session_progress(ctx.session) == :issued

      {:ok, _} = Transitions.transition_bill(bill, "paid", :mark_paid_cash, paid_via: "cash")
      assert Billing.session_progress(ctx.session) == :settled
    end

    test "settled reverts to issued after a paid -> unpaid cash cancel", ctx do
      paying = bill_fixture(ctx.session, member_fixture(ctx.group))
      bill_fixture(ctx.session, member_fixture(ctx.group), status: "paid", paid_via: "credit")

      {:ok, paid} = Transitions.transition_bill(paying, "paid", :mark_paid_cash, paid_via: "cash")
      assert Billing.session_progress(ctx.session) == :settled

      {:ok, _} = Transitions.transition_bill(paid, "unpaid", :cancel_cash)
      assert Billing.session_progress(ctx.session) == :issued
    end

    test "needs_review blocks settled; void bills are ignored", ctx do
      bill_fixture(ctx.session, member_fixture(ctx.group), status: "paid", paid_via: "cash")
      review = bill_fixture(ctx.session, member_fixture(ctx.group), status: "needs_review")
      assert Billing.session_progress(ctx.session) == :issued

      {:ok, _} = Transitions.void_bill(review)
      assert Billing.session_progress(ctx.session) == :settled
    end

    test "only void bills means issued, not settled", ctx do
      bill_fixture(ctx.session, member_fixture(ctx.group), status: "void")
      assert Billing.session_progress(ctx.session) == :issued
    end

    test "draft and cancelled sessions never show as settled even with paid bills", ctx do
      bill_fixture(ctx.session, member_fixture(ctx.group), status: "paid", paid_via: "cash")
      assert Billing.session_progress(%{ctx.session | status: "draft"}) == :draft
      assert Billing.session_progress(%{ctx.session | status: "cancelled"}) == :cancelled
    end

    test "session_progresses/1 answers many sessions at once", ctx do
      bill_fixture(ctx.session, member_fixture(ctx.group), status: "paid", paid_via: "cash")
      event = event_fixture(ctx.group, starts_at: ~U[2026-10-20 12:00:00Z])
      open = session_fixture(event, status: "issued", starts_at: ~U[2026-10-20 12:00:00Z])
      bill_fixture(open, member_fixture(ctx.group))
      {_, _, draft} = group_event_session_fixture()

      assert Billing.session_progresses([ctx.session, open, draft]) == %{
               ctx.session.id => :settled,
               open.id => :issued,
               draft.id => :draft
             }
    end
  end
end
