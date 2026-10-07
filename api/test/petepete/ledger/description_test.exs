defmodule Petepete.Ledger.DescriptionTest do
  use ExUnit.Case, async: true

  alias Petepete.Ledger.{Description, Entry, Txn}

  # The cases are shared with the Dart and TypeScript suites: contract/rupiah.json.
  @rupiah_file Path.expand("../../../../contract/rupiah.json", __DIR__)
  @external_resource @rupiah_file

  for %{"amount" => amount, "text" => text} <- @rupiah_file |> File.read!() |> Jason.decode!() do
    test "rupiah(#{amount}) is #{text}" do
      assert Description.rupiah(unquote(amount)) == unquote(text)
    end
  end

  test "cash and gateway payments read as '<name> bayar <amount>'" do
    names = %{1 => "Andi", 2 => "Host"}

    entries = [
      %Entry{account_type: "member", member_id: 1, amount: 45_000},
      %Entry{account_type: "member", member_id: 2, amount: -45_000}
    ]

    assert Description.of(%Txn{kind: "cash_received", entries: entries}, names) ==
             "Andi bayar Rp45.000 (tunai)"

    assert Description.of(%Txn{kind: "gateway_payment_received", entries: entries}, names) ==
             "Andi bayar Rp45.000 (online)"
  end

  test "kas spend with and without a note" do
    names = %{1 => "Andi"}

    entries = [
      %Entry{account_type: "kas", amount: -50_000},
      %Entry{account_type: "member", member_id: 1, amount: 50_000}
    ]

    assert Description.of(%Txn{kind: "kas_spend", reason: "bola", entries: entries}, names) ==
             "Andi beli bola Rp50.000 pakai kas"

    assert Description.of(%Txn{kind: "kas_spend", entries: entries}, names) ==
             "Andi belanja Rp50.000 pakai kas"
  end

  test "a correction names what it undid" do
    names = %{1 => "Andi", 2 => "Budi"}

    pay = [
      %Entry{account_type: "member", member_id: 1, amount: 5_000},
      %Entry{account_type: "member", member_id: 2, amount: -5_000}
    ]

    original = %Txn{id: 7, kind: "settlement", entries: pay}
    correction = %Txn{id: 8, kind: "correction", reverses_txn_id: 7, reason: "salah", entries: []}

    assert Description.of(correction, names, [original, correction]) ==
             "Dikoreksi: Andi bayar Rp5.000 ke Budi. Alasan: salah"
  end
end
