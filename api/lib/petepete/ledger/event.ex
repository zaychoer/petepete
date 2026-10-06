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

  defmodule SessionBilled do
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

  defmodule GatewayPaymentReceived do
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

  defmodule CashReceived do
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

  defmodule Settlement do
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

  defmodule KasSpend do
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

  defmodule SessionBillsCancelled do
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

  defmodule CashPaymentCancelled do
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

  defmodule Correction do
    @moduledoc "Undoes a `settlement` or `kas_spend` txn. Kind `correction`."
    @enforce_keys [:idempotency_key, :group_id, :txn_id, :reason]
    defstruct [:idempotency_key, :group_id, :txn_id, :reason]

    @type t :: %__MODULE__{
            idempotency_key: String.t(),
            group_id: pos_integer(),
            txn_id: pos_integer(),
            reason: String.t()
          }
  end
end
