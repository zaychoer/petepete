defmodule PetepeteWeb.Router do
  use PetepeteWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Protected routes: `pipe_through [:api, :authenticated]` (assigns `current_scope`).
  pipeline :authenticated do
    plug PetepeteWeb.Plugs.Authenticate
  end

  scope "/api", PetepeteWeb do
    pipe_through :api

    post "/auth/otp", AuthController, :otp
    post "/auth/verify", AuthController, :verify
    post "/auth/refresh", AuthController, :refresh
    post "/auth/logout", AuthController, :logout
  end

  scope "/api", PetepeteWeb do
    pipe_through [:api, :authenticated]

    post "/groups/:group_id/payout-account", PayoutAccountController, :create
    post "/groups/:group_id/settlements", LedgerController, :settlement
    post "/groups/:group_id/kas-spends", LedgerController, :kas_spend
    get "/groups/:group_id/balances", LedgerController, :balances
    get "/groups/:group_id/txns", LedgerController, :txns
    post "/txns/:id/correction", LedgerController, :correction
  end
end
