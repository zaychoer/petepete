defmodule PetepeteWeb.Router do
  use PetepeteWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", PetepeteWeb do
    pipe_through :api
  end
end
