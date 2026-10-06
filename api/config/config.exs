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

# Configure the endpoint
config :petepete, PetepeteWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PetepeteWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Petepete.PubSub,
  live_view: [signing_salt: "ZQyN0U8m"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Sentry: DSN comes from SENTRY_DSN in config/runtime.exs; without it nothing is sent.
# Every event carries the layer tag; Petepete.ErrorReporting masks phone numbers.
config :sentry,
  tags: %{layer: "api"},
  before_send: {Petepete.ErrorReporting, :before_send}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
