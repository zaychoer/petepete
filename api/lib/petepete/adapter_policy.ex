defmodule Petepete.AdapterPolicy do
  @moduledoc """
  Which adapters production may boot with; called by `config/runtime.exs`.

  One policy for every seam (`Petepete.Accounts.OtpSender`, `Petepete.Payments.Gateway`):

    * The adapter is named by an environment variable and has no default, so nothing
      is chosen by accident. Missing or blank: the release does not boot.
    * A real adapter is named by a module that can be loaded and implements the seam's
      behaviour. A typo or a module that is not an adapter fails at boot, not at the
      first login or payment.
    * The fake adapters move no money and deliver no code. They are refused unless
      `ALLOW_FAKE_ADAPTERS=true`, which only `fly.staging.toml` sets, never production.

  Every failure raises with a message naming the variable.
  """

  alias Petepete.Accounts.OtpSender
  alias Petepete.Payments.Gateway

  # PAYMENT_GATEWAY is an allowlist of names, not module names.
  @gateways %{"fake" => Gateway.Fake}

  @doc "`ALLOW_FAKE_ADAPTERS` is on only when it is exactly `\"true\"`."
  @spec allow_fake?(String.t() | nil) :: boolean()
  def allow_fake?(value), do: value == "true"

  @doc """
  The OTP sender module for `OTP_SENDER` (a module name such as
  `Elixir.Petepete.Accounts.OtpSender.<Provider>`).
  """
  @spec otp_sender!(String.t() | nil, boolean()) :: module()
  def otp_sender!(name, allow_fake?) when name in [nil, ""] and is_boolean(allow_fake?) do
    raise """
    environment variable OTP_SENDER is missing.
    Set it to the module implementing Petepete.Accounts.OtpSender (see docs/deploy.md).
    """
  end

  def otp_sender!(name, allow_fake?) when is_binary(name) and is_boolean(allow_fake?) do
    module = Module.concat([name])

    cond do
      module == OtpSender.Fake and not allow_fake? ->
        raise "OTP_SENDER=#{name} is the fake sender; it needs ALLOW_FAKE_ADAPTERS=true (staging only)"

      not Code.ensure_loaded?(module) ->
        raise "OTP_SENDER=#{name} is not a module of this release"

      not implements?(module, OtpSender) ->
        raise "OTP_SENDER=#{name} does not implement the Petepete.Accounts.OtpSender behaviour"

      true ->
        module
    end
  end

  @doc "The gateway adapter module for `PAYMENT_GATEWAY` (a name from the allowlist)."
  @spec gateway!(String.t() | nil, boolean()) :: module()
  def gateway!(nil, allow_fake?) when is_boolean(allow_fake?) do
    raise """
    environment variable PAYMENT_GATEWAY is missing.
    Set it to the payment gateway adapter to use (#{Enum.join(Map.keys(@gateways), ", ")}).
    """
  end

  def gateway!(name, allow_fake?) when is_binary(name) and is_boolean(allow_fake?) do
    case @gateways do
      %{^name => Gateway.Fake} when not allow_fake? ->
        raise "PAYMENT_GATEWAY=#{name} is the fake gateway; it needs ALLOW_FAKE_ADAPTERS=true (staging only)"

      %{^name => module} ->
        module

      _ ->
        raise "environment variable PAYMENT_GATEWAY=#{inspect(name)} is not a known adapter"
    end
  end

  defp implements?(module, behaviour) do
    :attributes
    |> module.module_info()
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(behaviour)
  end
end
