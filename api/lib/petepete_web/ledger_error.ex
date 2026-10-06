defmodule PetepeteWeb.LedgerError do
  @moduledoc """
  Renders a Ledger error atom as HTTP 422 `{"error": code, "message": indonesian_text}`.

  Codes are the atom names, stable for clients. Also used for request-shape errors
  (`:invalid_params`) so every rejected money request answers in one format.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @messages %{
    idempotency_key_required: "Header Idempotency-Key wajib diisi.",
    idempotency_key_conflict: "Idempotency-Key ini sudah dipakai untuk permintaan yang berbeda.",
    invalid_params: "Data yang dikirim belum lengkap atau salah format.",
    invalid_actor: "Pelaku tidak diizinkan untuk aksi ini.",
    amount_not_positive: "Nominal harus lebih dari Rp0.",
    insufficient_balance: "Saldo sub-account tidak cukup untuk penarikan ini.",
    payout_account_not_active: "Rekening pencairan belum aktif. Selesaikan verifikasi dulu.",
    group_not_found: "Grup tidak ditemukan.",
    member_not_in_group: "Anggota itu bukan bagian dari grup ini.",
    same_member: "Pembayar dan penerima tidak boleh orang yang sama.",
    insufficient_kas: "Saldo kas tidak cukup untuk belanja ini.",
    reason_required: "Alasan wajib diisi.",
    txn_not_found: "Catatan tidak ditemukan.",
    not_undoable:
      "Catatan ini tidak bisa dikoreksi. Hanya pelunasan antar anggota dan belanja kas yang bisa dikoreksi.",
    already_reversed: "Catatan ini sudah pernah dikoreksi.",
    undo_window_expired: "Batas waktu pembatalan sudah lewat.",
    invalid_time: "Waktu tidak valid.",
    no_payout_account: "Grup belum punya rekening pencairan."
  }

  @doc "Sends the 422 response and returns the conn."
  @spec render(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def render(conn, reason) when is_atom(reason) do
    message = Map.get(@messages, reason, "Permintaan ditolak.")

    conn
    |> put_status(422)
    |> json(%{error: Atom.to_string(reason), message: message})
  end

  @doc "422 `invalid_params` with per-field `details`."
  @spec render_invalid(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def render_invalid(conn, details) do
    conn
    |> put_status(422)
    |> json(%{
      error: "invalid_params",
      message: Map.fetch!(@messages, :invalid_params),
      details: details
    })
  end
end
