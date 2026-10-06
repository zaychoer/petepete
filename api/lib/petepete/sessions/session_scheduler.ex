defmodule Petepete.Sessions.SessionScheduler do
  @moduledoc """
  Oban cron job that creates the draft sessions of recurring events 3 days ahead.

  Scheduled daily at 17:05 UTC, which is 00:05 WIB (see the crontab in `config/config.exs`;
  Oban cron expressions are UTC). The work is `Petepete.Sessions.generate_upcoming/1`,
  idempotent, so a retry or a second run the same day creates nothing new. A run in which
  any session could not be created returns an error so Oban retries it.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Petepete.{Clock, Sessions}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Sessions.generate_upcoming(Clock.now()) do
      %{failed: 0} = result ->
        Logger.info("session scheduler: #{result.created} created, #{result.existing} existing")
        :ok

      %{failed: failed} = result ->
        Logger.error("session scheduler: #{failed} failed, #{result.created} created")
        {:error, "#{failed} sessions could not be created"}
    end
  end
end
