defmodule PetepeteWeb.MeControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.{Clock, Contract, Ledger, Repo}
  alias Petepete.Accounts.{OtpChallenge, RefreshToken, User}
  alias Petepete.Groups.Member
  alias Petepete.Ledger.Entry
  alias Petepete.Ledger.Event.Settlement

  @t0 ~U[2026-10-06 03:00:00Z]

  setup do
    Clock.freeze(@t0)
    :ok
  end

  describe "GET and PATCH /api/me" do
    test "need a bearer token", %{conn: conn} do
      unauthenticated = get(conn, ~p"/api/me")
      assert %{"error" => "unauthenticated"} = json_response(unauthenticated, 401)
      Contract.check!("errors/unauthenticated", unauthenticated)
      assert patch(conn, ~p"/api/me", %{display_name: "Budi"}) |> json_response(401)
      assert delete(conn, ~p"/api/me") |> json_response(401)
    end

    test "a new user has no name until PATCH sets it", %{conn: conn} do
      phone = unique_phone()
      %{"new_user" => true, "access_token" => token, "user" => %{"id" => id}} = login(conn, phone)

      shown = conn |> authed(token) |> get(~p"/api/me")
      assert %{"id" => ^id, "phone" => ^phone, "display_name" => ""} = json_response(shown, 200)
      Contract.check!("me.show", shown)

      updated =
        conn |> authed(token) |> patch(~p"/api/me", %{display_name: "  Budi Santoso "})

      assert %{"id" => ^id, "display_name" => "Budi Santoso"} = json_response(updated, 200)
      Contract.check!("me.updated", updated)

      assert Repo.get!(User, id).display_name == "Budi Santoso"

      assert %{"new_user" => false, "user" => %{"display_name" => "Budi Santoso"}} =
               login(conn, phone)
    end

    test "blank, missing and over-long names are rejected", %{conn: conn} do
      %{"access_token" => token, "user" => %{"id" => id}} = login(conn, unique_phone())

      for bad <- [%{display_name: "   "}, %{display_name: ""}, %{}, %{display_name: 5}] do
        rejected = conn |> authed(token) |> patch(~p"/api/me", bad)
        assert %{"error" => "invalid_display_name"} = json_response(rejected, 422)
        Contract.check!("errors/invalid_display_name", rejected)
      end

      long = String.duplicate("a", 51)

      assert conn
             |> authed(token)
             |> patch(~p"/api/me", %{display_name: long})
             |> json_response(422)

      assert Repo.get!(User, id).display_name == ""
    end
  end

  describe "linking roster entries by phone" do
    test "08.., +62 and 62.. entries link on verify; other numbers and rows stay", %{conn: conn} do
      phone = unique_phone()
      national = String.replace_prefix(phone, "62", "")

      [g1, g2, g3, other_group] = for _ <- 1..4, do: group_fixture()
      m1 = member_fixture(g1, phone: "0" <> national, role: "guest")
      m2 = member_fixture(g2, phone: "+62 " <> national, role: "member")
      m3 = member_fixture(g3, phone: phone, role: "guest")
      stranger = member_fixture(other_group, phone: "628" <> String.duplicate("1", 9))
      no_phone = member_fixture(other_group)

      %{"new_user" => true, "user" => %{"id" => id}} = login(conn, phone)

      assert user_ids([m1, m2, m3]) == [id, id, id]
      assert user_ids([stranger, no_phone]) == [nil, nil]
      # roles are the host's choice and do not change
      assert Repo.get!(Member, m1.id).role == "guest"
    end

    test "linking is idempotent across logins", %{conn: conn} do
      phone = unique_phone()
      member = member_fixture(group_fixture(), phone: phone)

      %{"user" => %{"id" => id}} = login(conn, phone)
      %{"user" => %{"id" => ^id}} = login(conn, phone)

      assert user_ids([member]) == [id]
      assert Repo.aggregate(from(m in Member, where: m.user_id == ^id), :count) == 1
    end

    test "one entry per group, and none where the user already has one", %{conn: conn} do
      phone = unique_phone()
      national = String.replace_prefix(phone, "62", "")
      group = group_fixture()
      first = member_fixture(group, phone: phone, role: "guest")
      second = member_fixture(group, phone: "0" <> national, role: "guest")

      joined_group = group_fixture()
      user = Repo.insert!(%User{phone: phone, display_name: "Sudah ada"})
      own = member_fixture(joined_group, user_id: user.id)
      duplicate = member_fixture(joined_group, phone: phone, role: "guest")

      assert %{"user" => %{"id" => id}} = login(conn, phone)
      assert id == user.id
      assert user_ids([first, second]) == [id, nil]
      assert user_ids([own, duplicate]) == [id, nil]
    end

    test "never takes an entry another account holds or claims", %{conn: conn} do
      phone = unique_phone()
      owner = user_fixture()
      claimer = user_fixture()
      [g1, g2] = [group_fixture(), group_fixture()]
      held = member_fixture(g1, phone: phone, user_id: owner.id)
      claimed = member_fixture(g2, phone: phone, claim_user_id: claimer.id)

      %{"user" => %{"id" => id}} = login(conn, phone)

      assert user_ids([held, claimed]) == [owner.id, nil]
      assert Repo.get!(Member, claimed.id).claim_user_id == claimer.id
      refute id in [owner.id, claimer.id]
    end

    test "entries added after login link on PATCH /me", %{conn: conn} do
      phone = unique_phone()
      %{"access_token" => token, "user" => %{"id" => id}} = login(conn, phone)
      late = member_fixture(group_fixture(), phone: "0" <> String.replace_prefix(phone, "62", ""))
      assert user_ids([late]) == [nil]

      conn |> authed(token) |> patch(~p"/api/me", %{display_name: "Sari"}) |> json_response(200)

      assert user_ids([late]) == [id]
    end
  end

  describe "DELETE /api/me" do
    test "anonymises user and roster but leaves the ledger untouched", %{conn: conn} do
      phone = unique_phone()
      group = group_fixture()
      {_host_user, host} = host_fixture(group)
      leaver = member_fixture(group, phone: phone, display_name: "Budi", role: "member")

      %{"access_token" => access, "refresh_token" => refresh, "user" => %{"id" => id}} =
        login(conn, phone)

      assert user_ids([leaver]) == [id]

      other =
        member_fixture(group, display_name: "Citra", phone: "6281" <> String.duplicate("9", 8))

      txn = settle(host, group, payer: leaver, payee: host, amount: 15_000)
      entries_before = entries(group)
      assert length(entries_before) == 2
      assert Enum.any?(entries_before, &(&1.member_id == leaver.id))

      deleted = conn |> authed(access) |> delete(~p"/api/me")
      assert json_response(deleted, 200) == %{"ok" => true}
      Contract.check!("me.deleted", deleted)

      user = Repo.get!(User, id)
      assert user.phone == "deleted:#{id}"
      assert user.display_name == "Mantan anggota"
      assert user.deleted_at == @t0

      leaver = Repo.get!(Member, leaver.id)
      assert %{display_name: "Mantan anggota", phone: nil} = leaver
      assert Repo.get!(Member, other.id).display_name == "Citra"
      assert Repo.get!(Member, other.id).phone

      assert entries(group) == entries_before
      assert Repo.get!(Petepete.Ledger.Txn, txn.id)
      assert Ledger.balances(group.id).members[leaver.id] == 15_000

      refute Enum.any?(Repo.all(OtpChallenge), &(&1.phone_hash == phone_hash(phone)))

      assert Repo.aggregate(
               from(t in RefreshToken, where: t.user_id == ^id and is_nil(t.revoked_at)),
               :count
             ) == 0

      assert conn |> authed(access) |> get(~p"/api/me") |> json_response(401)
      assert post(conn, ~p"/api/auth/refresh", %{refresh_token: refresh}) |> json_response(401)
    end

    test "the same phone logs in afterwards as a fresh user", %{conn: conn} do
      phone = unique_phone()
      %{"access_token" => token, "user" => %{"id" => old_id}} = login(conn, phone)
      conn |> authed(token) |> delete(~p"/api/me") |> json_response(200)

      assert %{"new_user" => true, "user" => %{"id" => new_id, "display_name" => ""}} =
               login(conn, phone)

      refute new_id == old_id
      assert Repo.get!(User, new_id).phone == phone
    end

    test "is refused while hosting a group with other members", %{conn: conn} do
      {conn, id} = login_as_host(conn, group = group_fixture())
      member_fixture(group, role: "guest")

      refused = delete(conn, ~p"/api/me")
      assert %{"error" => "still_host"} = json_response(refused, 422)
      Contract.check!("errors/still_host", refused)

      assert %{deleted_at: nil, display_name: "Host"} = Repo.get!(User, id)
      assert conn |> get(~p"/api/me") |> json_response(200)
    end

    test "is refused while hosting a group with a live session", %{conn: conn} do
      {conn, _id} = login_as_host(conn, group = group_fixture())
      session_fixture(event_fixture(group), status: "cancelled")
      session_fixture(event_fixture(group), status: "issued", starts_at: ~U[2026-10-07 03:00:00Z])

      assert %{"error" => "still_host"} = conn |> delete(~p"/api/me") |> json_response(422)
    end

    test "is accepted for a host whose group is empty or only has cancelled sessions",
         %{conn: conn} do
      {conn, id} = login_as_host(conn, group = group_fixture())
      session_fixture(event_fixture(group), status: "cancelled")

      assert conn |> delete(~p"/api/me") |> json_response(200)
      assert Repo.get!(User, id).deleted_at
    end

    test "is accepted for a member of someone else's active group", %{conn: conn} do
      group = group_fixture()
      host_fixture(group)
      session_fixture(event_fixture(group), status: "issued")
      phone = unique_phone()
      member = member_fixture(group, phone: phone)
      %{"access_token" => token} = login(conn, phone)

      assert conn |> authed(token) |> delete(~p"/api/me") |> json_response(200)
      assert Repo.get!(Member, member.id).display_name == "Mantan anggota"
    end
  end

  defp login_as_host(conn, group) do
    {conn, user} = bearer_login(conn)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [display_name: "Host"])
    member_fixture(group, role: "host", user: user)
    {conn, user.id}
  end

  defp settle(host, group, opts) do
    {:ok, {:ok, %{txn: txn}}} =
      Repo.transaction(fn ->
        Ledger.record(host_actor(group, host), %Settlement{
          idempotency_key: "k#{uniq()}",
          group_id: group.id,
          payer_member_id: opts[:payer].id,
          payee_member_id: opts[:payee].id,
          amount: opts[:amount],
          note: "ganti talangan"
        })
      end)

    txn
  end

  defp entries(group),
    do: Repo.all(from e in Entry, where: e.group_id == ^group.id, order_by: e.id)

  defp user_ids(members) do
    ids = Enum.map(members, & &1.id)

    rows = Repo.all(from m in Member, where: m.id in ^ids, select: {m.id, m.user_id})
    Enum.map(ids, &Map.fetch!(Map.new(rows), &1))
  end

  defp phone_hash(phone),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        :petepete |> Application.fetch_env!(Petepete.Accounts) |> Keyword.fetch!(:otp_hmac_key),
        ["phone:", phone]
      )

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp unique_phone,
    do:
      "628" <>
        (System.unique_integer([:positive])
         |> rem(1_000_000_000)
         |> Integer.to_string()
         |> String.pad_leading(9, "0"))

  defp login(conn, phone) do
    # a fresh IP per login keeps these helpers clear of the per-IP limit
    ip =
      {10, 8, rem(System.unique_integer([:positive]), 250),
       rem(System.unique_integer([:positive]), 250)}

    assert post(%{conn | remote_ip: ip}, ~p"/api/auth/otp", %{phone: phone})
           |> json_response(200) == %{"ok" => true}

    assert_received {:otp_sent, _normalized, code}
    post(conn, ~p"/api/auth/verify", %{phone: phone, code: code}) |> json_response(200)
  end
end
