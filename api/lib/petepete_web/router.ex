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

    post "/members/:id/claim", MemberController, :claim
    post "/members/:id/claim/approve", MemberController, :approve
    post "/members/:id/claim/reject", MemberController, :reject
  end
end
