defmodule Petepete.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail the boot, not the first login, when no OTP sender is configured.
    Petepete.Accounts.OtpSender.fetch!()

    children = [
      PetepeteWeb.Telemetry,
      Petepete.Repo,
      {Oban, Application.fetch_env!(:petepete, Oban)},
      {DNSCluster, query: Application.get_env(:petepete, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Petepete.PubSub},
      # Start a worker by calling: Petepete.Worker.start_link(arg)
      # {Petepete.Worker, arg},
      # Start to serve requests, typically the last entry
      PetepeteWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Petepete.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PetepeteWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
