defmodule PetepeteWeb.MemberControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.Groups.Member
  alias Petepete.Ledger
  alias Petepete.Ledger.{AuditLog, Entry, Event.Settlement, Txn}
  alias Petepete.{Contract, Repo}

  setup %{conn: conn} do
    group = group_fixture()
    {host_conn, host_user} = bearer_login(conn)
    host = member_fixture(group, role: "host", user: host_user)
    roster_entry = member_fixture(group, role: "member")
    {claimer_conn, claimer} = bearer_login(build_conn())

    %{
      group: group,
      host_conn: host_conn,
      host_user: host_user,
      host: host,
      entry: roster_entry,
      claimer_conn: claimer_conn,
      claimer: claimer
    }
  end

  defp claim_path(member), do: ~p"/api/members/#{member.id}/claim"
  defp approve_path(member), do: ~p"/api/members/#{member.id}/claim/approve"
  defp reject_path(member), do: ~p"/api/members/#{member.id}/claim/reject"
  defp reload(member), do: Repo.get!(Member, member.id)

  defp ledger_snapshot do
    %{
      txns: Repo.all(Txn) |> Enum.sort_by(& &1.id),
      entries: Repo.all(Entry) |> Enum.sort_by(& &1.id),
      audit: Repo.all(AuditLog) |> Enum.sort_by(& &1.id)
    }
  end

  describe "claim then approve" do
    test "links the account to the roster entry and leaves every ledger row untouched", ctx do
      {:ok, _} =
        Repo.transaction(fn ->
          Ledger.record(
            host_actor(ctx.group, ctx.host),
            %Settlement{
              idempotency_key: "claim-test-#{uniq()}",
              group_id: ctx.group.id,
              payer_member_id: ctx.entry.id,
              payee_member_id: ctx.host.id,
              amount: 25_000,
              note: "ganti air"
            }
          )
        end)

      balances = Ledger.balances(ctx.group.id)
      before = ledger_snapshot()
      assert [_] = before.txns
      assert Enum.any?(before.entries, &(&1.member_id == ctx.entry.id))

      claimed = post(ctx.claimer_conn, claim_path(ctx.entry))
      assert json_response(claimed, 200) == %{"ok" => true}
      Contract.check!("member_claim.ok", claimed)
      assert %Member{user_id: nil, claim_user_id: claim_id} = reload(ctx.entry)
      assert claim_id == ctx.claimer.id

      approved = post(ctx.host_conn, approve_path(ctx.entry))
      assert json_response(approved, 200) == %{"ok" => true}
      Contract.check!("member_claim.approved", approved)
      linked = reload(ctx.entry)
      assert linked.user_id == ctx.claimer.id
      assert linked.claim_user_id == nil
      assert linked.id == ctx.entry.id

      assert ledger_snapshot() == before
      assert Ledger.balances(ctx.group.id) == balances

      # The claimer is now a member of the group.
      assert %{"groups" => [%{"id" => gid, "role" => "member"}]} =
               get(ctx.claimer_conn, ~p"/api/groups") |> json_response(200)

      assert gid == ctx.group.id
    end

    test "the host sees who is claiming before approving", ctx do
      post(ctx.claimer_conn, claim_path(ctx.entry)) |> json_response(200)

      members =
        get(ctx.host_conn, ~p"/api/groups/#{ctx.group.id}")
        |> json_response(200)
        |> Map.fetch!("members")

      entry = Enum.find(members, &(&1["id"] == ctx.entry.id))
      assert entry["pending_claim"] == %{"display_name" => ctx.claimer.display_name}
    end

    test "claiming twice as the same user is fine", ctx do
      assert post(ctx.claimer_conn, claim_path(ctx.entry)).status == 200
      assert post(ctx.claimer_conn, claim_path(ctx.entry)).status == 200
    end
  end

  describe "claim rules" do
    test "an entry with a pending claim from someone else is 409 until the host rejects it",
         ctx do
      post(ctx.claimer_conn, claim_path(ctx.entry)) |> json_response(200)
      {other_conn, other} = bearer_login(build_conn())

      pending = post(other_conn, claim_path(ctx.entry))
      assert %{"error" => "claim_pending"} = json_response(pending, 409)
      Contract.check!("errors/claim_pending", pending)

      assert reload(ctx.entry).claim_user_id == ctx.claimer.id

      rejected = post(ctx.host_conn, reject_path(ctx.entry))
      assert json_response(rejected, 200) == %{"ok" => true}
      Contract.check!("member_claim.rejected", rejected)
      assert %Member{user_id: nil, claim_user_id: nil} = reload(ctx.entry)

      assert post(other_conn, claim_path(ctx.entry)).status == 200
      assert reload(ctx.entry).claim_user_id == other.id
    end

    test "an entry that already has an account cannot be claimed", ctx do
      refused = post(ctx.claimer_conn, claim_path(ctx.host))
      assert %{"error" => "not_claimable"} = json_response(refused, 409)
      Contract.check!("errors/not_claimable", refused)

      assert reload(ctx.host).claim_user_id == nil
    end

    test "someone already on the roster cannot claim another entry", ctx do
      member_fixture(ctx.group, role: "member", user: ctx.claimer)

      refused = post(ctx.claimer_conn, claim_path(ctx.entry))
      assert %{"error" => "already_member"} = json_response(refused, 409)
      Contract.check!("errors/already_member", refused)
    end

    test "unknown and malformed ids are 404", ctx do
      assert %{"error" => "not_found"} =
               json_response(post(ctx.claimer_conn, ~p"/api/members/0/claim"), 404)

      assert %{"error" => "not_found"} =
               json_response(post(ctx.claimer_conn, ~p"/api/members/abc/claim"), 404)

      assert %{"error" => "not_found"} =
               json_response(
                 post(ctx.claimer_conn, ~p"/api/members/99999999999999999999/claim"),
                 404
               )
    end

    test "needs a login", ctx do
      assert post(build_conn(), claim_path(ctx.entry)).status == 401
    end
  end

  describe "approve authorization" do
    setup ctx do
      post(ctx.claimer_conn, claim_path(ctx.entry)) |> json_response(200)
      :ok
    end

    test "a plain member of the group cannot approve or reject", ctx do
      {member_conn, user} = bearer_login(build_conn())
      member_fixture(ctx.group, role: "member", user: user)

      forbidden = post(member_conn, approve_path(ctx.entry))
      assert %{"error" => "forbidden"} = json_response(forbidden, 403)
      Contract.check!("errors/forbidden", forbidden)

      assert %{"error" => "forbidden"} =
               json_response(post(member_conn, reject_path(ctx.entry)), 403)

      assert %Member{user_id: nil, claim_user_id: claim_id} = reload(ctx.entry)
      assert claim_id == ctx.claimer.id
    end

    test "the claimer cannot approve their own claim", ctx do
      assert %{"error" => "not_found"} =
               json_response(post(ctx.claimer_conn, approve_path(ctx.entry)), 404)

      assert reload(ctx.entry).user_id == nil
    end

    test "the host of another group cannot see or approve it", ctx do
      {other_host, other_user} = bearer_login(build_conn())
      member_fixture(group_fixture(), role: "host", user: other_user)

      not_found = post(other_host, approve_path(ctx.entry))
      assert %{"error" => "not_found"} = json_response(not_found, 404)
      Contract.check!("errors/not_found", not_found)

      assert %{"error" => "not_found"} =
               json_response(post(other_host, reject_path(ctx.entry)), 404)

      assert reload(ctx.entry).user_id == nil
    end

    test "approving without a pending claim is 409", ctx do
      other = member_fixture(ctx.group, role: "guest")

      refused = post(ctx.host_conn, approve_path(other))
      assert %{"error" => "no_claim"} = json_response(refused, 409)
      Contract.check!("errors/no_claim", refused)

      assert reload(other).user_id == nil
    end

    test "approve is 409 when the claimer joined the group meanwhile", ctx do
      member_fixture(ctx.group, role: "member", user: ctx.claimer)

      assert %{"error" => "already_member"} =
               json_response(post(ctx.host_conn, approve_path(ctx.entry)), 409)

      assert %Member{user_id: nil, claim_user_id: claim_id} = reload(ctx.entry)
      assert claim_id == ctx.claimer.id
    end
  end
end
