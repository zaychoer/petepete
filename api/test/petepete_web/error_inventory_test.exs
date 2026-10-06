defmodule PetepeteWeb.ErrorInventoryTest do
  @moduledoc """
  Every error `code` the API can render is either in the wire contract (`errors/<code>` in
  `contract/manifest.json`, with a message) or on the explicit list below of codes no client
  can receive. The produced codes come from the single tables that render them:

    * `PetepeteWeb.FallbackController` (also used by the `Authenticate`, `MetricsToken` and
      access plugs and the webhook, auth, me and event controllers)
    * `PetepeteWeb.LedgerError` (also the `IdempotencyKey` plug and the money controllers)
    * `PetepeteWeb.BillingError`, `PetepeteWeb.PayController`,
      `PetepeteWeb.SessionBillingController` (codes they render themselves)
    * `PetepeteWeb.ErrorJSON` (Phoenix's own 4xx/5xx bodies)

  A source scan fails when `lib/petepete_web` renders a code literal that is in none of those
  tables, so a new inline `error: "..."` cannot hide from this test.
  """
  use ExUnit.Case, async: true

  alias PetepeteWeb.{
    BillingError,
    ErrorJSON,
    FallbackController,
    LedgerError,
    PayController,
    SessionBillingController
  }

  # Codes produced but not receivable by any client, with the reason. Everything else
  # produced must have a sample in the manifest.
  @not_client %{
    # Ledger rejections of events only server code builds (the routes build them from
    # validated input after authorizing, so no request can reach them).
    "invalid_actor" => "host routes authorize the actor before the Ledger sees it",
    "group_not_found" => "GroupAccess answers 404 not_found for an unknown group first",
    "txn_not_found" => "TxnAccess answers 404 not_found for a missing or foreign txn first",
    "invalid_time" => "the Ledger's `at` is set by the server, never by a request",
    "unknown_event" => "only server code builds Ledger events",
    "duplicate_member" => "shares are built by the billing calculation, not sent by a client",
    "empty_shares" => "shares are built by the billing calculation, not sent by a client",
    "negative_remainder" => "the kas remainder is computed by the server",
    "unbalanced_shares" => "shares are built by the billing calculation, not sent by a client",
    # The provider webhook is classified :server_only (no client reads its response).
    "invalid_signature" => "webhook-only: POST /api/webhooks/:provider is :server_only",
    "malformed_payload" => "webhook-only: POST /api/webhooks/:provider is :server_only",
    "processing_failed" => "webhook-only: POST /api/webhooks/:provider is :server_only"
  }

  defp produced do
    Enum.sort(
      Enum.uniq(
        FallbackController.codes() ++
          LedgerError.codes() ++
          BillingError.codes() ++
          PayController.codes() ++
          SessionBillingController.codes() ++
          ErrorJSON.codes()
      )
    )
  end

  defp recorded, do: Petepete.Contract.manifest()["errors"]

  test "every code a client can receive has a sample in the manifest" do
    missing =
      Enum.reject(produced(), &(Map.has_key?(@not_client, &1) or &1 in recorded()))

    assert missing == [],
           """
           Error codes the API renders to clients without an `errors/<code>` sample: #{inspect(missing)}.
           Trigger each through its real route in a controller test and call
           `Contract.check!("errors/<code>", conn)`; if no client can receive it, list it in
           @not_client in #{Path.relative_to_cwd(__ENV__.file)} with the reason.
           """
  end

  test "every manifest error is still produced by a table" do
    stale = recorded() -- produced()

    assert stale == [],
           "Manifest errors no table renders any more (delete the sample and its entry): #{inspect(stale)}"
  end

  test "the not-client list names only produced codes, none of them recorded" do
    stale = Map.keys(@not_client) -- produced()
    assert stale == [], "@not_client lists codes nothing renders: #{inspect(stale)}"

    recorded_anyway = Enum.filter(Map.keys(@not_client), &(&1 in recorded()))

    assert recorded_anyway == [],
           "@not_client lists codes that have a sample, so a client can receive them: #{inspect(recorded_anyway)}"
  end

  test "no controller or plug renders a code that is in none of the tables" do
    root = Path.expand("../../lib/petepete_web", __DIR__)

    literals =
      for file <- Path.wildcard(Path.join(root, "**/*.ex")),
          {code, line} <- code_literals(File.read!(file)) do
        {code, "#{Path.relative_to(file, root)}:#{line}"}
      end

    assert literals != [], "the scan found no code literal at all: the patterns are stale"

    unknown = for {code, where} <- literals, code not in produced(), do: "#{code} (#{where})"
    assert unknown == [], "codes rendered inline that no table lists: #{inspect(unknown)}"
  end

  # `error: "code"`, `{422, "code"}` / `respond(conn, 422, "code")` and
  # `LedgerError.render(conn, :code)`.
  defp code_literals(source) do
    patterns = [
      ~r/error: "([a-z_]+)"/,
      ~r/\b[1-5]\d\d, "([a-z_]+)"/,
      ~r/LedgerError\.render\(conn, :([a-z_]+)\)/
    ]

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      for pattern <- patterns, [_, code] <- Regex.scan(pattern, text), do: {code, line}
    end)
  end
end
