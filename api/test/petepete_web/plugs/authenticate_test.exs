defmodule PetepeteWeb.Plugs.AuthenticateTest do
  use PetepeteWeb.ConnCase, async: true

  alias Petepete.{Clock, Repo}
  alias Petepete.Accounts.{Scope, User}
  alias PetepeteWeb.Plugs.Authenticate

  @t0 ~U[2026-10-06 03:00:00Z]

  setup %{conn: conn} do
    Clock.freeze(@t0)

    phone =
      "628" <>
        (System.unique_integer([:positive])
         |> rem(1_000_000_000)
         |> Integer.to_string()
         |> String.pad_leading(9, "0"))

    post(conn, ~p"/api/auth/otp", %{phone: phone})
    assert_received {:otp_sent, _, code}

    %{"access_token" => access, "refresh_token" => refresh, "user" => %{"id" => user_id}} =
      post(conn, ~p"/api/auth/verify", %{phone: phone, code: code}) |> json_response(200)

    %{conn: conn, access: access, refresh: refresh, user_id: user_id}
  end

  defp call(conn, token) do
    conn |> put_req_header("authorization", "Bearer " <> token) |> Authenticate.call([])
  end

  test "a valid access token assigns the caller's scope", %{
    conn: conn,
    access: access,
    user_id: id
  } do
    conn = call(conn, access)

    refute conn.halted
    assert %Scope{user: %User{id: ^id}} = conn.assigns.current_scope
  end

  test "no header, wrong scheme and garbage are 401", %{conn: conn, access: access} do
    for conn <- [
          conn,
          put_req_header(conn, "authorization", "Basic " <> access),
          put_req_header(conn, "authorization", access),
          put_req_header(conn, "authorization", "Bearer garbage")
        ] do
      conn = Authenticate.call(conn, [])
      assert conn.halted
      assert %{"error" => "unauthenticated"} = json_response(conn, 401)
      refute Map.has_key?(conn.assigns, :current_scope)
    end
  end

  test "a refresh token is not an access token", %{conn: conn, refresh: refresh} do
    assert %{"error" => "unauthenticated"} = json_response(call(conn, refresh), 401)
  end

  test "access tokens expire after 15 minutes; refresh yields a fresh one", ctx do
    Clock.advance(14 * 60)
    refute call(ctx.conn, ctx.access).halted

    Clock.advance(60)
    assert %{"error" => "unauthenticated"} = json_response(call(ctx.conn, ctx.access), 401)

    %{"access_token" => fresh} =
      post(ctx.conn, ~p"/api/auth/refresh", %{refresh_token: ctx.refresh}) |> json_response(200)

    refute call(ctx.conn, fresh).halted
  end

  test "a deleted user is unauthenticated", %{conn: conn, access: access, user_id: id} do
    Repo.get!(User, id) |> Ecto.Changeset.change(deleted_at: Clock.now()) |> Repo.update!()

    assert %{"error" => "unauthenticated"} = json_response(call(conn, access), 401)
  end
end
