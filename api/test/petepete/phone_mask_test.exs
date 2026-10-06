defmodule Petepete.PhoneMaskTest do
  use ExUnit.Case, async: true

  alias Petepete.PhoneMask

  describe "mask/1" do
    test "masks 08, 62 and +62 numbers inside text" do
      assert PhoneMask.mask("hubungi 081234567890 atau 6281234567890 atau +6281234567890 ya") ==
               "hubungi [PHONE] atau [PHONE] atau [PHONE] ya"
    end

    test "masks numbers with spaces, dots and dashes" do
      assert PhoneMask.mask("+62 812-3456-7890") == "[PHONE]"
      assert PhoneMask.mask("0812.3456.7890") == "[PHONE]"
      assert PhoneMask.mask("nomor: 0812 3456 7890!") == "nomor: [PHONE]!"
    end

    test "masks URL-encoded and query-string numbers" do
      assert PhoneMask.mask("phone=%2B6281234567890&x=1") == "phone=[PHONE]&x=1"

      assert PhoneMask.mask("https://wa.me/6281234567890?text=hi") ==
               "https://wa.me/[PHONE]?text=hi"
    end

    test "leaves rupiah amounts, dates, ids and short numbers alone" do
      text =
        "Rp45.000 total 150000 pada 2026-10-06 08:15:30 id 62 request F8a0812345678901Zx 0812"

      assert PhoneMask.mask(text) == text
    end

    test "leaves long digit strings and numbers glued to words alone" do
      assert PhoneMask.mask("08123456789012345678") == "08123456789012345678"
      assert PhoneMask.mask("token_081234567890") == "token_081234567890"
    end
  end

  describe "scrub/1" do
    test "masks strings and string keys through maps, lists, tuples, keyword lists and structs" do
      input = %{
        "phone" => "081234567890",
        "081234567890" => ["ok", {:error, "gagal kirim ke +6281234567890"}],
        reason: [to: "6281234567890", id: 7],
        at: ~U[2026-10-06 08:00:00Z],
        error: %RuntimeError{message: "otp ke 081234567890 gagal"}
      }

      assert PhoneMask.scrub(input) == %{
               "phone" => "[PHONE]",
               "[PHONE]" => ["ok", {:error, "gagal kirim ke [PHONE]"}],
               reason: [to: "[PHONE]", id: 7],
               at: ~U[2026-10-06 08:00:00Z],
               error: %RuntimeError{message: "otp ke [PHONE] gagal"}
             }
    end

    test "returns pids, atoms and numbers untouched" do
      term = {self(), :atom, 42, 1.5}
      assert PhoneMask.scrub(term) == term
    end
  end
end
