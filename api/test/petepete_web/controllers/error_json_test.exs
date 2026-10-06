defmodule PetepeteWeb.ErrorJSONTest do
  use PetepeteWeb.ConnCase, async: true

  alias Petepete.Contract
  alias PetepeteWeb.ErrorJSON

  test "an unknown route answers the contract's not_found", %{conn: conn} do
    conn = get(conn, "/api/no/such/route")

    assert %{"error" => "not_found"} = json_response(conn, 404)
    Contract.check!("errors/not_found", conn)
  end

  test "a malformed JSON body answers bad_request", %{conn: conn} do
    {400, _headers, body} =
      assert_error_sent(400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/otp", "{not json")
      end)

    assert %{"error" => "bad_request"} = decoded = Jason.decode!(body)
    Contract.check!("errors/bad_request", decoded)
  end

  test "a crash renders server_error, never Phoenix's default body" do
    body = "500.json" |> ErrorJSON.render(%{}) |> Jason.encode!() |> Jason.decode!()

    assert %{"error" => "server_error", "message" => message} = body
    assert message =~ "server"
    Contract.check!("errors/server_error", body)
  end

  test "any other status renders without raising" do
    assert %{error: "bad_request"} = ErrorJSON.render("415.json", %{})
    assert %{error: "server_error"} = ErrorJSON.render("503.json", %{})
    assert %{error: "server_error"} = ErrorJSON.render("weird.json", %{})
  end
end
