defmodule Petepete.Repo do
  use Ecto.Repo,
    otp_app: :petepete,
    adapter: Ecto.Adapters.Postgres
end
