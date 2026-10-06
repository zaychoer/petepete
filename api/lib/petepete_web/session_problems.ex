defmodule PetepeteWeb.SessionProblems do
  @moduledoc """
  The one source of Indonesian text for the `problems` of a 422 `invalid_session` (what
  `Petepete.Billing.Calculation` finds wrong with a session that cannot be billed), keyed by
  problem code. A problem about a cost item or a participant has the item's name (label, else
  category) or the member's display name interpolated; the clients show `message` as is
  (ADR-0004). An unknown code raises, so a new problem cannot ship without text.
  """

  alias Petepete.Billing

  @doc "Every problem code that has text."
  @spec codes() :: [String.t()]
  def codes,
    do:
      ~w(invalid_amount invalid_rounding_unit invalid_weight item_without_bearers item_without_payer total_cost_not_positive)

  @doc """
  The wire problems (`%{code, id, message}`) of Calculation `errors` for `session_id`;
  `id` is the cost item (or, for `invalid_weight`, the member) the problem is about, else `nil`.
  """
  @spec render([atom() | {atom(), pos_integer()}], pos_integer()) :: [map()]
  def render(errors, session_id) do
    names = %{
      items: Map.new(Billing.list_cost_items(session_id), &{&1.id, item_name(&1)}),
      members:
        Map.new(Billing.list_participants(session_id), &{&1.member_id, &1.member.display_name})
    }

    Enum.map(errors, fn
      {code, id} -> problem(code, id, names)
      code -> problem(code, nil, names)
    end)
  end

  defp problem(code, id, names) do
    %{code: Atom.to_string(code), id: id, message: message(code, name(code, id, names))}
  end

  defp name(:invalid_weight, id, names), do: Map.get(names.members, id, "peserta")
  defp name(_code, nil, _names), do: nil
  defp name(_code, id, names), do: Map.get(names.items, id, "pos biaya")

  defp item_name(%{label: label}) when is_binary(label) and label != "", do: label
  defp item_name(%{category: category}), do: category

  defp message(:item_without_bearers, name),
    do:
      ~s(Pos "#{name}" belum ada peserta hadir yang menanggung. Centang kehadiran atau ubah "Hanya untuk…".)

  defp message(:item_without_payer, name),
    do: ~s(Pos "#{name}" belum ada yang menalangi. Pilih penalangnya.)

  defp message(:invalid_amount, name), do: ~s(Nominal pos "#{name}" harus lebih dari Rp0.)

  defp message(:invalid_weight, name),
    do: "Bobot #{name} nggak valid. Bobot harus lebih dari 0."

  defp message(:invalid_rounding_unit, _),
    do: "Pembulatan sesi ini nggak valid. Hubungi tim Petepete."

  defp message(:total_cost_not_positive, _),
    do: "Total biaya harus lebih dari Rp0. Tambah pos biaya dulu."
end
