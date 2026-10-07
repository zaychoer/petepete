defmodule Petepete.Ledger.Description do
  @moduledoc """
  Casual Indonesian one-liners for the Kas & riwayat screen, e.g. "Andi bayar Rp45.000".
  Produced on the server so every client shows the same text.
  """
  alias Petepete.Ledger.Txn

  @doc "Rupiah with dot thousands separators: `45000` -> `\"Rp45.000\"`."
  @spec rupiah(integer()) :: String.t()
  def rupiah(amount) when amount < 0, do: "-" <> rupiah(-amount)

  def rupiah(amount) when is_integer(amount) do
    digits =
      amount
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(".", &Enum.join/1)
      |> String.reverse()

    "Rp" <> digits
  end

  @doc """
  The text for `txn` (entries loaded). `names` maps member id to display name; `txns` are
  the txns shown alongside, used to name what a correction undid.
  """
  @spec of(Txn.t(), %{integer() => String.t()}, [Txn.t()]) :: String.t()
  def of(%Txn{} = txn, names, txns \\ []) do
    describe(txn, names, Map.new(txns, &{&1.id, &1}))
  end

  defp describe(%Txn{kind: "session_billed"} = t, _names, _) do
    shares = Enum.filter(t.entries, &(&1.account_type == "member" and &1.amount < 0))
    total = shares |> Enum.map(&(-&1.amount)) |> Enum.sum()
    "Tagihan sesi terbit: #{rupiah(total)} untuk #{length(shares)} orang"
  end

  defp describe(%Txn{kind: "gateway_payment_received"} = t, names, _),
    do: "#{payer_name(t, names)} bayar #{rupiah(amount(t))} (online)"

  defp describe(%Txn{kind: "cash_received"} = t, names, _),
    do: "#{payer_name(t, names)} bayar #{rupiah(amount(t))} (tunai)"

  defp describe(%Txn{kind: "settlement"} = t, names, _) do
    {payer, payee} = settlement_parties(t, names)
    "#{payer} bayar #{rupiah(amount(t))} ke #{payee}" <> note(t)
  end

  defp describe(%Txn{kind: "kas_spend"} = t, names, _) do
    who = payer_name(t, names)

    case t.reason do
      nil -> "#{who} belanja #{rupiah(amount(t))} pakai kas"
      note -> "#{who} beli #{note} #{rupiah(amount(t))} pakai kas"
    end
  end

  defp describe(%Txn{kind: "session_bills_cancelled"} = t, _names, _),
    do: "Tagihan sesi dibatalkan. Alasan: #{t.reason}"

  defp describe(%Txn{kind: "cash_payment_cancelled"} = t, names, _),
    do: "Bayar tunai #{payer_name(t, names)} #{rupiah(amount(t))} dibatalkan. Alasan: #{t.reason}"

  defp describe(%Txn{kind: "correction"} = t, names, index) do
    what =
      case Map.get(index, t.reverses_txn_id) do
        nil -> "Catatan sebelumnya"
        original -> describe(original, names, index)
      end

    "Dikoreksi: #{what}. Alasan: #{t.reason}"
  end

  defp amount(%Txn{} = t),
    do: t.entries |> Enum.filter(&(&1.amount > 0)) |> Enum.map(& &1.amount) |> Enum.sum()

  # The member credited by the txn; for mirrored (correction) txns the credit sits on the
  # other side, which is why corrections describe the original instead.
  defp payer_name(%Txn{} = t, names) do
    case Enum.find(t.entries, &(&1.account_type == "member" and &1.amount > 0)) do
      nil -> "Seseorang"
      entry -> Map.get(names, entry.member_id, "Seseorang")
    end
  end

  defp settlement_parties(%Txn{} = t, names) do
    payer = Enum.find(t.entries, &(&1.account_type == "member" and &1.amount > 0))
    payee = Enum.find(t.entries, &(&1.account_type == "member" and &1.amount < 0))
    {Map.get(names, payer.member_id, "Seseorang"), Map.get(names, payee.member_id, "Seseorang")}
  end

  defp note(%Txn{reason: reason}) when reason in [nil, ""], do: ""
  defp note(%Txn{reason: reason}), do: " (#{reason})"
end
