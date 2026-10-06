defmodule Petepete.Ledger.Event.KasSpend do
  @moduledoc "A member bought something for the group out of the kas. Kind `kas_spend`."
  @enforce_keys [:idempotency_key, :group_id, :member_id, :amount]
  defstruct [:idempotency_key, :group_id, :member_id, :amount, :note]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          group_id: pos_integer(),
          member_id: pos_integer(),
          amount: pos_integer(),
          note: String.t() | nil
        }
end
