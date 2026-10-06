defmodule PetepeteWeb.LedgerError do
  @moduledoc """
  Renders a Ledger error atom as HTTP 422 `{"error": code, "message": indonesian_text}`.
  Also the one place that renders the payment gateway's 502 `gateway_error`, shared by the
  pay link, withdrawals and payout account.

  Codes are the atom names, stable for clients. Also used for request-shape errors
  (`:invalid_params`) so every rejected money request answers in one format.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @gateway_error_message "Gateway sedang bermasalah. Coba lagi nanti."

  @messages %{
    idempotency_key_required: "Header Idempotency-Key wajib diisi.",
    idempotency_key_conflict:
      "Permintaan ini bentrok dengan catatan sebelumnya. Muat ulang lalu coba lagi.",
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
    undo_window_expired:
      "Batas waktu pembatalan 24 jam sudah lewat, jadi catatan ini tidak bisa dibatalkan atau dikoreksi lagi.",
    invalid_time: "Waktu tidak valid.",
    no_payout_account: "Grup belum punya rekening pencairan.",
    unknown_event: "Jenis catatan ini tidak dikenal.",
    duplicate_member: "Satu anggota tidak boleh muncul dua kali di pembagian.",
    empty_shares: "Pembagian belum punya peserta.",
    negative_remainder: "Sisa kas tidak boleh negatif.",
    unbalanced_shares: "Total pembagian tidak cocok dengan biaya."
  }

  @doc "Sends the 422 response and returns the conn."
  @spec render(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def render(conn, reason) when is_atom(reason) do
    message = Map.get(@messages, reason, "Permintaan ditolak.")

    conn
    |> put_status(422)
    |> json(%{error: Atom.to_string(reason), message: message})
  end

  @doc "502 `gateway_error`: the payment gateway refused or was unreachable."
  @spec render_gateway_error(Plug.Conn.t()) :: Plug.Conn.t()
  def render_gateway_error(conn) do
    conn
    |> put_status(502)
    |> json(%{error: "gateway_error", message: @gateway_error_message})
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
