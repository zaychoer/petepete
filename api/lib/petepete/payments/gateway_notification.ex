defmodule Petepete.Payments.GatewayNotification do
  @moduledoc "One gateway notification, deduplicated by `(provider, provider_txn_id, provider_status)`."
  use Ecto.Schema

  schema "gateway_notifications" do
    field :provider, :string
    field :provider_txn_id, :string
    field :provider_status, :string
    field :payload, :map
    field :outcome, :string
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
