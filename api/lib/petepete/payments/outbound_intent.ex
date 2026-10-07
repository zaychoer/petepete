defmodule Petepete.Payments.OutboundIntent do
  @moduledoc """
  Behaviour each outbound gateway call kind implements (ADR-0005).

  Each kind has a domain row (payment attempt, withdrawal, payout account) whose status
  column **is** the durable intent. The callbacks:

    * `prepare/1` – inside a `Repo.transaction`. Creates or finds the intent row.
    * `request/2` – outside any transaction. Calls the gateway.
    * `settle/2` – inside a `Repo.transaction`. Writes the outcome on the row.
    * `stuck/1` – returns rows still pending/registering older than `threshold`.
    * `recover/1` – decides reconciler action for a stuck row.
  """

  @callback kind() :: String.t()

  @callback prepare(args :: map()) ::
              {:ok, row :: struct(), reference :: String.t()} | {:error, term()}

  @callback request(row :: struct(), reference :: String.t()) ::
              {:ok, result :: map()} | {:error, term()}

  @callback settle(row :: struct(), result :: {:ok, map()} | {:error, term()}) ::
              {:ok, settled :: struct()} | {:error, term()}

  @callback stuck(threshold :: DateTime.t()) :: [struct()]

  @callback recover(row :: struct()) :: :redrive | :fail | :needs_review
end
