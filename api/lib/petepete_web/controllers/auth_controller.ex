defmodule PetepeteWeb.AuthController do
  @moduledoc "OTP login, token refresh and logout. No endpoint here needs a bearer token."
  use PetepeteWeb, :controller

  alias Petepete.Accounts

  def otp(conn, %{"phone" => phone}) do
    case Accounts.request_otp(phone, client_ip(conn)) do
      :ok -> json(conn, %{ok: true})
      {:error, reason} -> error(conn, reason)
    end
  end

  def otp(conn, _params), do: error(conn, :invalid_phone)

  def verify(conn, %{"phone" => phone, "code" => code}) do
    case Accounts.verify_otp(phone, code) do
      {:ok, user, tokens, new_user?} ->
        json(conn, %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_type: "Bearer",
          expires_in: tokens.expires_in,
          new_user: new_user?,
          user: %{id: user.id, display_name: user.display_name}
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def verify(conn, _params), do: error(conn, :invalid_code)

  def refresh(conn, %{"refresh_token" => token}) do
    case Accounts.refresh(token) do
      {:ok, tokens} ->
        json(conn, %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_type: "Bearer",
          expires_in: tokens.expires_in
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def refresh(conn, _params), do: error(conn, :invalid_token)

  def logout(conn, params) do
    :ok = Accounts.logout(params["refresh_token"])
    json(conn, %{ok: true})
  end

  defp error(conn, reason) do
    {status, code} =
      case reason do
        :invalid_phone -> {422, "invalid_phone"}
        :rate_limited -> {429, "rate_limited"}
        :delivery_failed -> {502, "delivery_failed"}
        :invalid_code -> {401, "invalid_code"}
        :invalid_token -> {401, "invalid_token"}
      end

    conn |> put_status(status) |> json(%{error: code})
  end

  # Behind Fly's proxy the socket peer is the proxy; the real client is in the
  # header named by `:client_ip_header` (set in prod only, never trusted elsewhere).
  defp client_ip(conn) do
    header = Application.get_env(:petepete, :client_ip_header)

    with header when is_binary(header) <- header,
         [value | _] <- get_req_header(conn, header),
         {:ok, ip} <- value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      ip |> :inet.ntoa() |> to_string()
    else
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
