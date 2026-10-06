defmodule PetepeteWeb.Labels do
  @moduledoc """
  The one source of Indonesian status text on the wire (ADR-0004). Every payload that
  carries a status-like field also carries `status_label` from here; clients choose only
  icon and tone. An unknown status raises, so a new status cannot ship without text.
  """

  @bill %{
    "unpaid" => "Belum bayar",
    "paid" => "Lunas",
    "needs_review" => "Perlu dicek",
    "void" => "Dibatalkan"
  }

  # The pay page's sentence under the chip; an unpaid bill has none.
  @bill_message %{
    "paid" => "Tagihan ini sudah lunas. Makasih ya!",
    "needs_review" => "Pembayaranmu lagi dicek host. Tunggu sebentar ya.",
    "void" => "Tagihan dibatalkan"
  }

  @payment_method %{"qris" => "QRIS", "va" => "Virtual Account", "ewallet" => "E-wallet"}

  # Session progress (stored draft | issued | cancelled, plus derived settled).
  @session %{
    "draft" => "Draft",
    "issued" => "Ditagih",
    "settled" => "Selesai",
    "cancelled" => "Batal"
  }

  @withdrawal %{
    "pending" => "Penarikan lagi diproses",
    "failed" => "Penarikan gagal. Coba lagi.",
    "submitted" => "Penarikan diajukan",
    "managed" => "Selesaikan di dashboard gateway"
  }

  @payout_account %{
    "pending_kyc" => "Menunggu verifikasi (KYC)",
    "active" => "Aktif"
  }

  @paid_via %{"cash" => "Cash", "gateway" => "Online", "credit" => "Saldo"}

  @role %{"host" => "Host", "member" => "Anggota", "guest" => "Tamu"}

  # The eight ledger money events (`Petepete.Ledger.Txn.kind`).
  @txn_kind %{
    "session_billed" => "Tagihan sesi",
    "gateway_payment_received" => "Bayar online",
    "cash_received" => "Bayar tunai",
    "settlement" => "Pelunasan",
    "kas_spend" => "Belanja kas",
    "session_bills_cancelled" => "Tagihan dibatalkan",
    "cash_payment_cancelled" => "Tunai dibatalkan",
    "correction" => "Koreksi"
  }

  @doc "Label for how a bill was paid (`cash | gateway | credit`); `nil` (unpaid) has none."
  @spec paid_via(String.t() | nil) :: String.t() | nil
  def paid_via(nil), do: nil
  def paid_via(via), do: Map.fetch!(@paid_via, via)

  @doc "Label for a bill status (`unpaid | paid | needs_review | void`)."
  @spec bill(String.t()) :: String.t()
  def bill(status), do: Map.fetch!(@bill, status)

  @doc "The pay page's message for a bill status, `nil` when there is none (unpaid)."
  @spec bill_message(String.t()) :: String.t() | nil
  def bill_message(status), do: Map.get(@bill_message, status)

  @doc "Label for a payment method (`qris | va | ewallet`)."
  @spec payment_method(String.t()) :: String.t()
  def payment_method(method), do: Map.fetch!(@payment_method, method)

  @doc "Label for a session status or progress (string or atom)."
  @spec session(String.t() | atom()) :: String.t()
  def session(status), do: Map.fetch!(@session, to_string(status))

  @doc "Label for a withdrawal status."
  @spec withdrawal(String.t()) :: String.t()
  def withdrawal(status), do: Map.fetch!(@withdrawal, status)

  @doc "Label for a payout account status."
  @spec payout_account(String.t()) :: String.t()
  def payout_account(status), do: Map.fetch!(@payout_account, status)

  @doc "Label for a roster role."
  @spec role(String.t()) :: String.t()
  def role(role), do: Map.fetch!(@role, role)

  @doc "Label for a ledger txn kind; an unknown kind raises."
  @spec txn_kind(String.t()) :: String.t()
  def txn_kind(kind), do: Map.fetch!(@txn_kind, kind)
end
