defmodule Petepete.Actor do
  @moduledoc """
  Who caused a money event: a **host** or the payment **gateway** (CONTEXT.md, ADR-0003).

  A host Actor proves that the HTTP edge already authorized the caller as host of the
  group in question. Contexts (Billing, Ledger, Payments) take an Actor and never check
  roles again, so the only way production code gets a host Actor is
  `Petepete.Groups.authorize_actor/3`, called by the access plugs
  (`PetepeteWeb.Plugs.GroupAccess`, `SessionAccess`, `BillAccess`, `TxnAccess`) which
  assign it to `conn.assigns.actor`. Do not build `%Petepete.Actor{type: :host}` by hand
  outside tests (`Petepete.Fixtures.host_actor/2`).

  The gateway Actor, `gateway/0`, has no user and no member. It is only accepted for
  `Petepete.Ledger.Event.GatewayPaymentReceived`; the Ledger rejects every other pairing
  with `{:error, :invalid_actor}`. There is no system actor.

    * `type`: `:host` or `:gateway`
    * `user_id`: the host's login (`nil` for the gateway)
    * `member_id`: the host's roster entry in the group they were authorized for (`nil` for
      the gateway)
  """

  @enforce_keys [:type, :user_id, :member_id]
  defstruct [:type, :user_id, :member_id]

  @type t :: %__MODULE__{
          type: :host | :gateway,
          user_id: pos_integer() | nil,
          member_id: pos_integer() | nil
        }

  @doc "The payment gateway as an Actor (no user, no member)."
  @spec gateway() :: t()
  def gateway, do: %__MODULE__{type: :gateway, user_id: nil, member_id: nil}
end
