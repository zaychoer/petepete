defmodule Petepete.FakeGateway do
  @moduledoc """
  Test control of `Petepete.Payments.Gateway.Fake`, whose behaviour is application config.

  `configure/1` merges options into the Fake's config and restores it when the test exits,
  so a test using it must not be `async`. `notify: self()` makes the Fake message the test
  for every call that reaches the provider (see the Fake's moduledoc).
  """

  alias Petepete.Payments.Gateway.Fake

  @doc "Merges `overrides` into the Fake's config for the rest of the test."
  @spec configure(keyword()) :: :ok
  def configure(overrides) do
    original = Application.fetch_env!(:petepete, Fake)
    Application.put_env(:petepete, Fake, Keyword.merge(original, overrides))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:petepete, Fake, original) end)
  end
end
