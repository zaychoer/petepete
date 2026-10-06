import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :petepete, Petepete.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 55432,
  database: "petepete_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :petepete, Oban, testing: :manual

config :petepete, Petepete.Accounts,
  otp_sender: Petepete.Accounts.OtpSender.Fake,
  otp_hmac_key: "test-only-otp-hmac-key-not-a-secret"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :petepete, PetepeteWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "VOdiZndm1qu/Wzsykq0VDNtQukvy1O2KcB/bWzqHSoTcnDD+fZamZOODWH2l8vFG",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
