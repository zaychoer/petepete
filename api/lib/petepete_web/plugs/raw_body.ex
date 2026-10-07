defmodule PetepeteWeb.Plugs.RawBody do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the exact request bytes of webhook requests
  (`/api/webhooks/...`) in `conn.private[:raw_body]`, because a gateway's signature is
  computed over those bytes, not over the decoded JSON. Every other route reads the body
  as usual and keeps nothing.
  """

  @webhook_path ["api", "webhooks"]

  @doc "Body reader for `Plug.Parsers`; reads the whole body, caching it for webhook paths."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{path_info: [_, _ | _] = path} = conn, opts) do
    if Enum.take(path, 2) == @webhook_path do
      read_and_cache(conn, opts, "")
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp read_and_cache(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        body = acc <> chunk
        {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}

      {:more, chunk, conn} ->
        read_and_cache(conn, opts, acc <> chunk)

      {:error, _} = error ->
        error
    end
  end

  @doc "The raw bytes captured for this request, or `\"\"` when none were."
  @spec raw_body(Plug.Conn.t()) :: binary()
  def raw_body(%Plug.Conn{private: private}), do: Map.get(private, :raw_body, "")
end
