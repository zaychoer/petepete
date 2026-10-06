defmodule Petepete.Ledger.Event.SessionBilled do
  @moduledoc "A session's bills were issued. Kind `session_billed`."
  @enforce_keys [:idempotency_key, :group_id, :session_id, :shares, :kas_remainder]
  defstruct [:idempotency_key, :group_id, :session_id, :shares, :kas_remainder, fronted: []]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          group_id: pos_integer(),
          session_id: pos_integer(),
          shares: [{member_id :: pos_integer(), share :: pos_integer()}],
          fronted: [{member_id :: pos_integer(), amount :: pos_integer()}],
          kas_remainder: non_neg_integer()
        }
end
