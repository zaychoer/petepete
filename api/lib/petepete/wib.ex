defmodule Petepete.Wib do
  @moduledoc """
  WIB (Waktu Indonesia Barat), UTC+7 all year, the wall-clock zone of every group.

  Fixed offset arithmetic: Indonesia has no daylight saving, so no timezone database is
  needed. Times are stored and compared in UTC; this module maps them to and from WIB
  calendar dates and times of day.
  """

  @offset_seconds 7 * 3600

  @doc "The WIB calendar date of a UTC instant."
  @spec date(DateTime.t()) :: Date.t()
  def date(%DateTime{} = utc) do
    utc |> DateTime.add(@offset_seconds, :second) |> DateTime.to_date()
  end

  @doc "The UTC instant of a WIB `date` at WIB wall-clock `time` (midnight by default)."
  @spec to_utc(Date.t(), Time.t()) :: DateTime.t()
  def to_utc(%Date{} = date, %Time{} = time \\ ~T[00:00:00]) do
    date
    |> NaiveDateTime.new!(time)
    |> NaiveDateTime.add(-@offset_seconds, :second)
    |> DateTime.from_naive!("Etc/UTC")
  end
end
