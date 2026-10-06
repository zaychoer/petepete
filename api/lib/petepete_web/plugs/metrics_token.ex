defmodule PetepeteWeb.Plugs.MetricsToken do
  @moduledoc """
  Guards the admin metrics endpoint with the shared secret `METRICS_TOKEN`
  (`config :petepete, :metrics_token`), sent as `authorization: Bearer <secret>`.

  With no secret configured the endpoint does not exist: 404 `not_found`. A missing or wrong
  secret is 401 `unauthenticated` (both through `PetepeteWeb.FallbackController`). The comparison is
  constant-time: both sides are hashed to the same length before `Plug.Crypto.secure_compare/2`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Application.get_env(:petepete, :metrics_token) do
      secret when is_binary(secret) and secret != "" -> authenticate(conn, secret)
      _ -> reject(conn, 404, "not_found")
    end
  end

  defp authenticate(conn, secret) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(digest(token), digest(secret)) do
      conn
    else
      _ -> reject(conn, 401, "unauthenticated")
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp reject(conn, status, code),
    do: conn |> PetepeteWeb.FallbackController.respond(status, code) |> halt()
end
