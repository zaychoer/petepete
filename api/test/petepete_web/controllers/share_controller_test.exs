defmodule PetepeteWeb.ShareControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  setup %{conn: conn} do
    {conn, user} = bearer_login(conn)
    %{conn: conn, user: user}
  end

  # A group with an issued session and two bills, one of a member with a phone.
  defp issued_group(host_user) do
    group = group_fixture(%{name: "Futsal Kamis"})
    host = member_fixture(group, "host", host_user)
    session = session_fixture(group, status: "issued")
    cost_item_fixture(session, amount: 60_000, paid_by: host)

    member =
      member_fixture(group, "member")
      |> Ecto.Changeset.change(phone: "6281234567890")
      |> Petepete.Repo.update!()

    bill = bill_fixture(session, member, %{share: 30_000, amount_due: 30_000})

    bill_fixture(session, host, %{
      share: 30_000,
      amount_due: 0,
      status: "paid",
      paid_via: "credit"
    })

    %{group: group, host: host, session: session, bill: bill}
  end

  describe "host endpoints" do
    test "bills carries the texts, pay link and wa_number", %{conn: conn, user: user} do
      ctx = issued_group(user)

      conn = get(conn, ~p"/api/sessions/#{ctx.session.id}/share/bills")
      body = json_response(conn, 200)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [other, _host_bill] = body["bills"]

      assert %{"wa_number" => "6281234567890", "has_phone" => true, "amount_due" => 30_000} =
               other

      assert other["text"] =~ "Rp30.000"
      assert other["text"] =~ "https://petepete.test/pay/#{ctx.bill.pay_token}"
      assert other["pay_url"] == "https://petepete.test/pay/#{ctx.bill.pay_token}"
    end

    test "reminder lists the unpaid", %{conn: conn, user: user} do
      ctx = issued_group(user)

      body = conn |> get(~p"/api/sessions/#{ctx.session.id}/share/reminder") |> json_response(200)

      assert %{"count" => 1, "group_text" => text} = body
      assert text =~ "Rp30.000" and text =~ ctx.bill.pay_token
    end

    test "a draft session is 409", %{conn: conn, user: user} do
      group = group_fixture()
      member_fixture(group, "host", user)
      session = session_fixture(group)

      for action <- ~w(bills reminder summary) do
        assert conn
               |> get("/api/sessions/#{session.id}/share/#{action}")
               |> json_response(409) == %{"error" => "session_not_issued"}
      end
    end

    test "a plain member gets 403 and an anonymous caller 401" do
      ctx = issued_group(user_fixture())
      {member_conn, member_user} = bearer_login(build_conn())
      member_fixture(ctx.group, "member", member_user)

      for action <- ~w(bills reminder) do
        path = "/api/sessions/#{ctx.session.id}/share/#{action}"

        assert member_conn |> get(path) |> json_response(403) == %{"error" => "forbidden"}
        assert build_conn() |> get(path) |> json_response(401)
      end
    end

    test "the host of group B gets 404 on group A's session", %{conn: conn, user: user} do
      a = issued_group(user_fixture())
      _b = issued_group(user)

      for action <- ~w(bills reminder summary) do
        assert conn
               |> get("/api/sessions/#{a.session.id}/share/#{action}")
               |> json_response(404) == %{"error" => "not_found"}
      end
    end
  end

  describe "GET /api/sessions/:id/share/summary" do
    test "any member of the group reads it, without tokens or phones", %{conn: conn, user: user} do
      ctx = issued_group(user_fixture())
      member_fixture(ctx.group, "member", user)

      conn = get(conn, ~p"/api/sessions/#{ctx.session.id}/share/summary")
      body = json_response(conn, 200)

      assert body["text"] =~ "Total biaya: Rp60.000"
      assert body["text"] =~ "(Belum bayar)"
      assert body["text"] =~ "(Lunas)"
      assert body["paid_count"] == 1 and body["unpaid_count"] == 1
      refute conn.resp_body =~ ctx.bill.pay_token
      refute conn.resp_body =~ "6281234567890"
    end

    test "a stranger gets 404", %{conn: conn} do
      ctx = issued_group(user_fixture())

      assert conn
             |> get(~p"/api/sessions/#{ctx.session.id}/share/summary")
             |> json_response(404)
    end
  end
end
