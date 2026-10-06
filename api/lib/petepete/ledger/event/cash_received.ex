defmodule Petepete.Ledger.Event.CashReceived do
  @moduledoc "The host marked a bill paid in cash. Kind `cash_received`."
  @enforce_keys [:idempotency_key, :group_id, :bill_id, :member_id, :amount, :at]
  defstruct [:idempotency_key, :group_id, :bill_id, :member_id, :amount, :at]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          group_id: pos_integer(),
          bill_id: pos_integer(),
          member_id: pos_integer(),
          amount: pos_integer(),
          at: DateTime.t()
        }
end
