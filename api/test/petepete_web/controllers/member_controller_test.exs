defmodule PetepeteWeb.MemberControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.Groups.Member
  alias Petepete.Ledger
  alias Petepete.Ledger.{AuditLog, Entry, Event.Settlement, Txn}
  alias Petepete.Repo

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
            {:host, ctx.host_user.id},
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

      assert json_response(post(ctx.claimer_conn, claim_path(ctx.entry)), 200) == %{"ok" => true}
      assert %Member{user_id: nil, claim_user_id: claim_id} = reload(ctx.entry)
      assert claim_id == ctx.claimer.id

      assert json_response(post(ctx.host_conn, approve_path(ctx.entry)), 200) == %{"ok" => true}
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

      assert json_response(post(other_conn, claim_path(ctx.entry)), 409) == %{
               "error" => "claim_pending"
             }

      assert reload(ctx.entry).claim_user_id == ctx.claimer.id

      assert json_response(post(ctx.host_conn, reject_path(ctx.entry)), 200) == %{"ok" => true}
      assert %Member{user_id: nil, claim_user_id: nil} = reload(ctx.entry)

      assert post(other_conn, claim_path(ctx.entry)).status == 200
      assert reload(ctx.entry).claim_user_id == other.id
    end

    test "an entry that already has an account cannot be claimed", ctx do
      assert json_response(post(ctx.claimer_conn, claim_path(ctx.host)), 409) == %{
               "error" => "not_claimable"
             }

      assert reload(ctx.host).claim_user_id == nil
    end

    test "someone already on the roster cannot claim another entry", ctx do
      member_fixture(ctx.group, role: "member", user: ctx.claimer)

      assert json_response(post(ctx.claimer_conn, claim_path(ctx.entry)), 409) == %{
               "error" => "already_member"
             }
    end

    test "unknown and malformed ids are 404", ctx do
      assert json_response(post(ctx.claimer_conn, ~p"/api/members/0/claim"), 404) == %{
               "error" => "not_found"
             }

      assert json_response(post(ctx.claimer_conn, ~p"/api/members/abc/claim"), 404) == %{
               "error" => "not_found"
             }

      assert json_response(
               post(ctx.claimer_conn, ~p"/api/members/99999999999999999999/claim"),
               404
             ) ==
               %{"error" => "not_found"}
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

      assert json_response(post(member_conn, approve_path(ctx.entry)), 403) == %{
               "error" => "forbidden"
             }

      assert json_response(post(member_conn, reject_path(ctx.entry)), 403) == %{
               "error" => "forbidden"
             }

      assert %Member{user_id: nil, claim_user_id: claim_id} = reload(ctx.entry)
      assert claim_id == ctx.claimer.id
    end

    test "the claimer cannot approve their own claim", ctx do
      assert json_response(post(ctx.claimer_conn, approve_path(ctx.entry)), 404) == %{
               "error" => "not_found"
             }

      assert reload(ctx.entry).user_id == nil
    end

    test "the host of another group cannot see or approve it", ctx do
      {other_host, other_user} = bearer_login(build_conn())
      member_fixture(group_fixture(), role: "host", user: other_user)

      assert json_response(post(other_host, approve_path(ctx.entry)), 404) == %{
               "error" => "not_found"
             }

      assert json_response(post(other_host, reject_path(ctx.entry)), 404) == %{
               "error" => "not_found"
             }

      assert reload(ctx.entry).user_id == nil
    end

    test "approving without a pending claim is 409", ctx do
      other = member_fixture(ctx.group, role: "guest")

      assert json_response(post(ctx.host_conn, approve_path(other)), 409) == %{
               "error" => "no_claim"
             }

      assert reload(other).user_id == nil
    end

    test "approve is 409 when the claimer joined the group meanwhile", ctx do
      member_fixture(ctx.group, role: "member", user: ctx.claimer)

      assert json_response(post(ctx.host_conn, approve_path(ctx.entry)), 409) == %{
               "error" => "already_member"
             }

      assert %Member{user_id: nil, claim_user_id: claim_id} = reload(ctx.entry)
      assert claim_id == ctx.claimer.id
    end
  end
end
