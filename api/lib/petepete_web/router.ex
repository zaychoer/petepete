defmodule PetepeteWeb.Router do
  use PetepeteWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Fly health check (fly.*.toml); excluded from force_ssl in config/prod.exs.
  scope "/", PetepeteWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api", PetepeteWeb do
    pipe_through :api
  end
end
