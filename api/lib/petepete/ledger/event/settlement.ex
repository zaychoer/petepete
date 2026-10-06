defmodule Petepete.Ledger.Event.Settlement do
  @moduledoc "One member paid another back. Kind `settlement`."
  @enforce_keys [:idempotency_key, :group_id, :payer_member_id, :payee_member_id, :amount]
  defstruct [
    :idempotency_key,
    :group_id,
    :payer_member_id,
    :payee_member_id,
    :amount,
    :note
  ]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          group_id: pos_integer(),
          payer_member_id: pos_integer(),
          payee_member_id: pos_integer(),
          amount: pos_integer(),
          note: String.t() | nil
        }
end
