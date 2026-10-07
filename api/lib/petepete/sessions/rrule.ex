defmodule Petepete.Sessions.RRule do
  @moduledoc """
  The weekly recurrence subset Petepete needs, in RFC 5545 `RRULE` syntax.

  Supported: `FREQ=WEEKLY`, `BYDAY` as a list of `MO,TU,WE,TH,FR,SA,SU`, and the time of
  day as `BYHOUR` + `BYMINUTE`. The time of day is wall-clock time in WIB (UTC+7, no
  daylight saving), the zone every group plays in. Anything else (`INTERVAL`, `COUNT`,
  `UNTIL`, `BYMONTHDAY`, other frequencies, …) is rejected with a message naming it,
  because silently ignoring it would generate sessions on the wrong days.

      iex> {:ok, rule} = Petepete.Sessions.RRule.parse("FREQ=WEEKLY;BYDAY=TH,MO;BYHOUR=19;BYMINUTE=30")
      iex> Petepete.Sessions.RRule.to_string(rule)
      "FREQ=WEEKLY;BYDAY=MO,TH;BYHOUR=19;BYMINUTE=30"

  A rule parsed without `BYHOUR`/`BYMINUTE` has no time of day yet; `put_time/2` adds one.
  Only a rule with a time of day can produce occurrences.
  """

  alias Petepete.Wib

  @days ~w(MO TU WE TH FR SA SU)
  @day_numbers @days |> Enum.with_index(1) |> Map.new()
  @weekdays_by_number Map.new(@day_numbers, fn {code, n} -> {n, code} end)

  @enforce_keys [:days]
  defstruct [:days, :time]

  @type t :: %__MODULE__{days: [1..7], time: Time.t() | nil}

  @supported_help "only FREQ=WEEKLY;BYDAY=<MO,TU,WE,TH,FR,SA,SU list> with a time of day is supported"

  @doc """
  Parses a rule. `days` come back sorted Monday (1) to Sunday (7) without duplicates.
  Returns `{:error, message}` for anything outside the supported subset.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(rrule) when is_binary(rrule) do
    with {:ok, parts} <- split(rrule),
         :ok <- check_unsupported(parts),
         :ok <- check_freq(parts),
         {:ok, days} <- parse_days(parts),
         {:ok, time} <- parse_time(parts) do
      {:ok, %__MODULE__{days: days, time: time}}
    end
  end

  def parse(_), do: {:error, "must be a string like FREQ=WEEKLY;BYDAY=TH"}

  defp split(rrule) do
    parts =
      rrule
      |> String.trim()
      |> String.split(";", trim: true)
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {key |> String.trim() |> String.upcase(), String.trim(value)}
          [key] -> {String.upcase(String.trim(key)), nil}
        end
      end)

    keys = Enum.map(parts, &elem(&1, 0))

    cond do
      parts == [] ->
        {:error, "is empty; " <> @supported_help}

      Enum.any?(parts, fn {_, value} -> value in [nil, ""] end) ->
        {:error, "has a part without a value"}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, "repeats a part"}

      true ->
        {:ok, Map.new(parts)}
    end
  end

  defp check_unsupported(parts) do
    case Map.keys(parts) -- ~w(FREQ BYDAY BYHOUR BYMINUTE) do
      [] ->
        :ok

      unsupported ->
        {:error,
         "#{Enum.join(Enum.sort(unsupported), ", ")} is not supported; " <> @supported_help}
    end
  end

  defp check_freq(%{"FREQ" => freq}) do
    if String.upcase(freq) == "WEEKLY",
      do: :ok,
      else: {:error, "FREQ=#{freq} is not supported; " <> @supported_help}
  end

  defp check_freq(_), do: {:error, "needs FREQ=WEEKLY; " <> @supported_help}

  defp parse_days(%{"BYDAY" => value}) do
    codes = value |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.upcase()))

    case Enum.reject(codes, &Map.has_key?(@day_numbers, &1)) do
      [] ->
        {:ok, codes |> Enum.map(&Map.fetch!(@day_numbers, &1)) |> Enum.uniq() |> Enum.sort()}

      bad ->
        {:error, "BYDAY has unknown day #{Enum.join(bad, ", ")}; use #{Enum.join(@days, ",")}"}
    end
  end

  defp parse_days(_), do: {:error, "needs BYDAY; " <> @supported_help}

  defp parse_time(parts) do
    case {Map.fetch(parts, "BYHOUR"), Map.fetch(parts, "BYMINUTE")} do
      {:error, :error} ->
        {:ok, nil}

      {{:ok, hour}, minute} ->
        with {:ok, h} <- int_in(hour, "BYHOUR", 0..23),
             {:ok, m} <- int_in(minute_value(minute), "BYMINUTE", 0..59) do
          {:ok, Time.new!(h, m, 0)}
        end

      {:error, {:ok, _}} ->
        {:error, "BYMINUTE needs BYHOUR"}
    end
  end

  defp minute_value({:ok, minute}), do: minute
  defp minute_value(:error), do: "0"

  defp int_in(value, name, range) do
    case Integer.parse(value) do
      {n, ""} ->
        if n in range,
          do: {:ok, n},
          else: {:error, "#{name} must be #{range.first}..#{range.last}"}

      _ ->
        {:error, "#{name} must be a whole number"}
    end
  end

  @doc """
  Adds a wall-clock WIB time of day given as `"HH:MM"` to a rule that has none. Returns an
  error message for a malformed time or when the rule already carries one.
  """
  @spec put_time(t(), term()) :: {:ok, t()} | {:error, String.t()}
  def put_time(%__MODULE__{time: nil} = rule, time) when is_binary(time) do
    case Regex.run(~r/\A(\d{1,2}):(\d{2})\z/, String.trim(time), capture: :all_but_first) do
      [h, m] ->
        case Time.new(String.to_integer(h), String.to_integer(m), 0) do
          {:ok, parsed} -> {:ok, %{rule | time: parsed}}
          {:error, _} -> {:error, "time must be HH:MM between 00:00 and 23:59"}
        end

      _ ->
        {:error, "time must be HH:MM between 00:00 and 23:59"}
    end
  end

  def put_time(%__MODULE__{time: %Time{}}, _time),
    do: {:error, "time conflicts with BYHOUR/BYMINUTE in the rrule; give the time once"}

  def put_time(%__MODULE__{}, _time), do: {:error, "time must be HH:MM between 00:00 and 23:59"}

  @doc "The canonical text of a rule (`FREQ=WEEKLY;BYDAY=MO,TH;BYHOUR=19;BYMINUTE=0`)."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{days: days, time: time}) do
    base = "FREQ=WEEKLY;BYDAY=" <> Enum.map_join(days, ",", &Map.fetch!(@weekdays_by_number, &1))

    case time do
      nil -> base
      %Time{hour: h, minute: m} -> base <> ";BYHOUR=#{h};BYMINUTE=#{m}"
    end
  end

  @doc """
  The UTC start of the occurrence on `date` (a WIB calendar date), or `nil` when the rule
  has no occurrence that day. Needs a rule with a time of day.
  """
  @spec occurrence_on(t(), Date.t()) :: DateTime.t() | nil
  def occurrence_on(%__MODULE__{days: days, time: %Time{} = time}, %Date{} = date) do
    if Date.day_of_week(date) in days, do: Wib.to_utc(date, time)
  end
end
