defmodule PetepeteWeb.FieldErrorsTest do
  use Petepete.DataCase, async: true

  import Ecto.Changeset

  alias PetepeteWeb.FieldErrors

  describe "message/2" do
    for {kind, opts, text} <- [
          {:required, [], "wajib diisi"},
          {:invalid, [], "tidak valid"},
          {:cast, [type: :integer], "harus angka"},
          {:cast, [type: :string], "tidak valid"},
          {:whole_rupiah, [], "harus angka bulat dalam rupiah"},
          {:format, [], "formatnya belum benar"},
          {:inclusion, [], "pilihannya nggak valid"},
          {:unique, [], "sudah dipakai"},
          {:length, [kind: :max, count: 60, type: :string], "maksimal 60 karakter"},
          {:length, [kind: :min, count: 3, type: :string], "minimal 3 karakter"},
          {:length, [kind: :is, count: 4, type: :string], "harus 4 karakter"},
          {:length, [kind: :max, count: 2, type: :list], "maksimal 2 item"},
          {:number, [kind: :greater_than, number: 0], "harus lebih dari 0"},
          {:number, [kind: :greater_than_or_equal_to, number: 1], "minimal 1"},
          {:number, [kind: :less_than, number: 9], "harus kurang dari 9"},
          {:number, [kind: :less_than_or_equal_to, number: 100], "maksimal 100"},
          {:number, [kind: :equal_to, number: 5], "harus 5"},
          {:number, [kind: :not_equal_to, number: 5], "nggak boleh 5"},
          {:digits_only, [min: 6], "harus angka saja, minimal 6 digit"},
          {:invalid_phone, [], "nomor HP nggak valid"},
          {:not_in_group, [], "harus anggota grup ini"},
          {:members_required, [], "pilih minimal satu anggota untuk biaya sebagian"},
          {:members_not_in_group, [], "semua anggota harus dari grup ini"},
          {:one_off_only, [], "cuma untuk acara sekali jalan; isi rrule dan time"},
          {:recurring_only, [], "cuma untuk acara berulang; isi starts_at"},
          {:starts_at_required, [], "wajib diisi untuk acara sekali jalan"},
          {:starts_at_offset, [], "perlu zona waktu, contoh 2026-10-08T19:00:00+07:00"},
          {:starts_at_format, [],
           "harus tanggal dan jam format ISO 8601, contoh 2026-10-08T19:00:00+07:00"},
          {:time_required, [], "wajib diisi (JJ:MM WIB), atau isi BYHOUR/BYMINUTE di rrule"},
          {:time_format, [], "harus JJ:MM antara 00:00 dan 23:59"},
          {:time_conflict, [], "bentrok dengan BYHOUR/BYMINUTE di rrule; isi jamnya sekali saja"},
          {:rrule_type, [], "harus teks seperti FREQ=WEEKLY;BYDAY=TH"},
          {:rrule_empty, [],
           "kosong; yang didukung cuma FREQ=WEEKLY;BYDAY=<daftar MO,TU,WE,TH,FR,SA,SU> plus jam"},
          {:rrule_part_without_value, [], "ada bagian tanpa nilai"},
          {:rrule_repeated_part, [], "ada bagian yang diulang"},
          {:rrule_unsupported, [parts: ["COUNT", "INTERVAL"]],
           "COUNT, INTERVAL belum didukung; yang didukung cuma FREQ=WEEKLY;BYDAY=<daftar MO,TU,WE,TH,FR,SA,SU> plus jam"},
          {:rrule_freq_unsupported, [freq: "DAILY"],
           "FREQ=DAILY belum didukung; yang didukung cuma FREQ=WEEKLY;BYDAY=<daftar MO,TU,WE,TH,FR,SA,SU> plus jam"},
          {:rrule_freq_required, [],
           "perlu FREQ=WEEKLY; yang didukung cuma FREQ=WEEKLY;BYDAY=<daftar MO,TU,WE,TH,FR,SA,SU> plus jam"},
          {:rrule_day_required, [],
           "perlu BYDAY; yang didukung cuma FREQ=WEEKLY;BYDAY=<daftar MO,TU,WE,TH,FR,SA,SU> plus jam"},
          {:rrule_unknown_day, [days: ["XX"], allowed: ~w(MO TU)],
           "BYDAY berisi hari yang nggak dikenal: XX; pakai MO,TU"},
          {:rrule_minute_needs_hour, [], "BYMINUTE perlu BYHOUR"},
          {:rrule_out_of_range, [name: "BYHOUR", min: 0, max: 23], "BYHOUR harus 0..23"},
          {:rrule_not_whole, [name: "BYHOUR"], "BYHOUR harus angka bulat"},
          {:cost_template_shape, [], "harus berbentuk {\"items\": [{category, amount, …}]}"},
          {:cost_item_not_object, [item: 2], "pos biaya 2: harus berupa objek"},
          {:cost_item_category, [item: 1], "pos biaya 1: kategori wajib diisi"},
          {:cost_item_amount, [item: 1],
           "pos biaya 1: jumlah harus angka bulat rupiah lebih dari 0"},
          {:cost_item_scope, [item: 1], "pos biaya 1: scope harus all atau subset"},
          {:cost_item_label, [item: 1], "pos biaya 1: label harus teks"},
          {:cost_item_paid_by, [item: 1], "pos biaya 1: paid_by_member_id harus id anggota"},
          {:cost_item_member_ids, [item: 1], "pos biaya 1: member_ids harus daftar id anggota"},
          {:cost_item_subset_members, [item: 1], "pos biaya 1: biaya sebagian perlu member_ids"},
          {:cost_template_members_not_in_group, [ids: [3, 9]],
           "anggota bukan dari grup ini: 3, 9"}
        ] do
      test "#{kind} #{inspect(opts)}" do
        assert FieldErrors.message(unquote(kind), unquote(Macro.escape(opts))) ==
                 unquote(text)
      end
    end

    test "an unknown kind raises instead of reaching a client untranslated" do
      assert_raise ArgumentError, ~r/no Indonesian text for validation :brand_new/, fn ->
        FieldErrors.message(:brand_new, [])
      end
    end
  end

  describe "changeset_errors/1" do
    @types %{name: :string, count: :integer, kind: :string, phone: :string}

    test "words Ecto's own validations by kind, per field" do
      errors =
        {%{}, @types}
        |> cast(
          %{"name" => String.duplicate("a", 9), "count" => "x", "kind" => "z"},
          Map.keys(@types)
        )
        |> validate_required([:phone])
        |> validate_length(:name, max: 5)
        |> validate_inclusion(:kind, ["a", "b"])
        |> add_error(:phone, "is invalid", validation: :invalid_phone)
        |> FieldErrors.changeset_errors()

      assert errors == %{
               name: ["maksimal 5 karakter"],
               count: ["harus angka"],
               kind: ["pilihannya nggak valid"],
               phone: ["nomor HP nggak valid", "wajib diisi"]
             }
    end

    test "words a unique constraint by its constraint kind" do
      changeset =
        {%{}, @types}
        |> change()
        |> add_error(:name, "has already been taken", constraint: :unique)

      assert FieldErrors.changeset_errors(changeset) == %{name: ["sudah dipakai"]}
    end

    test "a changeset error of an unknown kind raises" do
      changeset = add_error(change({%{}, @types}), :name, "x", validation: :brand_new)
      assert_raise ArgumentError, fn -> FieldErrors.changeset_errors(changeset) end
    end
  end
end
