defmodule PetepeteWeb.ErrorJSON do
  @moduledoc """
  Renders the errors Phoenix raises itself (an unknown route, a malformed JSON body, a crash)
  in the API's one error format, `{"error": code, "message": indonesian_text}` (ADR-0004),
  instead of Phoenix's default `{"errors": {"detail": ...}}`. Configured as the endpoint's
  `render_errors` JSON view.

    * 404 `not_found` (same text as `FallbackController`)
    * any other 4xx (unparseable body, unsupported media type, payload too large) `bad_request`
    * 5xx `server_error`

  Never raises, whatever the template: an error view that crashes hides the real error.
  """

  alias PetepeteWeb.FallbackController

  @messages %{
    "bad_request" => "Permintaan nggak bisa dibaca. Coba lagi ya.",
    "server_error" => "Ada masalah di server kami. Coba lagi sebentar lagi."
  }

  @doc "Every error code this view can render."
  @spec codes() :: [String.t()]
  def codes, do: ["not_found" | Map.keys(@messages)] |> Enum.sort()

  def render(template, _assigns) do
    code = code(template)
    %{error: code, message: message(code)}
  end

  defp code("404.json"), do: "not_found"

  defp code(template) do
    case Integer.parse(template) do
      {status, ".json"} when status in 400..499 -> "bad_request"
      _ -> "server_error"
    end
  end

  defp message("not_found"), do: FallbackController.message("not_found")
  defp message(code), do: Map.fetch!(@messages, code)
end
