defmodule Petepete.Payments.Gateway.FeeTable do
  @moduledoc """
  Gateway fees from a config table, shared by adapters.

  A table maps a method to `%{flat: rupiah, bps: basis_points}`: the provider keeps
  `flat + ceil(gross * bps / 10_000)` of every transaction, PPN already included in
  both numbers. All arithmetic is integer.
  """

  @type entry :: %{flat: non_neg_integer(), bps: 0..9_999}
  @type t :: %{String.t() => entry()}

  @doc """
  The fee to charge on top of `amount_due` so that `gross - provider_fee(gross) == amount_due`.

  The result is exact: `h(g) = g - ceil(g * bps / 10_000)` rises by 0 or 1 per rupiah,
  so the smallest gross with `h(g) >= amount_due + flat` hits it exactly.
  """
  @spec fee_for(t(), String.t(), integer()) ::
          {:ok, non_neg_integer()} | {:error, :unsupported_method | :invalid_amount}
  def fee_for(table, method, amount_due) when is_integer(amount_due) and amount_due > 0 do
    with {:ok, %{flat: flat, bps: bps}} <- fetch(table, method) do
      gross = ceil_div((amount_due + flat) * 10_000, 10_000 - bps)
      {:ok, gross - amount_due}
    end
  end

  def fee_for(_table, _method, _amount_due), do: {:error, :invalid_amount}

  @doc "What the provider keeps from a `gross` payment by `method`."
  @spec provider_fee(t(), String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :unsupported_method}
  def provider_fee(table, method, gross) do
    with {:ok, %{flat: flat, bps: bps}} <- fetch(table, method) do
      {:ok, flat + ceil_div(gross * bps, 10_000)}
    end
  end

  defp fetch(table, method) do
    case table do
      %{^method => entry} -> {:ok, entry}
      _ -> {:error, :unsupported_method}
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
