defmodule Petepete.Ledger.Event.SessionBillsCancelled do
  @moduledoc "Undoes a `session_billed` txn. Kind `session_bills_cancelled`."
  @enforce_keys [:idempotency_key, :group_id, :txn_id, :reason]
  defstruct [:idempotency_key, :group_id, :txn_id, :reason]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          group_id: pos_integer(),
          txn_id: pos_integer(),
          reason: String.t()
        }
end
