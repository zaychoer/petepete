import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/petepete start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :petepete, PetepeteWeb.Endpoint, server: true
end

config :petepete, PetepeteWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Sentry is disabled (dsn nil) when SENTRY_DSN is absent or blank.
# The environment name comes from SENTRY_ENVIRONMENT (set per Fly app).
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry, dsn: if(String.trim(sentry_dsn) == "", do: nil, else: sentry_dsn)
end

if config_env() == :dev do
  config :petepete, PetepeteWeb.Endpoint,
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") ||
        raise(
          "SECRET_KEY_BASE is missing: run bin/dev once, or copy .env.example to .env and fill it in"
        )
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :petepete, Petepete.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # Dev reads it from .env (see above), test uses a fixed value in
  # config/test.exs, and prod gets it from Fly secrets.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Production has no default OTP sender: OTP_SENDER must name an adapter module
  # implementing Petepete.Accounts.OtpSender, otherwise the app fails to boot
  # (Petepete.Accounts.OtpSender.fetch!/0). The dev/test fake is refused.
  otp_sender =
    case System.get_env("OTP_SENDER") do
      nil ->
        nil

      "" ->
        nil

      name ->
        module = Module.concat([name])

        if module == Petepete.Accounts.OtpSender.Fake do
          raise "OTP_SENDER must not be the fake sender in production"
        end

        module
    end

  otp_hmac_key =
    System.get_env("OTP_HMAC_KEY") ||
      raise """
      environment variable OTP_HMAC_KEY is missing.
      It keys the OTP hashes. Generate one with: openssl rand -base64 48
      """

  if byte_size(otp_hmac_key) < 32, do: raise("OTP_HMAC_KEY must be at least 32 bytes")

  config :petepete, Petepete.Accounts, otp_sender: otp_sender, otp_hmac_key: otp_hmac_key

  host = System.get_env("PHX_HOST") || "example.com"

  # No default on purpose: money must never flow through a gateway nobody chose.
  # "fake" is for staging, where no real money moves. See docs/deploy.md, "Gateway adapter".
  gateway =
    case System.get_env("PAYMENT_GATEWAY") do
      "fake" ->
        Petepete.Payments.Gateway.Fake

      nil ->
        raise """
        environment variable PAYMENT_GATEWAY is missing.
        Set it to the payment gateway adapter to use ("fake" while no real adapter exists).
        """

      other ->
        raise "environment variable PAYMENT_GATEWAY=#{inspect(other)} is not a known adapter"
    end

  config :petepete, :gateway, gateway

  config :petepete, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :petepete, PetepeteWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :petepete, PetepeteWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :petepete, PetepeteWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
