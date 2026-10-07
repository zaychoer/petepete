defmodule PetepeteWeb.Plugs.CORS do
  @moduledoc """
  Lets the web app (pay page, join page) call the API from the browser.

  Only the origin of `:web_base_url` is allowed: a request whose `origin` header is exactly
  that origin gets `access-control-allow-origin`; any other origin gets no CORS headers, so
  the browser blocks it. The API is bearer-token based and sets no cookies, so credentials
  are never allowed. Preflight (`OPTIONS`) is answered here with 204 and never reaches the
  router.
  """
  @behaviour Plug

  import Plug.Conn

  @allow_methods "GET, POST, PATCH, PUT, DELETE, OPTIONS"
  @allow_headers "content-type, authorization, idempotency-key"
  @max_age "600"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = put_resp_header(conn, "vary", "origin")

    if allowed?(get_req_header(conn, "origin")) do
      conn
      |> put_resp_header("access-control-allow-origin", allowed_origin())
      |> preflight()
    else
      conn
    end
  end

  defp preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> put_resp_header("access-control-allow-methods", @allow_methods)
    |> put_resp_header("access-control-allow-headers", @allow_headers)
    |> put_resp_header("access-control-max-age", @max_age)
    |> send_resp(204, "")
    |> halt()
  end

  defp preflight(conn), do: conn

  defp allowed?([origin]), do: origin == allowed_origin()
  defp allowed?(_), do: false

  defp allowed_origin do
    uri = :petepete |> Application.fetch_env!(:web_base_url) |> URI.parse()
    port = if uri.port == URI.default_port(uri.scheme), do: "", else: ":#{uri.port}"
    "#{uri.scheme}://#{uri.host}#{port}"
  end
end
