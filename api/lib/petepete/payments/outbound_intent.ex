defmodule Petepete.Payments.OutboundIntent do
  @moduledoc """
  Behaviour for outbound gateway intent kinds.

  Each kind (payment attempt, withdrawal, payout registration) implements these
  callbacks so `IntentRunner` and `IntentReconciler` can drive them uniformly.
  The intent state lives on the domain row itself (no separate outbox table).
  """

  @doc "Machine name: `\"payment_attempt\"`, `\"withdrawal\"`, `\"payout_registration\"`."
  @callback kind() :: String.t()

  @doc """
  Inside a `Repo.transaction`. Creates or finds the intent row (status pending/registering).
  Returns the row and the stable reference the gateway will receive.

  A replay (same idempotency key, same args) returns `{:ok, row, ref}` where the
  row may already be settled; the runner skips the gateway call in that case.
  """
  @callback prepare(args :: map()) ::
              {:ok, row :: struct(), reference :: String.t()} | {:error, term()}

  @doc """
  Outside any transaction. Calls the gateway with the given reference.
  Must be safe to retry with the same reference (idempotent at the provider).
  """
  @callback request(row :: struct(), reference :: String.t()) ::
              {:ok, result :: map()} | {:error, term()}

  @doc """
  Inside a `Repo.transaction`. Writes the outcome on the row
  (status submitted/active/failed/needs_review).
  """
  @callback settle(row :: struct(), result :: {:ok, map()} | {:error, term()}) ::
              {:ok, settled :: struct()} | {:error, term()}

  @doc """
  Returns intent rows still pending/registering older than the given threshold.
  """
  @callback stuck(threshold :: DateTime.t()) :: [struct()]

  @doc """
  Decides what the reconciler does with a stuck row.

  - `:redrive` — call the gateway again (up to max retries, then `:fail`).
  - `:fail` — mark the row failed immediately.
  - `:needs_review` — mark needs_review and alert.
  """
  @callback recover(row :: struct()) :: :redrive | :fail | :needs_review
end
