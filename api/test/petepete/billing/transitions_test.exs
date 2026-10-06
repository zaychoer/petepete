defmodule Petepete.Billing.TransitionsTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.Billing.{Bill, Session, TransitionError, Transitions}

  # The spec's state diagram written out independently of the implementation.
  @session_allowed [
    {"draft", "issued", :issue},
    {"draft", "cancelled", :cancel},
    {"issued", "draft", :void_issue}
  ]

  @bill_allowed [
    {nil, "unpaid", :issue},
    {nil, "paid", :issue},
    {"unpaid", "paid", :gateway_payment},
    {"unpaid", "paid", :mark_paid_cash},
    {"unpaid", "needs_review", :gateway_amount_mismatch},
    {"needs_review", "paid", :mark_paid_cash},
    {"paid", "unpaid", :cancel_cash},
    {"unpaid", "void", :void_issue},
    {"needs_review", "void", :void_issue},
    {"paid", "void", :void_issue}
  ]

  @session_statuses ~w(draft issued cancelled)
  @bill_statuses ~w(unpaid paid needs_review void)

  defp every_change(from_statuses, to_statuses, triggers) do
    for from <- from_statuses, to <- to_statuses, trigger <- triggers, do: {from, to, trigger}
  end

  describe "transition table" do
    test "every session from/to/trigger is allowed only if it is in the diagram" do
      for {from, to, trigger} = change <-
            every_change(@session_statuses, @session_statuses, Transitions.session_triggers()) do
        if change in @session_allowed do
          assert Transitions.session(from, to, trigger) == :ok, inspect(change)
        else
          assert {:error,
                  %TransitionError{entity: :session, from: ^from, to: ^to, trigger: ^trigger}} =
                   Transitions.session(from, to, trigger)
        end
      end
    end

    test "every bill from/to/trigger (including creation) is allowed only if it is in the diagram" do
      for {from, to, trigger} = change <-
            every_change([nil | @bill_statuses], @bill_statuses, Transitions.bill_triggers()) do
        if change in @bill_allowed do
          assert Transitions.bill(from, to, trigger) == :ok, inspect(change)
        else
          assert {:error,
                  %TransitionError{entity: :bill, from: ^from, to: ^to, trigger: ^trigger}} =
                   Transitions.bill(from, to, trigger)
        end
      end
    end

    test "a cancelled session and a void bill are terminal" do
      for to <- @session_statuses, trigger <- Transitions.session_triggers() do
        assert {:error, _} = Transitions.session("cancelled", to, trigger)
      end

      for to <- @bill_statuses, trigger <- Transitions.bill_triggers() do
        assert {:error, _} = Transitions.bill("void", to, trigger)
      end
    end

    test "unknown statuses and triggers are rejected" do
      assert {:error, _} = Transitions.session("settled", "issued", :issue)
      assert {:error, _} = Transitions.session("draft", "issued", :webhook)
      assert {:error, _} = Transitions.bill("unpaid", "paid", :host_edit)
    end

    test "a bill with nothing to pay is created paid, otherwise unpaid" do
      assert Transitions.initial_bill_status(0) == "paid"
      assert Transitions.initial_bill_status(1) == "unpaid"
    end

    test "the error message names the rejected change" do
      {:error, error} = Transitions.session("issued", "cancelled", :cancel)
      assert Exception.message(error) =~ ~s("issued" -> "cancelled")
    end
  end

  describe "session persistence" do
    setup do
      {group, event, session} = session_with_group!()
      {:ok, group: group, event: event, session: session}
    end

    test "draft -> issued records the issue txn; issued -> draft reverts", %{
      session: session,
      group: group
    } do
      txn =
        Repo.insert!(%Petepete.Ledger.Txn{
          group_id: group.id,
          kind: "session_billed",
          actor_type: "gateway",
          idempotency_key: "k#{uniq()}"
        })

      assert {:ok, %Session{status: "issued", issue_txn_id: id} = issued} =
               Transitions.issue_session(session, txn.id)

      assert id == txn.id
      assert Repo.get!(Session, session.id).status == "issued"

      assert {:ok, %Session{status: "draft"}} = Transitions.revert_session_to_draft(issued)
      assert Repo.get!(Session, session.id).status == "draft"
    end

    test "draft -> cancelled, and nothing leaves cancelled", %{session: session} do
      assert {:ok, %Session{status: "cancelled"} = cancelled} =
               Transitions.cancel_session(session)

      assert {:error, %TransitionError{from: "cancelled", to: "draft"}} =
               Transitions.revert_session_to_draft(cancelled)

      assert {:error, %TransitionError{from: "cancelled", to: "cancelled"}} =
               Transitions.cancel_session(cancelled)
    end

    test "a stale struct is rejected and does not overwrite the row", %{session: session} do
      {:ok, _} = Transitions.cancel_session(session)

      # `session` still says draft, but the row is already cancelled
      assert {:error, %TransitionError{from: "draft", to: "cancelled"}} =
               Transitions.cancel_session(session)

      assert {:error, %TransitionError{to: "issued"}} = Transitions.issue_session(session, 1)
      assert Repo.get!(Session, session.id).status == "cancelled"
    end
  end

  describe "bill persistence" do
    setup do
      {group, event, session} = session_with_group!()
      member = member!(group)
      {:ok, group: group, member: member, session: session, event: event}
    end

    test "unpaid -> paid stores how it was paid; paid -> unpaid clears it", ctx do
      bill = bill!(ctx.session, ctx.member)
      paid_at = ~U[2026-10-09 10:00:00Z]

      assert {:ok, %Bill{status: "paid", paid_via: "cash", paid_at: ^paid_at} = paid} =
               Transitions.transition_bill(bill, "paid", :mark_paid_cash,
                 paid_via: "cash",
                 paid_at: paid_at,
                 status: "void"
               )

      assert {:ok, %Bill{status: "unpaid", paid_via: nil, paid_at: nil, paid_txn_id: nil}} =
               Transitions.transition_bill(paid, "unpaid", :cancel_cash, paid_via: "cash")
    end

    test "unpaid -> needs_review -> paid", ctx do
      bill = bill!(ctx.session, ctx.member)

      assert {:ok, %Bill{status: "needs_review"} = review} =
               Transitions.transition_bill(bill, "needs_review", :gateway_amount_mismatch)

      assert {:ok, %Bill{status: "paid"}} =
               Transitions.transition_bill(review, "paid", :mark_paid_cash, paid_via: "cash")
    end

    test "illegal changes leave the row untouched", ctx do
      bill = bill!(ctx.session, ctx.member)

      assert {:error, %TransitionError{from: "unpaid", to: "unpaid"}} =
               Transitions.transition_bill(bill, "unpaid", :cancel_cash)

      assert {:error, %TransitionError{from: "unpaid", to: "paid"}} =
               Transitions.transition_bill(bill, "paid", :cancel_cash)

      assert Repo.get!(Bill, bill.id).status == "unpaid"
    end

    test "void is unreachable through transition_bill, whatever the trigger", ctx do
      bill = bill!(ctx.session, ctx.member)

      for trigger <- Transitions.bill_triggers() do
        assert {:error, %TransitionError{to: "void"}} =
                 Transitions.transition_bill(bill, "void", trigger)
      end

      assert Repo.get!(Bill, bill.id).status == "unpaid"
    end

    test "void_bill voids unpaid, needs_review and paid bills, and void is terminal", ctx do
      members = for _ <- 1..3, do: member!(ctx.group)

      for {status, member} <- Enum.zip(~w(unpaid needs_review paid), members) do
        bill = bill!(ctx.session, member, status: status)
        assert {:ok, %Bill{status: "void"} = voided} = Transitions.void_bill(bill)
        assert {:error, _} = Transitions.void_bill(voided)
        assert {:error, _} = Transitions.transition_bill(voided, "unpaid", :cancel_cash)
      end
    end
  end
end
