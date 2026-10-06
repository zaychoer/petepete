# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :petepete,
  ecto_repos: [Petepete.Repo],
  generators: [timestamp_type: :utc_datetime]

config :petepete, Oban,
  engine: Oban.Engines.Basic,
  repo: Petepete.Repo,
  queues: [default: 10, payments: 10, notifications: 10]

# Configure the endpoint
config :petepete, PetepeteWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PetepeteWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Petepete.PubSub

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Never log request parameters that identify or authenticate a person.
config :phoenix, :filter_parameters, ["password", "phone", "code", "refresh_token"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
