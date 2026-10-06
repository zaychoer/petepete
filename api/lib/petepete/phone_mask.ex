defmodule Petepete.PhoneMask do
  @moduledoc """
  Masks Indonesian phone numbers (`08…`, `62…`, `+62…`) so they never reach logs
  or Sentry.

  `mask/1` works on one string. `scrub/1` walks any term (maps, keyword lists,
  tuples, structs, nested lists) and masks every string, and every string map key,
  it finds. Numbers, atoms, pids and other non-string leaves are returned as is.
  """

  @mask "[PHONE]"

  @doc """
  Replaces every phone number in `string` with `#{@mask}`.

  Recognises the `0`, `62` and `+62` (or URL-encoded `%2B62`) prefixes with optional
  spaces, dots or dashes between digits. A number glued to other word characters
  (a token, a UUID) is left alone.
  """
  @spec mask(String.t()) :: String.t()
  def mask(string) when is_binary(string) do
    Regex.replace(
      ~r/(?<!\w)(?:\+|%2[Bb])?(?:62|0)[\s.\-]?[1-9](?:[\s.\-]?\d){7,12}(?!\d)/u,
      string,
      @mask
    )
  end

  @doc "Masks phone numbers in every string inside `term`. See the module doc."
  @spec scrub(term()) :: term()
  def scrub(term) when is_binary(term), do: mask(term)

  def scrub(%module{} = struct) do
    struct(module, struct |> Map.from_struct() |> scrub())
  end

  def scrub(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {scrub(key), scrub(value)} end)
  end

  def scrub([head | tail]), do: [scrub(head) | scrub(tail)]

  def scrub(term) when is_tuple(term) do
    term |> Tuple.to_list() |> scrub() |> List.to_tuple()
  end

  def scrub(term), do: term
end
