defmodule Petepete.LedgerTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.{Actor, Ledger}

  alias Petepete.Ledger.Event.{
    CashPaymentCancelled,
    CashReceived,
    Correction,
    GatewayPaymentReceived,
    KasSpend,
    SessionBilled,
    SessionBillsCancelled,
    Settlement
  }

  @t0 ~U[2026-10-06 10:00:00Z]

  setup do
    host_user = user_fixture()
    group = group_fixture()
    host = member_fixture(group, user_id: host_user.id, role: "host")
    [a, b, c] = for _ <- 1..3, do: member_fixture(group)
    payout_account_fixture(group, host)

    {:ok, g: group.id, actor: host_actor(group, host), host: host.id, a: a.id, b: b.id, c: c.id}
  end

  defp key, do: "k#{System.unique_integer([:positive])}"

  defp record!(actor, event) do
    {:ok, res} = Repo.transaction(fn -> Ledger.record(actor, event) end) |> unwrap()
    res
  end

  defp try_record(actor, event) do
    {:ok, result} = Repo.transaction(fn -> Ledger.record(actor, event) end)
    result
  end

  defp unwrap({:ok, {:ok, res}}), do: {:ok, res}
  defp unwrap({:ok, {:error, _} = e}), do: e

  defp entries(txn),
    do: txn.entries |> Enum.map(&{&1.account_type, &1.member_id, &1.amount}) |> Enum.sort()

  defp billed(ctx, overrides \\ []) do
    struct!(
      %SessionBilled{
        idempotency_key: key(),
        group_id: ctx.g,
        session_id: 7,
        shares: [{ctx.host, 34_000}, {ctx.a, 34_000}, {ctx.b, 34_000}],
        fronted: [{ctx.host, 100_000}],
        kas_remainder: 2_000
      },
      overrides
    )
  end

  defp cash(ctx, overrides \\ []) do
    struct!(
      %CashReceived{
        idempotency_key: key(),
        group_id: ctx.g,
        bill_id: 9,
        member_id: ctx.a,
        amount: 34_000,
        at: @t0
      },
      overrides
    )
  end

  defp settlement(ctx, overrides \\ []) do
    struct!(
      %Settlement{
        idempotency_key: key(),
        group_id: ctx.g,
        payer_member_id: ctx.host,
        payee_member_id: ctx.a,
        amount: 10_000,
        note: "ganti talangan"
      },
      overrides
    )
  end

  defp kas_spend(ctx, overrides \\ []) do
    struct!(
      %KasSpend{
        idempotency_key: key(),
        group_id: ctx.g,
        member_id: ctx.b,
        amount: 1_500,
        note: "bola"
      },
      overrides
    )
  end

  defp gateway(ctx, overrides \\ []) do
    struct!(
      %GatewayPaymentReceived{
        idempotency_key: key(),
        group_id: ctx.g,
        bill_id: 9,
        member_id: ctx.b,
        amount: 34_000
      },
      overrides
    )
  end

  describe "entries per event" do
    test "session_billed: shares debit, fronted and kas remainder credit", ctx do
      %{txn: txn, replayed: false} = record!(ctx.actor, billed(ctx))

      assert txn.kind == "session_billed"
      assert {txn.ref_type, txn.ref_id} == {"session", 7}

      assert entries(txn) ==
               Enum.sort([
                 {"kas", nil, 2_000},
                 {"member", ctx.host, -34_000},
                 {"member", ctx.host, 100_000},
                 {"member", ctx.a, -34_000},
                 {"member", ctx.b, -34_000}
               ])

      assert Ledger.balances(ctx.g) == %{
               kas: 2_000,
               members: %{ctx.host => 66_000, ctx.a => -34_000, ctx.b => -34_000, ctx.c => 0}
             }
    end

    test "session_billed without remainder writes no kas entry", ctx do
      ev = billed(ctx, shares: [{ctx.a, 50_000}], fronted: [{ctx.host, 50_000}], kas_remainder: 0)
      %{txn: txn} = record!(ctx.actor, ev)
      refute Enum.any?(txn.entries, &(&1.account_type == "kas"))
    end

    test "gateway_payment_received: payer credited, payout account owner debited", ctx do
      %{txn: txn} = record!(Actor.gateway(), gateway(ctx))

      assert {txn.kind, txn.actor_type, txn.actor_user_id} ==
               {"gateway_payment_received", "gateway", nil}

      assert {txn.ref_type, txn.ref_id} == {"bill", 9}
      assert entries(txn) == Enum.sort([{"member", ctx.b, 34_000}, {"member", ctx.host, -34_000}])
    end

    test "cash_received: payer credited, acting host's member debited, at is the txn time", ctx do
      %{txn: txn} = record!(ctx.actor, cash(ctx))

      assert txn.kind == "cash_received"
      assert txn.inserted_at == @t0
      assert entries(txn) == Enum.sort([{"member", ctx.a, 34_000}, {"member", ctx.host, -34_000}])
    end

    test "settlement: payer +X, payee -X", ctx do
      %{txn: txn} = record!(ctx.actor, settlement(ctx))

      assert txn.reason == "ganti talangan"
      assert entries(txn) == Enum.sort([{"member", ctx.host, 10_000}, {"member", ctx.a, -10_000}])
    end

    test "kas_spend: kas -X, member +X", ctx do
      record!(ctx.actor, billed(ctx))
      %{txn: txn} = record!(ctx.actor, kas_spend(ctx))

      assert entries(txn) == Enum.sort([{"kas", nil, -1_500}, {"member", ctx.b, 1_500}])
      assert Ledger.balances(ctx.g).kas == 500
    end

    test "undo events post the mirror of the original", ctx do
      %{txn: billed} = record!(ctx.actor, billed(ctx))

      %{txn: cancelled} =
        record!(ctx.actor, %SessionBillsCancelled{
          idempotency_key: key(),
          group_id: ctx.g,
          txn_id: billed.id,
          reason: "salah input"
        })

      assert cancelled.kind == "session_bills_cancelled"
      assert cancelled.reverses_txn_id == billed.id
      assert cancelled.reason == "salah input"
      assert {cancelled.ref_type, cancelled.ref_id} == {"session", 7}
      assert entries(cancelled) == Enum.sort(for {t, m, a} <- entries(billed), do: {t, m, -a})

      assert Ledger.balances(ctx.g) == %{
               kas: 0,
               members: %{ctx.host => 0, ctx.a => 0, ctx.b => 0, ctx.c => 0}
             }
    end
  end

  describe "session_billed result" do
    test "carries each participant's balance immediately before posting", ctx do
      record!(ctx.actor, billed(ctx))
      record!(ctx.actor, cash(ctx, amount: 40_000))

      ev =
        billed(ctx,
          session_id: 8,
          shares: [{ctx.a, 20_000}, {ctx.c, 20_000}],
          fronted: [{ctx.b, 40_000}],
          kas_remainder: 0
        )

      %{balances_before: before} = record!(ctx.actor, ev)

      # a: -34_000 (first bill) + 40_000 cash; c: untouched
      assert before == %{ctx.a => 6_000, ctx.c => 0}
      assert Ledger.balances(ctx.g).members[ctx.a] == 6_000 - 20_000
    end
  end

  describe "rules" do
    test "unbalanced shares are rejected before the database trigger and write nothing", ctx do
      assert {:error, :unbalanced_shares} =
               try_record(ctx.actor, billed(ctx, kas_remainder: 1_000))

      assert {:error, :unbalanced_shares} =
               try_record(ctx.actor, billed(ctx, kas_remainder: 3_000))

      assert Ledger.txns(ctx.g) == []
    end

    test "session_billed structural errors", ctx do
      assert {:error, :negative_remainder} =
               try_record(
                 ctx.actor,
                 billed(ctx,
                   shares: [{ctx.a, 1_000}],
                   fronted: [{ctx.host, 2_000}],
                   kas_remainder: -1_000
                 )
               )

      assert {:error, :empty_shares} =
               try_record(ctx.actor, billed(ctx, shares: [], fronted: [], kas_remainder: 0))

      assert {:error, :duplicate_member} =
               try_record(
                 ctx.actor,
                 billed(ctx,
                   shares: [{ctx.a, 1_000}, {ctx.a, 1_000}],
                   fronted: [{ctx.host, 2_000}],
                   kas_remainder: 0
                 )
               )

      assert {:error, :amount_not_positive} =
               try_record(
                 ctx.actor,
                 billed(ctx, shares: [{ctx.a, 0}], fronted: [], kas_remainder: 0)
               )
    end

    test "amounts must be positive integers", ctx do
      for amount <- [0, -5, 1.5, nil] do
        assert {:error, :amount_not_positive} =
                 try_record(Actor.gateway(), gateway(ctx, amount: amount))

        assert {:error, :amount_not_positive} = try_record(ctx.actor, cash(ctx, amount: amount))

        assert {:error, :amount_not_positive} =
                 try_record(ctx.actor, settlement(ctx, amount: amount))

        assert {:error, :amount_not_positive} =
                 try_record(ctx.actor, kas_spend(ctx, amount: amount))
      end
    end

    test "members must belong to the event's group", ctx do
      other = member_fixture(group_fixture())

      assert {:error, :member_not_in_group} =
               try_record(ctx.actor, settlement(ctx, payee_member_id: other.id))

      assert {:error, :member_not_in_group} =
               try_record(Actor.gateway(), gateway(ctx, member_id: other.id))

      assert {:error, :member_not_in_group} =
               try_record(ctx.actor, billed(ctx, fronted: [{other.id, 100_000}]))

      assert {:error, :member_not_in_group} =
               try_record(ctx.actor, cash(ctx, member_id: other.id))
    end

    test "guests and former members count as members", ctx do
      guest = member_fixture(%{id: ctx.g}, role: "guest")
      assert {:ok, _} = try_record(ctx.actor, settlement(ctx, payee_member_id: guest.id))
    end

    test "settlement needs two different members", ctx do
      assert {:error, :same_member} =
               try_record(ctx.actor, settlement(ctx, payee_member_id: ctx.host))
    end

    test "kas_spend is capped by the kas balance, cash and gateway payments are not", ctx do
      assert {:error, :insufficient_kas} = try_record(ctx.actor, kas_spend(ctx))

      record!(ctx.actor, billed(ctx))
      assert {:error, :insufficient_kas} = try_record(ctx.actor, kas_spend(ctx, amount: 2_001))
      assert {:ok, _} = try_record(ctx.actor, kas_spend(ctx, amount: 2_000))
      assert {:error, :insufficient_kas} = try_record(ctx.actor, kas_spend(ctx, amount: 1))

      assert {:ok, _} = try_record(ctx.actor, cash(ctx, amount: 9_999_999))
      assert {:ok, _} = try_record(Actor.gateway(), gateway(ctx, amount: 9_999_999))
    end

    test "actor rules by kind", ctx do
      assert {:error, :invalid_actor} = try_record(ctx.actor, gateway(ctx))

      for {actor, ev} <- [
            {Actor.gateway(), billed(ctx)},
            {Actor.gateway(), cash(ctx)},
            {Actor.gateway(), settlement(ctx)},
            {Actor.gateway(), kas_spend(ctx)},
            {%Actor{type: :system, user_id: 1, member_id: ctx.host}, settlement(ctx)},
            {%Actor{type: :host, user_id: "x", member_id: ctx.host}, settlement(ctx)},
            {%Actor{type: :host, user_id: 1, member_id: nil}, settlement(ctx)},
            {%Actor{type: :host, user_id: nil, member_id: nil}, gateway(ctx)}
          ] do
        assert {:error, :invalid_actor} = try_record(actor, ev)
      end
    end

    test "cash_received needs the host Actor's member to be on the group's roster", ctx do
      elsewhere = member_fixture(group_fixture(), role: "host", user: user_fixture())
      actor = %Actor{type: :host, user_id: elsewhere.user_id, member_id: elsewhere.id}

      assert {:error, :member_not_in_group} = try_record(actor, cash(ctx))
    end

    test "gateway payment needs a payout account", ctx do
      bare = group_fixture()
      m = member_fixture(bare)

      assert {:error, :no_payout_account} =
               try_record(Actor.gateway(), gateway(ctx, group_id: bare.id, member_id: m.id))
    end

    test "idempotency key is required", ctx do
      for k <- [nil, "", "  "] do
        assert {:error, :idempotency_key_required} =
                 try_record(ctx.actor, settlement(ctx, idempotency_key: k))
      end
    end

    test "unknown group and unknown event", ctx do
      assert {:error, :group_not_found} = try_record(ctx.actor, settlement(ctx, group_id: 0))
      assert {:error, :unknown_event} = try_record(ctx.actor, %{kind: :settlement})
    end

    test "record/2 raises outside the caller's transaction" do
      # The sandbox owner connection runs in a transaction, so check from a plain connection.
      ev = %Settlement{
        idempotency_key: "x",
        group_id: 1,
        payer_member_id: 1,
        payee_member_id: 2,
        amount: 1
      }

      assert_raise ArgumentError, ~r/inside the caller's/, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Ledger.record(%Actor{type: :host, user_id: 1, member_id: 1}, ev)
        end)
      end
    end
  end

  describe "idempotency" do
    test "same key and same event returns the original txn without posting again", ctx do
      ev = settlement(ctx)
      %{txn: first, replayed: false} = record!(ctx.actor, ev)
      %{txn: again, replayed: true} = record!(ctx.actor, ev)

      assert again.id == first.id
      assert entries(again) == entries(first)
      assert length(Ledger.txns(ctx.g)) == 1
    end

    test "a replay succeeds even after state moved on", ctx do
      record!(ctx.actor, billed(ctx))
      ev = kas_spend(ctx, amount: 2_000)
      %{txn: first} = record!(ctx.actor, ev)
      assert %{txn: %{id: id}, replayed: true} = record!(ctx.actor, ev)
      assert id == first.id
    end

    test "replayed session_billed reports the balances from before the original posting", ctx do
      record!(ctx.actor, cash(ctx, amount: 5_000))
      ev = billed(ctx)
      %{balances_before: first} = record!(ctx.actor, ev)
      assert first[ctx.a] == 5_000

      %{balances_before: again, replayed: true} = record!(ctx.actor, ev)
      assert again == first
    end

    test "gateway replay survives a change of payout account owner and keeps history", ctx do
      ev = gateway(ctx)
      %{txn: first} = record!(Actor.gateway(), ev)
      payout_account_fixture(%{id: ctx.g}, %{id: ctx.c})

      assert %{txn: %{id: id}, replayed: true} = record!(Actor.gateway(), ev)
      assert id == first.id
      assert Ledger.balances(ctx.g).members[ctx.host] == -34_000

      later = gateway(ctx, bill_id: 10)
      %{txn: txn} = record!(Actor.gateway(), later)
      assert {"member", ctx.c, -34_000} in entries(txn)
    end

    test "same key with a different event is an error", ctx do
      k = key()
      record!(ctx.actor, settlement(ctx, idempotency_key: k))

      assert {:error, :idempotency_key_conflict} =
               try_record(ctx.actor, settlement(ctx, idempotency_key: k, amount: 10_001))

      assert {:error, :idempotency_key_conflict} =
               try_record(ctx.actor, kas_spend(ctx, idempotency_key: k))

      assert {:error, :idempotency_key_conflict} =
               try_record(
                 %Actor{type: :host, user_id: user_fixture().id, member_id: ctx.host},
                 settlement(ctx, idempotency_key: k)
               )

      assert length(Ledger.txns(ctx.g)) == 1
    end

    test "keys are unique across groups", ctx do
      k = key()
      record!(ctx.actor, settlement(ctx, idempotency_key: k))
      other = group_fixture()
      a = member_fixture(other)
      b = member_fixture(other)

      assert {:error, :idempotency_key_conflict} =
               try_record(ctx.actor, %Settlement{
                 idempotency_key: k,
                 group_id: other.id,
                 payer_member_id: a.id,
                 payee_member_id: b.id,
                 amount: 10_000,
                 note: "ganti talangan"
               })
    end
  end

  describe "undo" do
    defp undo(ctx, mod, txn_id, extra \\ []) do
      struct!(
        mod,
        [idempotency_key: key(), group_id: ctx.g, txn_id: txn_id, reason: "salah"] ++ extra
      )
    end

    defp undo_events(ctx, id) do
      [
        SessionBillsCancelled: undo(ctx, SessionBillsCancelled, id),
        CashPaymentCancelled: undo(ctx, CashPaymentCancelled, id, at: @t0),
        Correction: undo(ctx, Correction, id)
      ]
    end

    test "legality matrix", ctx do
      txns = %{
        "session_billed" => record!(ctx.actor, billed(ctx)).txn,
        "gateway_payment_received" => record!(Actor.gateway(), gateway(ctx)).txn,
        "cash_received" => record!(ctx.actor, cash(ctx)).txn,
        "settlement" => record!(ctx.actor, settlement(ctx)).txn,
        "kas_spend" => record!(ctx.actor, kas_spend(ctx)).txn
      }

      allowed = %{
        SessionBillsCancelled: ["session_billed"],
        CashPaymentCancelled: ["cash_received"],
        Correction: ["settlement", "kas_spend"]
      }

      for {kind, txn} <- txns, {name, ev} <- undo_events(ctx, txn.id) do
        # a fresh event per attempt: the only rejection under test is the kind
        result = try_record(ctx.actor, ev)

        if kind in allowed[name] do
          assert {:ok, %{txn: %{reverses_txn_id: id}}} = result
          assert id == txn.id
        else
          assert {:error, :not_undoable} = result, "#{name} on #{kind}"
        end
      end
    end

    test "the three undo kinds and gateway payments are never undone", ctx do
      %{txn: s} = record!(ctx.actor, settlement(ctx))
      %{txn: c} = record!(ctx.actor, undo(ctx, Correction, s.id))

      for {_, ev} <- undo_events(ctx, c.id),
          do: assert({:error, :not_undoable} = try_record(ctx.actor, ev))
    end

    test "a txn is undone once only", ctx do
      %{txn: s} = record!(ctx.actor, settlement(ctx))
      record!(ctx.actor, undo(ctx, Correction, s.id))

      assert {:error, :already_reversed} = try_record(ctx.actor, undo(ctx, Correction, s.id))
    end

    test "undo replays with the same key", ctx do
      %{txn: s} = record!(ctx.actor, settlement(ctx))
      ev = undo(ctx, Correction, s.id)
      %{txn: first} = record!(ctx.actor, ev)
      assert %{txn: %{id: id}, replayed: true} = record!(ctx.actor, ev)
      assert id == first.id
    end

    test "reason is required", ctx do
      %{txn: s} = record!(ctx.actor, settlement(ctx))

      for r <- [nil, "", "  "] do
        assert {:error, :reason_required} =
                 try_record(ctx.actor, undo(ctx, Correction, s.id, reason: r))
      end
    end

    test "txn must exist in the event's group", ctx do
      assert {:error, :txn_not_found} = try_record(ctx.actor, undo(ctx, Correction, 0))

      %{txn: s} = record!(ctx.actor, settlement(ctx))
      other = group_fixture()

      assert {:error, :txn_not_found} =
               try_record(ctx.actor, undo(ctx, Correction, s.id, group_id: other.id))
    end

    test "correction restores balances", ctx do
      %{txn: s} = record!(ctx.actor, settlement(ctx))
      record!(ctx.actor, undo(ctx, Correction, s.id))

      assert Ledger.balances(ctx.g).members[ctx.a] == 0
      assert Ledger.balances(ctx.g).members[ctx.host] == 0
    end

    test "cash cancel: allowed up to exactly 24h after the cash txn, rejected after", ctx do
      %{txn: c} = record!(ctx.actor, cash(ctx))
      too_late = DateTime.add(@t0, 24 * 3600 + 1)
      on_time = DateTime.add(@t0, 24 * 3600)

      assert {:error, :undo_window_expired} =
               try_record(ctx.actor, undo(ctx, CashPaymentCancelled, c.id, at: too_late))

      assert {:ok, %{txn: txn}} =
               try_record(ctx.actor, undo(ctx, CashPaymentCancelled, c.id, at: on_time))

      assert txn.inserted_at == on_time
      assert Ledger.balances(ctx.g).members[ctx.a] == 0
    end

    test "cancelling a session's bills may drive the kas negative", ctx do
      %{txn: b} = record!(ctx.actor, billed(ctx))
      record!(ctx.actor, kas_spend(ctx, amount: 2_000))
      record!(ctx.actor, undo(ctx, SessionBillsCancelled, b.id))

      assert Ledger.balances(ctx.g).kas == -2_000
      assert {:error, :insufficient_kas} = try_record(ctx.actor, kas_spend(ctx, amount: 1))
    end
  end

  describe "reading" do
    test "balances equal the manual sums, including members with no entries", ctx do
      record!(ctx.actor, billed(ctx))
      record!(ctx.actor, cash(ctx))
      record!(Actor.gateway(), gateway(ctx))
      record!(ctx.actor, settlement(ctx))
      record!(ctx.actor, kas_spend(ctx, amount: 1_500))

      # host: +66_000 -34_000(cash) -34_000(gateway owner) +10_000
      # a: -34_000 +34_000 -10_000 ; b: -34_000 +34_000 +1_500 ; kas 2_000-1_500
      assert Ledger.balances(ctx.g) == %{
               kas: 500,
               members: %{ctx.host => 8_000, ctx.a => -10_000, ctx.b => 1_500, ctx.c => 0}
             }

      assert Ledger.balances(group_fixture().id) == %{kas: 0, members: %{}}
    end

    test "txns are chronological with entries and filter by member", ctx do
      %{txn: t1} = record!(ctx.actor, billed(ctx))

      %{txn: t2} =
        record!(ctx.actor, settlement(ctx, payer_member_id: ctx.a, payee_member_id: ctx.b))

      %{txn: t3} = record!(ctx.actor, kas_spend(ctx, member_id: ctx.host))

      assert Enum.map(Ledger.txns(ctx.g), & &1.id) == [t1.id, t2.id, t3.id]
      assert Enum.all?(Ledger.txns(ctx.g), &(&1.entries != []))
      assert Enum.map(Ledger.txns(ctx.g, member_id: ctx.b), & &1.id) == [t1.id, t2.id]
      assert Enum.map(Ledger.txns(ctx.g, member_id: ctx.host), & &1.id) == [t1.id, t3.id]
      assert Ledger.txns(ctx.g, member_id: ctx.c) == []
      # all entries of a matching txn are included, not only the member's
      assert [%{entries: es}] =
               Enum.filter(Ledger.txns(ctx.g, member_id: ctx.b), &(&1.id == t2.id))

      assert length(es) == 2
    end
  end
end
