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

  @role %{"host" => "Host", "member" => "Anggota", "guest" => "Tamu"}

  @doc "Label for a bill status (`unpaid | paid | needs_review | void`)."
  @spec bill(String.t()) :: String.t()
  def bill(status), do: Map.fetch!(@bill, status)

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
end
