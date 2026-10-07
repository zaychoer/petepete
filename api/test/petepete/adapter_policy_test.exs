defmodule Petepete.AdapterPolicyTest do
  # Reads config/runtime.exs for MIX_ENV=prod with a fabricated environment, so the boot
  # rules are the real ones. Not async: it changes the OS environment.
  use ExUnit.Case, async: false

  defmodule RealSender do
    @moduledoc false
    @behaviour Petepete.Accounts.OtpSender

    @impl true
    def deliver(_phone, _code), do: :ok
  end

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @base_env %{
    "DATABASE_URL" => "ecto://u:p@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "OTP_HMAC_KEY" => String.duplicate("k", 40),
    "WEB_BASE_URL" => "https://web.example.test",
    "PAYMENT_GATEWAY" => "fake",
    "OTP_SENDER" => "Elixir.Petepete.Accounts.OtpSender.Fake",
    "ALLOW_FAKE_ADAPTERS" => "true"
  }

  @keys Map.keys(@base_env)

  setup do
    saved = Map.new(@keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- saved,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end)

    :ok
  end

  defp boot(overrides \\ %{}) do
    env = Map.merge(@base_env, overrides)

    for key <- @keys do
      case env do
        %{^key => nil} -> System.delete_env(key)
        %{^key => value} -> System.put_env(key, value)
        _ -> System.delete_env(key)
      end
    end

    Config.Reader.read!(@runtime, env: :prod)
  end

  defp petepete(config), do: Keyword.fetch!(config, :petepete)

  test "staging boots with both fakes when ALLOW_FAKE_ADAPTERS=true" do
    petepete = boot() |> petepete()

    assert petepete[:gateway] == Petepete.Payments.Gateway.Fake
    assert petepete[Petepete.Accounts][:otp_sender] == Petepete.Accounts.OtpSender.Fake
  end

  test "production refuses either fake without the explicit flag" do
    for flag <- [nil, "false", "1", "yes"] do
      assert_raise RuntimeError, ~r/OTP_SENDER.*fake sender.*ALLOW_FAKE_ADAPTERS/, fn ->
        boot(%{"ALLOW_FAKE_ADAPTERS" => flag})
      end

      assert_raise RuntimeError, ~r/PAYMENT_GATEWAY.*fake gateway.*ALLOW_FAKE_ADAPTERS/, fn ->
        boot(%{
          "ALLOW_FAKE_ADAPTERS" => flag,
          "OTP_SENDER" => inspect(RealSender) |> then(&("Elixir." <> &1))
        })
      end
    end
  end

  test "a real sender module that implements the behaviour boots" do
    sender = "Elixir." <> inspect(RealSender)

    # The only gateway that exists is the fake, so the flag stays on for it.
    petepete = boot(%{"OTP_SENDER" => sender}) |> petepete()
    assert petepete[Petepete.Accounts][:otp_sender] == RealSender
  end

  test "OTP_SENDER must be set, loadable and an OtpSender" do
    assert_raise RuntimeError, ~r/OTP_SENDER is missing/, fn -> boot(%{"OTP_SENDER" => nil}) end
    assert_raise RuntimeError, ~r/OTP_SENDER is missing/, fn -> boot(%{"OTP_SENDER" => ""}) end

    assert_raise RuntimeError, ~r/not a module of this release/, fn ->
      boot(%{"OTP_SENDER" => "Elixir.Petepete.Accounts.OtpSender.Typo"})
    end

    assert_raise RuntimeError, ~r/does not implement/, fn ->
      boot(%{"OTP_SENDER" => "Elixir.Enum"})
    end
  end

  test "PAYMENT_GATEWAY must be set and on the allowlist" do
    assert_raise RuntimeError, ~r/PAYMENT_GATEWAY is missing/, fn ->
      boot(%{"PAYMENT_GATEWAY" => nil})
    end

    assert_raise RuntimeError, ~r/not a known adapter/, fn ->
      boot(%{"PAYMENT_GATEWAY" => "xendit"})
    end
  end
end
