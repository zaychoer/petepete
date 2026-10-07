defmodule PetepeteWeb.WebhookController do
  @moduledoc """
  `POST /api/webhooks/:provider`: the gateway's payment notifications (spec "Alur webhook").

  No login: the request is authentic only if the gateway adapter verifies it against the
  raw body (`PetepeteWeb.Plugs.RawBody`). Answers 200 (processed, or already processed),
  401 (bad signature), 400 (verified but unreadable payload), 404 (a provider that is not
  the configured one) and 500 (any failure, so the gateway sends it again and the
  notification is processed from the start). The flow lives in `Petepete.Payments.Webhook`.
  """
  use PetepeteWeb, :controller

  alias Petepete.Payments.Webhook
  alias PetepeteWeb.FallbackController
  alias PetepeteWeb.Plugs.RawBody

  def create(conn, %{"provider" => provider}) do
    headers = conn.req_headers
    payload = conn.body_params

    case Webhook.handle(provider, headers, RawBody.raw_body(conn), payload) do
      {:ok, outcome} -> json(conn, %{outcome: outcome})
      {:error, :unknown_provider} -> FallbackController.call(conn, {:error, :not_found})
      {:error, :invalid_signature} -> FallbackController.respond(conn, 401, "invalid_signature")
      {:error, :malformed_payload} -> FallbackController.respond(conn, 400, "malformed_payload")
      {:error, :processing_failed} -> FallbackController.respond(conn, 500, "processing_failed")
    end
  end
end
