defmodule PetepeteWeb.FallbackController do
  @moduledoc """
  Renders command errors as JSON: 404 `not_found` (`invite_not_found` for a dead invite link), 403 `forbidden`, 409 with the code of a
  `{:conflict, code}`, 409 `session_not_editable` (with the session `status`) and 422
  `invalid` with per-field messages under both `errors` and `fields`. Every error carries
  an Indonesian `message` from the one table below (ADR-0004: the server owns text); an
  unknown code raises, so a new code cannot ship without text.
  """
  use PetepeteWeb, :controller

  alias PetepeteWeb.FieldErrors

  @messages %{
    "not_found" => "Data nggak ditemukan.",
    "invite_not_found" => "Link undangan ini sudah tidak berlaku. Minta link baru ke host.",
    "forbidden" => "Kamu nggak punya akses untuk aksi ini.",
    "not_claimable" => "Nama ini nggak bisa diklaim.",
    "already_member" => "Kamu sudah jadi anggota grup ini.",
    "claim_pending" => "Klaim kamu masih menunggu persetujuan host.",
    "no_claim" => "Nggak ada klaim yang menunggu keputusan.",
    "session_not_issued" => "Sesi ini belum ditagih.",
    "session_not_editable" =>
      "Sesi ini sudah ditagih, jadi nggak bisa diubah lagi. Muat ulang dulu ya.",
    "invalid" => "Ada isian yang belum benar. Cek lagi ya.",
    "invalid_event" => "Ada isian acara yang belum benar. Cek lagi ya.",
    "unauthenticated" => "Sesi login habis. Masuk lagi ya.",
    "invalid_phone" => "Nomor HP nggak valid.",
    "rate_limited" => "Terlalu sering minta kode. Tunggu sebentar lalu coba lagi.",
    "delivery_failed" => "Kode gagal dikirim. Coba lagi sebentar lagi.",
    "invalid_code" => "Kode salah atau sudah kedaluwarsa.",
    "invalid_token" => "Sesi login nggak valid. Masuk lagi ya.",
    "invalid_display_name" => "Nama nggak boleh kosong.",
    "still_host" => "Kamu masih jadi host di grup. Serahkan atau hapus grupnya dulu.",
    "invalid_signature" => "Tanda tangan webhook nggak valid.",
    "malformed_payload" => "Isi webhook nggak bisa dibaca.",
    "processing_failed" => "Webhook gagal diproses."
  }

  @doc "Every error code this controller can render (the keys of the message table)."
  @spec codes() :: [String.t()]
  def codes, do: @messages |> Map.keys() |> Enum.sort()

  @doc "The Indonesian text of error `code`; an unknown code raises."
  @spec message(String.t()) :: String.t()
  def message(code), do: Map.fetch!(@messages, code)

  def call(conn, {:error, :not_found}), do: respond(conn, 404, "not_found")
  def call(conn, {:error, :forbidden}), do: respond(conn, 403, "forbidden")

  def call(conn, {:error, {:conflict, code}}), do: respond(conn, 409, Atom.to_string(code))

  def call(conn, {:error, {:session_not_editable, status}}) do
    respond(conn, 409, "session_not_editable", %{
      status: status,
      status_label: PetepeteWeb.Labels.session(status)
    })
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors = FieldErrors.changeset_errors(changeset)
    respond(conn, 422, "invalid", %{errors: errors, fields: errors})
  end

  @doc """
  Sends `{error, message, ...extra}` with `status`; the message comes from the table.
  """
  def respond(conn, status, error, extra \\ %{}) do
    body = Map.merge(extra, %{error: error, message: message(error)})
    conn |> put_status(status) |> json(body)
  end
end
