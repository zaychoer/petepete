defmodule PetepeteWeb.LedgerControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures
  import Ecto.Query

  alias Petepete.Ledger
  alias Petepete.Ledger.{AuditLog, Event, Txn}
  alias Petepete.Repo

  setup %{conn: conn} do
    g = group_fixture()
    other = group_fixture()
    {host, host_m} = login_member(g, "host")
    {plain, _} = login_member(g, "member")
    {outsider, _} = login_member(other, "host")
    andi = member_fixture(g, role: "member")
    budi = member_fixture(g, role: "member")

    Repo.update_all(from(m in Petepete.Groups.Member, where: m.id == ^andi.id),
      set: [display_name: "Andi"]
    )

    Repo.update_all(from(m in Petepete.Groups.Member, where: m.id == ^budi.id),
      set: [display_name: "Budi"]
    )

    %{
      conn: conn,
      g: g,
      host_conn: bearer_conn(conn, host),
      plain_conn: bearer_conn(conn, plain),
      outsider_conn: bearer_conn(conn, outsider),
      host: host,
      host_m: host_m,
      andi: andi,
      budi: budi
    }
  end

  # Phones must pass OTP normalization, unlike the generic fixture phones.
  defp login_member(group, role) do
    user = user_fixture(phone: valid_phone())
    {user, member_fixture(group, role: role, user: user)}
  end

  defp key, do: "k#{System.unique_integer([:positive])}"

  defp keyed(conn, key), do: put_req_header(conn, "idempotency-key", key)

  defp audit_rows(group_id, action),
    do: Repo.all(from a in AuditLog, where: a.group_id == ^group_id and a.action == ^action)

  defp txn_count(group_id),
    do: Repo.aggregate(from(t in Txn, where: t.group_id == ^group_id), :count)

  defp fund_kas(g, host, member, amount) do
    # A session bill with a kas remainder funds kas without involving the HTTP layer.
    {:ok, _} =
      Repo.transaction(fn ->
        Ledger.record(
          {:host, host.id},
          %Event.SessionBilled{
            idempotency_key: key(),
            group_id: g.id,
            session_id: session_fixture(event_fixture(g)).id,
            shares: [{member.id, amount}],
            kas_remainder: amount
          }
        )
        |> case do
          {:ok, _} -> :ok
        end
      end)
  end

  describe "POST settlements" do
    test "records a settlement and an audit row", ctx do
      body = %{
        from_member_id: ctx.andi.id,
        to_member_id: ctx.budi.id,
        amount: 45_000,
        note: "talangan"
      }

      conn = ctx.host_conn |> keyed(key()) |> post(~p"/api/groups/#{ctx.g.id}/settlements", body)

      assert %{"txn_id" => id, "replayed" => false} = json_response(conn, 201)
      assert %Txn{kind: "settlement", reason: "talangan"} = Repo.get!(Txn, id)

      assert [%{subject_id: ^id, actor_user_id: uid, metadata: %{"amount" => 45_000}}] =
               audit_rows(ctx.g.id, "settlement.record")

      assert uid == ctx.host.id
    end

    test "the same key twice posts one txn and one audit row", ctx do
      body = %{from_member_id: ctx.andi.id, to_member_id: ctx.budi.id, amount: 45_000}
      k = key()
      c1 = ctx.host_conn |> keyed(k) |> post(~p"/api/groups/#{ctx.g.id}/settlements", body)
      c2 = ctx.host_conn |> keyed(k) |> post(~p"/api/groups/#{ctx.g.id}/settlements", body)

      assert %{"txn_id" => id} = json_response(c1, 201)
      assert %{"txn_id" => ^id, "replayed" => true} = json_response(c2, 200)
      assert txn_count(ctx.g.id) == 1
      assert length(audit_rows(ctx.g.id, "settlement.record")) == 1
    end

    test "a missing key is 422 and posts nothing", ctx do
      body = %{from_member_id: ctx.andi.id, to_member_id: ctx.budi.id, amount: 45_000}
      conn = post(ctx.host_conn, ~p"/api/groups/#{ctx.g.id}/settlements", body)

      assert %{"error" => "idempotency_key_required", "message" => _} = json_response(conn, 422)
      assert txn_count(ctx.g.id) == 0
    end

    test "ledger rejections are 422 with a code and no audit row", ctx do
      conn =
        ctx.host_conn
        |> keyed(key())
        |> post(~p"/api/groups/#{ctx.g.id}/settlements", %{
          from_member_id: ctx.andi.id,
          to_member_id: ctx.andi.id,
          amount: 1000
        })

      assert %{"error" => "same_member"} = json_response(conn, 422)
      assert audit_rows(ctx.g.id, "settlement.record") == []
    end

    test "malformed bodies are 422 invalid_params", ctx do
      conn =
        ctx.host_conn
        |> keyed(key())
        |> post(~p"/api/groups/#{ctx.g.id}/settlements", %{
          from_member_id: ctx.andi.id,
          amount: "45000"
        })

      assert %{"error" => "invalid_params", "details" => details} = json_response(conn, 422)
      assert Map.keys(details) |> Enum.sort() == ["amount", "to_member_id"]
    end

    test "only the group's host may write", ctx do
      body = %{from_member_id: ctx.andi.id, to_member_id: ctx.budi.id, amount: 1000}
      path = ~p"/api/groups/#{ctx.g.id}/settlements"

      assert ctx.plain_conn |> keyed(key()) |> post(path, body) |> json_response(403)
      assert ctx.outsider_conn |> keyed(key()) |> post(path, body) |> json_response(404)
      assert ctx.conn |> keyed(key()) |> post(path, body) |> json_response(401)
      assert txn_count(ctx.g.id) == 0
    end
  end

  describe "POST kas-spends" do
    test "spends from kas, replays once, and rejects beyond the balance", ctx do
      fund_kas(ctx.g, ctx.host, ctx.andi, 100_000)
      path = ~p"/api/groups/#{ctx.g.id}/kas-spends"
      body = %{member_id: ctx.andi.id, amount: 60_000, note: "bola"}
      k = key()

      c1 = ctx.host_conn |> keyed(k) |> post(path, body)
      c2 = ctx.host_conn |> keyed(k) |> post(path, body)
      assert %{"txn_id" => id} = json_response(c1, 201)
      assert %{"txn_id" => ^id, "replayed" => true} = json_response(c2, 200)
      assert Ledger.balances(ctx.g.id).kas == 40_000
      assert length(audit_rows(ctx.g.id, "kas_spend.record")) == 1

      over = ctx.host_conn |> keyed(key()) |> post(path, %{body | amount: 40_001})
      assert %{"error" => "insufficient_kas"} = json_response(over, 422)
      assert Ledger.balances(ctx.g.id).kas == 40_000
      assert length(audit_rows(ctx.g.id, "kas_spend.record")) == 1
    end

    test "authorization is per group", ctx do
      path = ~p"/api/groups/#{ctx.g.id}/kas-spends"
      body = %{member_id: ctx.andi.id, amount: 1}
      assert ctx.plain_conn |> keyed(key()) |> post(path, body) |> json_response(403)
      assert ctx.outsider_conn |> keyed(key()) |> post(path, body) |> json_response(404)
    end
  end

  describe "POST txns/:id/correction" do
    setup ctx do
      body = %{from_member_id: ctx.andi.id, to_member_id: ctx.budi.id, amount: 45_000}
      c = ctx.host_conn |> keyed(key()) |> post(~p"/api/groups/#{ctx.g.id}/settlements", body)
      %{"txn_id" => id} = json_response(c, 201)
      %{settlement_id: id}
    end

    test "reverses the txn; history keeps both; replay is one txn", ctx do
      path = ~p"/api/txns/#{ctx.settlement_id}/correction"
      k = key()
      c1 = ctx.host_conn |> keyed(k) |> post(path, %{reason: "salah orang"})
      c2 = ctx.host_conn |> keyed(k) |> post(path, %{reason: "salah orang"})

      assert %{"txn_id" => cid, "replayed" => false} = json_response(c1, 201)
      assert %{"txn_id" => ^cid, "replayed" => true} = json_response(c2, 200)
      assert txn_count(ctx.g.id) == 2

      assert [%{subject_id: ^cid, metadata: %{"reason" => "salah orang"}}] =
               audit_rows(ctx.g.id, "txn.correct")

      assert Enum.all?(Ledger.balances(ctx.g.id).members, fn {_, v} -> v == 0 end)

      %{"txns" => txns} =
        ctx.host_conn |> get(~p"/api/groups/#{ctx.g.id}/txns") |> json_response(200)

      assert [
               %{"id" => sid, "kind" => "settlement"},
               %{"id" => ^cid, "reverses_txn_id" => sid, "kind" => "correction"}
             ] =
               txns
    end

    test "reason is required", ctx do
      conn =
        ctx.host_conn |> keyed(key()) |> post(~p"/api/txns/#{ctx.settlement_id}/correction", %{})

      assert %{"error" => "reason_required"} = json_response(conn, 422)
      assert audit_rows(ctx.g.id, "txn.correct") == []
    end

    test "a second correction of the same txn is rejected", ctx do
      path = ~p"/api/txns/#{ctx.settlement_id}/correction"
      assert ctx.host_conn |> keyed(key()) |> post(path, %{reason: "x"}) |> json_response(201)
      conn = ctx.host_conn |> keyed(key()) |> post(path, %{reason: "lagi"})
      assert %{"error" => "already_reversed"} = json_response(conn, 422)
    end

    test "other kinds (and corrections themselves) are not undoable", ctx do
      {:ok, billed} =
        Repo.transaction(fn ->
          {:ok, %{txn: t}} =
            Ledger.record({:host, ctx.host.id}, %Event.SessionBilled{
              idempotency_key: key(),
              group_id: ctx.g.id,
              session_id: session_fixture(event_fixture(ctx.g)).id,
              shares: [{ctx.andi.id, 5000}],
              kas_remainder: 5000
            })

          t
        end)

      conn =
        ctx.host_conn
        |> keyed(key())
        |> post(~p"/api/txns/#{billed.id}/correction", %{reason: "x"})

      assert %{"error" => "not_undoable"} = json_response(conn, 422)
    end

    test "authorization is by the txn's group", ctx do
      path = ~p"/api/txns/#{ctx.settlement_id}/correction"
      assert ctx.plain_conn |> keyed(key()) |> post(path, %{reason: "x"}) |> json_response(403)
      assert ctx.outsider_conn |> keyed(key()) |> post(path, %{reason: "x"}) |> json_response(404)

      assert ctx.host_conn
             |> keyed(key())
             |> post(~p"/api/txns/0/correction", %{reason: "x"})
             |> json_response(404)
    end
  end

  describe "GET balances and txns" do
    test "any member reads balances; outsiders get 404", ctx do
      fund_kas(ctx.g, ctx.host, ctx.andi, 20_000)

      body = ctx.plain_conn |> get(~p"/api/groups/#{ctx.g.id}/balances") |> json_response(200)
      assert body["kas"] == 20_000

      assert %{"member_id" => _, "display_name" => "Andi", "balance" => -20_000} =
               Enum.find(body["members"], &(&1["display_name"] == "Andi"))

      assert ctx.outsider_conn |> get(~p"/api/groups/#{ctx.g.id}/balances") |> json_response(404)
    end

    test "history is visible to plain members, describes txns in casual text, filters by member",
         ctx do
      body = %{from_member_id: ctx.andi.id, to_member_id: ctx.budi.id, amount: 1_245_000}
      ctx.host_conn |> keyed(key()) |> post(~p"/api/groups/#{ctx.g.id}/settlements", body)

      ctx.host_conn
      |> keyed(key())
      |> post(~p"/api/groups/#{ctx.g.id}/settlements", %{
        from_member_id: ctx.host_m.id,
        to_member_id: ctx.budi.id,
        amount: 45_000
      })

      path = ~p"/api/groups/#{ctx.g.id}/txns"
      all = ctx.plain_conn |> get(path) |> json_response(200)

      assert [%{"description" => "Andi bayar Rp1.245.000 ke Budi", "entries" => [_, _]}, _] =
               all["txns"]

      filtered = ctx.plain_conn |> get(path, %{member_id: ctx.andi.id}) |> json_response(200)
      assert [%{"description" => "Andi bayar Rp1.245.000 ke Budi"}] = filtered["txns"]

      assert ctx.outsider_conn |> get(path) |> json_response(404)
      assert ctx.plain_conn |> get(path, %{member_id: "abc"}) |> json_response(422)
    end
  end
end
