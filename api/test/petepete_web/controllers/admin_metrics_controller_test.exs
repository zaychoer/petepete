defmodule PetepeteWeb.AdminMetricsControllerTest do
  # Sets application env (the METRICS_TOKEN secret), which is global.
  use PetepeteWeb.ConnCase, async: false

  @secret "s3cret-metrics-token-for-tests"

  defp with_secret(secret) do
    previous = Application.get_env(:petepete, :metrics_token)
    Application.put_env(:petepete, :metrics_token, secret)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:petepete, :metrics_token, previous),
        else: Application.delete_env(:petepete, :metrics_token)
    end)
  end

  defp get_metrics(conn, token) do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, ~p"/api/admin/metrics")
  end

  describe "without METRICS_TOKEN" do
    for secret <- [nil, ""] do
      test "is 404 even with a bearer token (secret #{inspect(secret)})", %{conn: conn} do
        with_secret(unquote(secret))
        assert %{"error" => "not_found"} = conn |> get_metrics("anything") |> json_response(404)
      end
    end
  end

  describe "with METRICS_TOKEN" do
    setup do
      with_secret(@secret)
    end

    test "401 without or with a wrong token", %{conn: conn} do
      for token <- [nil, "wrong", @secret <> "x", String.slice(@secret, 0..-2//1), ""] do
        assert %{"error" => "unauthenticated"} = conn |> get_metrics(token) |> json_response(401)
      end
    end

    test "401 for a non-bearer authorization header", %{conn: conn} do
      conn = put_req_header(conn, "authorization", @secret)
      assert json_response(get(conn, ~p"/api/admin/metrics"), 401)
    end

    test "200 with the aggregates for the right token", %{conn: conn} do
      body = conn |> get_metrics(@secret) |> json_response(200)

      assert %{
               "from" => _,
               "to" => _,
               "totals" => %{
                 "sessions_billed" => 0,
                 "bills_sent" => 0,
                 "build_duration_ms" => %{"median" => nil, "p90" => nil},
                 "time_to_paid_ms" => %{"median" => nil, "p90" => nil},
                 "paid_without_install_pct" => nil
               },
               "days" => days
             } = body

      assert length(days) == 30
    end
  end
end
