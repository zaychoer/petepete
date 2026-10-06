defmodule PetepeteWeb.Router do
  use PetepeteWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Protected routes: `pipe_through [:api, :authenticated]` (assigns `current_scope`).
  pipeline :authenticated do
    plug PetepeteWeb.Plugs.Authenticate
  end

  # Routes that work with or without a login (`current_scope` is nil when anonymous).
  pipeline :optionally_authenticated do
    plug PetepeteWeb.Plugs.OptionalAuthenticate
  end

  scope "/api", PetepeteWeb do
    pipe_through :api

    post "/auth/otp", AuthController, :otp
    post "/auth/verify", AuthController, :verify
    post "/auth/refresh", AuthController, :refresh
    post "/auth/logout", AuthController, :logout
  end

  scope "/api", PetepeteWeb do
    pipe_through [:api, :optionally_authenticated]

    post "/invites/:token/join", InviteController, :join
  end

  scope "/api", PetepeteWeb do
    pipe_through [:api, :authenticated]

    get "/groups", GroupController, :index
    post "/groups", GroupController, :create
    get "/groups/:group_id", GroupController, :show
    post "/groups/:group_id/invite/reset", GroupController, :reset_invite
    post "/groups/:group_id/guests", GroupController, :add_guest
    post "/groups/:group_id/events", EventController, :create
    get "/groups/:group_id/home", HomeController, :show

    post "/members/:id/claim", MemberController, :claim
    post "/members/:id/claim/approve", MemberController, :approve
    post "/members/:id/claim/reject", MemberController, :reject

    post "/groups/:group_id/payout-account", PayoutAccountController, :create
    post "/groups/:group_id/settlements", LedgerController, :settlement
    post "/groups/:group_id/kas-spends", LedgerController, :kas_spend
    get "/groups/:group_id/balances", LedgerController, :balances
    get "/groups/:group_id/txns", LedgerController, :txns
    post "/txns/:id/correction", LedgerController, :correction

    get "/sessions/:id", SessionController, :show
    put "/sessions/:id/costs/:cid", SessionController, :put_cost
    delete "/sessions/:id/costs/:cid", SessionController, :delete_cost
    put "/sessions/:id/attendance", SessionController, :put_attendance
    get "/sessions/:id/preview", SessionBillingController, :preview
    post "/sessions/:id/issue", SessionBillingController, :issue

    get "/me", MeController, :show
    patch "/me", MeController, :update
    delete "/me", MeController, :delete
  end
end
