defmodule Petepete.Ledger.Event do
  @moduledoc """
  The closed set of money events `Petepete.Ledger.record/2` accepts, one struct per kind.

  Every event carries `:group_id` and a mandatory `:idempotency_key` (non-blank string,
  globally unique). See `Petepete.Ledger` for the exact fields, entries and rules.
  """

  @typedoc "Any of the eight money event structs."
  @type t ::
          __MODULE__.SessionBilled.t()
          | __MODULE__.GatewayPaymentReceived.t()
          | __MODULE__.CashReceived.t()
          | __MODULE__.Settlement.t()
          | __MODULE__.KasSpend.t()
          | __MODULE__.SessionBillsCancelled.t()
          | __MODULE__.CashPaymentCancelled.t()
          | __MODULE__.Correction.t()
end
