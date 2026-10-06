defmodule Petepete.SchemaConstraintsTest do
  use Petepete.DataCase, async: true

  alias Petepete.Accounts.User
  alias Petepete.Billing.{Bill, CostItem, Participant, Session}
  alias Petepete.Groups.{Group, Member}
  alias Petepete.Ledger.{Entry, Txn}
  alias Petepete.Sessions.Event

  @now ~U[2026-10-06 10:00:00Z]

  defp uniq, do: System.unique_integer([:positive])

  defp user!, do: Repo.insert!(%User{phone: "62#{uniq()}", display_name: "Host"})

  defp group!, do: Repo.insert!(%Group{name: "Futsal", invite_token: "inv#{uniq()}"})

  defp member!(group, attrs \\ []) do
    Repo.insert!(
      struct(%Member{group_id: group.id, display_name: "M#{uniq()}", role: "member"}, attrs)
    )
  end

  defp txn!(group, attrs \\ []) do
    base = %Txn{
      group_id: group.id,
      kind: "settlement",
      actor_type: "gateway",
      idempotency_key: "k#{uniq()}"
    }

    Repo.insert!(struct(base, attrs))
  end

  defp entry!(txn, attrs) do
    Repo.insert!(struct(%Entry{txn_id: txn.id, group_id: txn.group_id}, attrs))
  end

  defp commit_deferred, do: Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

  describe "ledger zero-sum" do
    setup do
      group = group!()
      {:ok, group: group, a: member!(group), b: member!(group)}
    end

    test "unbalanced txn is rejected when constraints are checked at commit", ctx do
      txn = txn!(ctx.group)
      entry!(txn, account_type: "member", member_id: ctx.a.id, amount: -1000)
      entry!(txn, account_type: "member", member_id: ctx.b.id, amount: 900)

      assert_raise Postgrex.Error, ~r/unbalanced/, &commit_deferred/0
    end

    test "balanced txn passes, even though entries are inserted one row at a time", ctx do
      txn = txn!(ctx.group)
      entry!(txn, account_type: "member", member_id: ctx.a.id, amount: -1000)
      entry!(txn, account_type: "member", member_id: ctx.b.id, amount: 600)
      entry!(txn, account_type: "kas", amount: 400)

      commit_deferred()
    end
  end

  describe "ledger immutability" do
    setup do
      group = group!()
      a = member!(group)
      txn = txn!(group)
      entry = entry!(txn, account_type: "member", member_id: a.id, amount: 0)
      {:ok, txn: txn, entry: entry}
    end

    test "ledger_entries reject UPDATE and DELETE", %{entry: entry} do
      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(e in Entry, where: e.id == ^entry.id), set: [amount: 5])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.delete!(entry) end
    end

    test "ledger_txns reject UPDATE and DELETE", %{txn: txn} do
      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(t in Txn, where: t.id == ^txn.id), set: [reason: "x"])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.delete!(txn) end
    end
  end

  describe "ledger_txns checks" do
    setup do
      group = group!()
      {:ok, group: group, user: user!()}
    end

    test "kind must be one of the eight money events", %{group: group} do
      assert_raise Ecto.ConstraintError, ~r/kind_allowed/, fn ->
        txn!(group, kind: "reversal")
      end
    end

    test "reverses_txn_id is only allowed on the cancel kinds", %{group: group} do
      original = txn!(group)

      assert_raise Ecto.ConstraintError, ~r/reverses_only_for_cancel_kinds/, fn ->
        txn!(group, kind: "cash_received", reverses_txn_id: original.id)
      end

      txn!(group,
        kind: "correction",
        reverses_txn_id: original.id,
        reason: "salah catat"
      )
    end

    test "the cancel kinds require a reason", %{group: group} do
      for kind <- ~w(session_bills_cancelled cash_payment_cancelled correction) do
        assert_raise Ecto.ConstraintError, ~r/reason_required_for_cancel_kinds/, fn ->
          txn!(group, kind: kind)
        end
      end
    end

    test "a txn can be reversed only once", %{group: group} do
      original = txn!(group)
      opts = [kind: "correction", reverses_txn_id: original.id, reason: "r"]
      txn!(group, opts)

      assert_raise Ecto.ConstraintError, ~r/reverses_txn_id/, fn -> txn!(group, opts) end
    end

    test "host needs actor_user_id, gateway must not have one", %{group: group, user: user} do
      assert_raise Ecto.ConstraintError, ~r/actor_matches_type/, fn ->
        txn!(group, actor_type: "host")
      end

      assert_raise Ecto.ConstraintError, ~r/actor_matches_type/, fn ->
        txn!(group, actor_type: "gateway", actor_user_id: user.id)
      end

      txn!(group, actor_type: "host", actor_user_id: user.id)
    end

    test "idempotency_key is unique", %{group: group} do
      txn!(group, idempotency_key: "same")

      assert_raise Ecto.ConstraintError, ~r/idempotency_key/, fn ->
        txn!(group, idempotency_key: "same")
      end
    end
  end

  describe "ledger_entries checks" do
    test "member accounts need member_id, kas accounts must not have one" do
      group = group!()
      txn = txn!(group)
      m = member!(group)

      assert_raise Ecto.ConstraintError, ~r/account_matches_member/, fn ->
        entry!(txn, account_type: "member", amount: 1)
      end

      assert_raise Ecto.ConstraintError, ~r/account_matches_member/, fn ->
        entry!(txn, account_type: "kas", member_id: m.id, amount: 1)
      end
    end
  end

  describe "other checks" do
    test "weights must be positive" do
      group = group!()

      assert_raise Ecto.ConstraintError, ~r/default_weight_positive/, fn ->
        member!(group, default_weight: 0)
      end

      m = member!(group)
      session = session!(group)

      assert_raise Ecto.ConstraintError, ~r/weight_positive/, fn ->
        Repo.insert!(%Participant{session_id: session.id, member_id: m.id, weight: 0})
      end
    end

    test "member role, rounding unit and cost amount are restricted" do
      group = group!()

      assert_raise Ecto.ConstraintError, ~r/role_allowed/, fn ->
        member!(group, role: "admin")
      end

      assert_raise Ecto.ConstraintError, ~r/rounding_unit_allowed/, fn ->
        Repo.insert!(%Group{name: "x", invite_token: "t#{uniq()}", rounding_unit: 250})
      end

      session = session!(group)

      assert_raise Ecto.ConstraintError, ~r/amount_positive/, fn ->
        Repo.insert!(%CostItem{session_id: session.id, category: "lapangan", amount: 0})
      end
    end
  end

  describe "uniques" do
    test "group member is unique per (group, user) only when user is set" do
      group = group!()
      user = user!()
      member!(group, user_id: user.id)
      member!(group)
      member!(group)

      assert_raise Ecto.ConstraintError, ~r/group_members_group_id_user_id_index/, fn ->
        member!(group, user_id: user.id)
      end
    end

    test "only one active session per (event, starts_at); cancelled frees the slot" do
      group = group!()
      event = event!(group)
      first = session!(group, event)

      assert_raise Ecto.ConstraintError, ~r/sessions_event_id_starts_at_index/, fn ->
        session!(group, event)
      end

      first |> Ecto.Changeset.change(status: "cancelled") |> Repo.update!()
      session!(group, event)
    end

    test "bills: one non-void bill per (session, member); re-bill allowed after void" do
      group = group!()
      session = session!(group)
      m = member!(group)

      first = bill!(session, m)

      assert_raise Ecto.ConstraintError, ~r/bills_session_id_member_id_index/, fn ->
        bill!(session, m)
      end

      first |> Ecto.Changeset.change(status: "void") |> Repo.update!()
      bill!(session, m)
      # voided bills do not count towards uniqueness either
      bill!(session, m, status: "void")
    end
  end

  defp event!(group) do
    Repo.insert!(%Event{group_id: group.id, name: "Futsal Kamis", type: "recurring"})
  end

  defp session!(group, event \\ nil) do
    event = event || event!(group)
    Repo.insert!(%Session{event_id: event.id, group_id: group.id, starts_at: @now})
  end

  defp bill!(session, member, attrs \\ []) do
    base = %Bill{
      session_id: session.id,
      member_id: member.id,
      share: 1000,
      amount_due: 1000,
      pay_token: "p#{uniq()}",
      token_expires_at: @now
    }

    Repo.insert!(struct(base, attrs))
  end
end
