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
end
