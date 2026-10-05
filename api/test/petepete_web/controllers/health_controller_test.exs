defmodule PetepeteWeb.HealthControllerTest do
  use PetepeteWeb.ConnCase, async: true

  test "GET /health", %{conn: conn} do
    assert conn |> get(~p"/health") |> json_response(200) == %{"status" => "ok"}
  end
end
