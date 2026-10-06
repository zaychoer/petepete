defmodule Petepete.BillingTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.Billing
  alias Petepete.Billing.{Session, TransitionError, Transitions}

  describe "create_session/1" do
    setup do
      group = group!()
      {:ok, group: group, event: event!(group)}
    end

    test "creates a draft session", %{group: group, event: event} do
      starts_at = ~U[2026-10-15 12:00:00Z]

      assert {:ok, %Session{status: "draft", issue_txn_id: nil, starts_at: ^starts_at}} =
               Billing.create_session(%{
                 event_id: event.id,
                 group_id: group.id,
                 starts_at: starts_at,
                 status: "issued"
               })
    end

    test "rejects an event of another group", %{event: event} do
      other = group!()

      assert {:error, changeset} =
               Billing.create_session(%{
                 event_id: event.id,
                 group_id: other.id,
                 starts_at: ~U[2026-10-15 12:00:00Z]
               })

      assert %{event_id: ["does not belong to the group"]} = errors_on(changeset)
    end

    test "one non-cancelled session per event and time; cancelling frees the slot", ctx do
      attrs = %{
        event_id: ctx.event.id,
        group_id: ctx.group.id,
        starts_at: ~U[2026-10-15 12:00:00Z]
      }

      {:ok, first} = Billing.create_session(attrs)

      assert {:error, changeset} = Billing.create_session(attrs)
      assert %{event_id: [_]} = errors_on(changeset)

      assert {:ok, _} = Billing.cancel_session(first.id)
      assert {:ok, _} = Billing.create_session(attrs)
    end
  end

  describe "cancel_session/1" do
    test "cancels a draft session" do
      {_, _, session} = session_with_group!()
      assert {:ok, %Session{status: "cancelled"}} = Billing.cancel_session(session.id)
      assert Repo.get!(Session, session.id).status == "cancelled"
    end

    test "rejects an issued or an already cancelled session" do
      {_, _, issued} = session_with_group!(status: "issued")

      assert {:error, %TransitionError{from: "issued", to: "cancelled"}} =
               Billing.cancel_session(issued.id)

      {_, _, session} = session_with_group!()
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
      {_, _, session} = session_with_group!(status: "issued")
      assert {:error, _} = Billing.ensure_editable(session)

      {:ok, draft} = Transitions.revert_session_to_draft(session)
      assert Billing.ensure_editable(draft) == :ok
    end
  end

  describe "session_progress/1 (derived Selesai)" do
    setup do
      {group, _event, session} = session_with_group!(status: "issued")
      {:ok, group: group, session: session}
    end

    test "issued with no bills is not settled", %{session: session} do
      assert Billing.session_progress(session) == :issued
    end

    test "one unpaid bill is issued, all paid is settled", ctx do
      bill = bill!(ctx.session, member!(ctx.group))
      assert Billing.session_progress(ctx.session) == :issued

      {:ok, _} = Transitions.transition_bill(bill, "paid", :mark_paid_cash, paid_via: "cash")
      assert Billing.session_progress(ctx.session) == :settled
    end

    test "settled reverts to issued after a paid -> unpaid cash cancel", ctx do
      paying = bill!(ctx.session, member!(ctx.group))
      bill!(ctx.session, member!(ctx.group), status: "paid", paid_via: "credit")

      {:ok, paid} = Transitions.transition_bill(paying, "paid", :mark_paid_cash, paid_via: "cash")
      assert Billing.session_progress(ctx.session) == :settled

      {:ok, _} = Transitions.transition_bill(paid, "unpaid", :cancel_cash)
      assert Billing.session_progress(ctx.session) == :issued
    end

    test "needs_review blocks settled; void bills are ignored", ctx do
      bill!(ctx.session, member!(ctx.group), status: "paid", paid_via: "cash")
      review = bill!(ctx.session, member!(ctx.group), status: "needs_review")
      assert Billing.session_progress(ctx.session) == :issued

      {:ok, _} = Transitions.void_bill(review)
      assert Billing.session_progress(ctx.session) == :settled
    end

    test "only void bills means issued, not settled", ctx do
      bill!(ctx.session, member!(ctx.group), status: "void")
      assert Billing.session_progress(ctx.session) == :issued
    end

    test "draft and cancelled sessions never show as settled even with paid bills", ctx do
      bill!(ctx.session, member!(ctx.group), status: "paid", paid_via: "cash")
      assert Billing.session_progress(%{ctx.session | status: "draft"}) == :draft
      assert Billing.session_progress(%{ctx.session | status: "cancelled"}) == :cancelled
    end

    test "session_progresses/1 answers many sessions at once", ctx do
      bill!(ctx.session, member!(ctx.group), status: "paid", paid_via: "cash")
      event = event!(ctx.group, starts_at: ~U[2026-10-20 12:00:00Z])
      open = session!(event, status: "issued", starts_at: ~U[2026-10-20 12:00:00Z])
      bill!(open, member!(ctx.group))
      {_, _, draft} = session_with_group!()

      assert Billing.session_progresses([ctx.session, open, draft]) == %{
               ctx.session.id => :settled,
               open.id => :issued,
               draft.id => :draft
             }
    end
  end
end
