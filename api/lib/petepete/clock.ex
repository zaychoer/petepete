defmodule Petepete.Clock do
  @moduledoc """
  The current time, with a per-process override so tests can move time.

  Production code asks `now/0` instead of `DateTime.utc_now/0` where tests need to
  cross a deadline (OTP validity, token expiry). The override lives in the calling
  process, so async tests do not affect each other; HTTP tests run the request in
  the test process.
  """

  @key {__MODULE__, :now}

  @doc "Current UTC time truncated to the second."
  @spec now() :: DateTime.t()
  def now do
    case Process.get(@key) do
      nil -> DateTime.utc_now(:second)
      %DateTime{} = frozen -> frozen
    end
  end

  @doc "Freezes `now/0` in the calling process at `datetime`."
  @spec freeze(DateTime.t()) :: :ok
  def freeze(%DateTime{} = datetime) do
    Process.put(@key, DateTime.truncate(datetime, :second))
    :ok
  end

  @doc "Moves the frozen clock of the calling process forward by `seconds`."
  @spec advance(integer()) :: :ok
  def advance(seconds) when is_integer(seconds) do
    now() |> DateTime.add(seconds, :second) |> freeze()
  end
end
