defmodule Petepete.Ledger.Event.GatewayPaymentReceived do
  @moduledoc "A participant paid a bill through the gateway. Kind `gateway_payment_received`."
  @enforce_keys [:idempotency_key, :group_id, :bill_id, :member_id, :amount]
  defstruct [:idempotency_key, :group_id, :bill_id, :member_id, :amount]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          group_id: pos_integer(),
          bill_id: pos_integer(),
          member_id: pos_integer(),
          amount: pos_integer()
        }
end
