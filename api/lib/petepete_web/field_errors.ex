defmodule PetepeteWeb.FieldErrors do
  @moduledoc """
  The one source of Indonesian text for field-level validation messages clients see (the
  `fields` / `errors` of `invalid`, the `details` of `invalid_params` and `invalid_event`).

  A message is chosen by validation *kind*, never by matching English text. Ecto sets the
  kind itself (`validation: :required | :length | :number | ...`, or `constraint: :unique`);
  our own `add_error` calls pass `validation: <kind>` plus the values the text needs.
  `message/2` raises `ArgumentError` for a kind it does not know, so a new validation cannot
  reach a client untranslated.
  """

  @doc "A changeset's errors as `%{field => [Indonesian message]}`."
  @spec changeset_errors(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {_english, opts} -> from_opts(opts) end)
  end

  @doc "The text of one changeset error's `opts` (`validation:` or `constraint:` names the kind)."
  @spec from_opts(keyword()) :: String.t()
  def from_opts(opts) do
    case Keyword.fetch(opts, :validation) do
      {:ok, kind} -> message(kind, opts)
      :error -> message(Keyword.fetch!(opts, :constraint), opts)
    end
  end

  @doc "The Indonesian text for validation `kind`, with the values it names in `opts`."
  @spec message(atom(), keyword()) :: String.t()
  def message(kind, opts \\ [])

  def message(:required, _), do: "wajib diisi"
  def message(:invalid, _), do: "tidak valid"

  def message(:cast, opts),
    do: if(opts[:type] == :integer, do: "harus angka", else: "tidak valid")

  def message(:whole_rupiah, _), do: "harus angka bulat dalam rupiah"
  def message(:format, _), do: "formatnya belum benar"
  def message(:inclusion, _), do: "pilihannya nggak valid"
  def message(:unique, _), do: "sudah dipakai"
  def message(:length, opts), do: length_message(opts[:kind], opts[:count], opts[:type])
  def message(:number, opts), do: number_message(opts[:kind], opts[:number])

  # Our own validations.
  def message(:digits_only, opts),
    do: "harus angka saja, minimal #{Keyword.fetch!(opts, :min)} digit"

  def message(:invalid_phone, _), do: "nomor HP nggak valid"
  def message(:not_in_group, _), do: "harus anggota grup ini"
  def message(:members_required, _), do: "pilih minimal satu anggota untuk biaya sebagian"
  def message(:members_not_in_group, _), do: "semua anggota harus dari grup ini"

  def message(:recurring_only, _), do: "cuma untuk acara berulang; isi starts_at"
  def message(:one_off_only, _), do: "cuma untuk acara sekali jalan; isi rrule dan time"
  def message(:starts_at_required, _), do: "wajib diisi untuk acara sekali jalan"
  def message(:starts_at_offset, _), do: "perlu zona waktu, contoh 2026-10-08T19:00:00+07:00"

  def message(:starts_at_format, _),
    do: "harus tanggal dan jam format ISO 8601, contoh 2026-10-08T19:00:00+07:00"

  def message(:time_required, _), do: "wajib diisi (JJ:MM WIB), atau isi BYHOUR/BYMINUTE di rrule"
  def message(:time_format, _), do: "harus JJ:MM antara 00:00 dan 23:59"

  def message(:time_conflict, _),
    do: "bentrok dengan BYHOUR/BYMINUTE di rrule; isi jamnya sekali saja"

  def message(:rrule_type, _), do: "harus teks seperti FREQ=WEEKLY;BYDAY=TH"
  def message(:rrule_empty, _), do: "kosong; " <> rrule_help()
  def message(:rrule_part_without_value, _), do: "ada bagian tanpa nilai"
  def message(:rrule_repeated_part, _), do: "ada bagian yang diulang"

  def message(:rrule_unsupported, opts),
    do: "#{Enum.join(Keyword.fetch!(opts, :parts), ", ")} belum didukung; " <> rrule_help()

  def message(:rrule_freq_unsupported, opts),
    do: "FREQ=#{Keyword.fetch!(opts, :freq)} belum didukung; " <> rrule_help()

  def message(:rrule_freq_required, _), do: "perlu FREQ=WEEKLY; " <> rrule_help()
  def message(:rrule_day_required, _), do: "perlu BYDAY; " <> rrule_help()

  def message(:rrule_unknown_day, opts),
    do:
      "BYDAY berisi hari yang nggak dikenal: #{Enum.join(Keyword.fetch!(opts, :days), ", ")}; " <>
        "pakai #{Enum.join(Keyword.fetch!(opts, :allowed), ",")}"

  def message(:rrule_minute_needs_hour, _), do: "BYMINUTE perlu BYHOUR"

  def message(:rrule_out_of_range, opts),
    do: "#{opts[:name]} harus #{opts[:min]}..#{opts[:max]}"

  def message(:rrule_not_whole, opts), do: "#{opts[:name]} harus angka bulat"

  def message(:cost_template_shape, _),
    do: "harus berbentuk {\"items\": [{category, amount, …}]}"

  def message(:cost_item_not_object, opts), do: "pos biaya #{opts[:item]}: harus berupa objek"
  def message(:cost_item_category, opts), do: "pos biaya #{opts[:item]}: kategori wajib diisi"

  def message(:cost_item_amount, opts),
    do: "pos biaya #{opts[:item]}: jumlah harus angka bulat rupiah lebih dari 0"

  def message(:cost_item_scope, opts),
    do: "pos biaya #{opts[:item]}: scope harus all atau subset"

  def message(:cost_item_label, opts), do: "pos biaya #{opts[:item]}: label harus teks"

  def message(:cost_item_paid_by, opts),
    do: "pos biaya #{opts[:item]}: paid_by_member_id harus id anggota"

  def message(:cost_item_member_ids, opts),
    do: "pos biaya #{opts[:item]}: member_ids harus daftar id anggota"

  def message(:cost_item_subset_members, opts),
    do: "pos biaya #{opts[:item]}: biaya sebagian perlu member_ids"

  def message(:cost_template_members_not_in_group, opts),
    do: "anggota bukan dari grup ini: #{Enum.join(Keyword.fetch!(opts, :ids), ", ")}"

  def message(kind, _opts),
    do: raise(ArgumentError, "no Indonesian text for validation #{inspect(kind)}")

  defp rrule_help,
    do: "yang didukung cuma FREQ=WEEKLY;BYDAY=<daftar MO,TU,WE,TH,FR,SA,SU> plus jam"

  defp length_message(:max, count, :list), do: "maksimal #{count} item"
  defp length_message(:min, count, :list), do: "minimal #{count} item"
  defp length_message(:is, count, :list), do: "harus #{count} item"
  defp length_message(:max, count, _), do: "maksimal #{count} karakter"
  defp length_message(:min, count, _), do: "minimal #{count} karakter"
  defp length_message(:is, count, _), do: "harus #{count} karakter"

  defp number_message(:greater_than, n), do: "harus lebih dari #{n}"
  defp number_message(:greater_than_or_equal_to, n), do: "minimal #{n}"
  defp number_message(:less_than, n), do: "harus kurang dari #{n}"
  defp number_message(:less_than_or_equal_to, n), do: "maksimal #{n}"
  defp number_message(:equal_to, n), do: "harus #{n}"
  defp number_message(:not_equal_to, n), do: "nggak boleh #{n}"
end
