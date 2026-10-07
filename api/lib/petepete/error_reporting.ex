defmodule Petepete.ErrorReporting do
  @moduledoc """
  Glue between Petepete and Sentry for the API layer.

  Every event, request body, and log line that leaves the node passes through
  `Petepete.PhoneMask`, so no phone number reaches Sentry or the logs.
  Sentry stays off when `SENTRY_DSN` is absent (see `config/runtime.exs`).

    * `before_send/1` is the Sentry `:before_send` callback: it masks the whole event
      (message, exception, request, breadcrumbs, extra, user, tags).
    * `scrub_body/1` is the `Sentry.PlugContext` `:body_scrubber`: Sentry's default
      scrubbing (passwords, card numbers) plus phone masking.
    * `install_logger_handlers/0` masks phone numbers in every log event and routes
      crash reports to Sentry.
  """

  alias Petepete.PhoneMask

  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t()
  def before_send(%Sentry.Event{} = event), do: PhoneMask.scrub(event)

  @spec scrub_body(Plug.Conn.t()) :: map()
  def scrub_body(%Plug.Conn{} = conn) do
    conn |> Sentry.PlugContext.default_body_scrubber() |> PhoneMask.scrub()
  end

  @doc """
  Adds the phone-masking primary filter and the Sentry `:logger` handler.

  The filter is a primary filter, so it runs before every handler, Sentry's included.
  """
  @spec install_logger_handlers() :: :ok
  def install_logger_handlers do
    :ok = :logger.add_primary_filter(:phone_mask, {&phone_mask_filter/2, []})
    :ok = :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{config: %{}})
  end

  @doc false
  @spec phone_mask_filter(:logger.log_event(), term()) :: :logger.log_event()
  def phone_mask_filter(%{msg: msg, meta: meta} = log_event, _extra) do
    %{log_event | msg: mask_msg(msg), meta: PhoneMask.scrub(meta)}
  end

  defp mask_msg({:string, string}) do
    {:string, string |> IO.chardata_to_string() |> PhoneMask.mask()}
  end

  # Keep `{format, args}` and reports in their original shape: Elixir's
  # translators for crash reports match on the format string.
  defp mask_msg({:report, report}), do: {:report, PhoneMask.scrub(report)}
  defp mask_msg({format, args}), do: {format, PhoneMask.scrub(args)}
end
