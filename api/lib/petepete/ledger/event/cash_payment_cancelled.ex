defmodule Petepete.Ledger.Event.CashPaymentCancelled do
  @moduledoc "Undoes a `cash_received` txn within 24h of it. Kind `cash_payment_cancelled`."
  @enforce_keys [:idempotency_key, :group_id, :txn_id, :reason, :at]
  defstruct [:idempotency_key, :group_id, :txn_id, :reason, :at]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          group_id: pos_integer(),
          txn_id: pos_integer(),
          reason: String.t(),
          at: DateTime.t()
        }
end
