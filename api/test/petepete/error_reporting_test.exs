defmodule Petepete.ErrorReportingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  require Logger

  @phone "081234567890"

  defp reported_event(opts) do
    event = Sentry.Event.create_event(opts)
    callback = Application.fetch_env!(:sentry, :before_send)
    {module, function} = callback
    apply(module, function, [event])
  end

  test "an event for a failing request carries the api layer tag and no phone numbers" do
    Sentry.Context.add_breadcrumb(message: "OTP dikirim ke #{@phone}")
    Sentry.Context.set_extra_context(%{recipient: "+6281234567890"})

    _conn =
      conn(:post, "/api/auth/otp?phone=%2B6281234567890", %{
        "phone" => @phone,
        "password" => "rahasia"
      })
      |> Plug.Parsers.call(
        Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)
      )
      |> Sentry.PlugContext.call(
        Sentry.PlugContext.init(body_scrubber: {Petepete.ErrorReporting, :scrub_body})
      )

    event =
      reported_event(
        exception: %RuntimeError{message: "gagal kirim OTP ke #{@phone}"},
        stacktrace: [],
        request: %{}
      )

    assert event.tags[:layer] == "api"

    payload = inspect(event, limit: :infinity, printable_limit: :infinity)
    refute payload =~ "1234567890"
    refute payload =~ "rahasia"
    assert payload =~ "[PHONE]"
  end

  describe "log filter" do
    test "keeps phone numbers out of log output, in messages and metadata" do
      log =
        capture_log([metadata: [:recipient]], fn ->
          Logger.metadata(recipient: "6281234567890")
          Logger.warning("OTP gagal untuk #{@phone}")
          Logger.warning(fn -> ["kirim ke ", "+62 812-3456-7890"] end)
          Logger.warning(%{reason: "nomor #{@phone} tidak aktif"})
        end)

      refute log =~ "1234567890"
      refute log =~ "812-3456-7890"
      assert log =~ "OTP gagal untuk [PHONE]"
      assert log =~ "kirim ke [PHONE]"
      assert log =~ "recipient=[PHONE]"
    end

    test "keeps phone numbers out of format-style log events" do
      log =
        capture_log(fn ->
          :logger.warning(~c"nomor ~ts tidak aktif", [@phone])
        end)

      assert log =~ "nomor [PHONE] tidak aktif"
      refute log =~ @phone
    end
  end
end
