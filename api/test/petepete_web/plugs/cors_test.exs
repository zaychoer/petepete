defmodule PetepeteWeb.Plugs.CORSTest do
  use PetepeteWeb.ConnCase, async: true

  @web "https://petepete.test"

  test "answers the web app's preflight without reaching the router", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", @web)
      |> put_req_header("access-control-request-method", "POST")
      |> options(~p"/api/pay/abc/payment")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == [@web]
    assert [methods] = get_resp_header(conn, "access-control-allow-methods")
    assert methods =~ "POST"
    assert get_resp_header(conn, "access-control-allow-credentials") == []
  end

  test "marks responses to the web origin as readable by it", %{conn: conn} do
    conn = conn |> put_req_header("origin", @web) |> get(~p"/api/pay/unknown-token")

    assert json_response(conn, 404)["error"] == "not_found"
    assert get_resp_header(conn, "access-control-allow-origin") == [@web]
  end

  test "gives other origins no CORS headers", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://evil.example")
      |> put_req_header("access-control-request-method", "POST")
      |> options(~p"/api/pay/abc/payment")

    assert get_resp_header(conn, "access-control-allow-origin") == []
    refute conn.status == 204
  end
end
