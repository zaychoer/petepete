defmodule PetepeteWeb.PayController do
  @moduledoc """
  The public pay link, addressed by `bills.pay_token` (no login). Responses carry no phone
  numbers and not even the payer's name.

  `GET /api/pay/:token` (PAY-04's data), 200 with:

    * `group_name`, `event_name`, `session_date` (WIB calendar date), `session_starts_at`
    * `status` (`unpaid | paid | needs_review | void`), `status_label`, `message`
    * `token_expired`, `can_pay`
    * `share`, `credit_applied`, `amount_due`, `rounding` and `lines`
      (`[%{category, label, amount}]`; `lines` plus `rounding` add up to `share`);
      absent for a void bill, which has no payable amount
    * `methods`: `[%{method, label, fee, gross_amount}]`, empty unless `can_pay`
    * `attempt`: the active payment (see below) or `null`, and `attempt_expired`:
      `true` when the bill is unpaid and the last attempt has expired. The page then
      calls `POST /pay/:token/payment` again for a new attempt.

  `POST /api/pay/:token/payment` with `{"method": "qris" | "va" | "ewallet"}`: 201 with a
  new attempt, 200 with the still-active one of the same method (`reused: true`):
  `method`, `action` (`%{"type" => "qr_string" | "va_number" | "redirect_url", <type> => value}`),
  `amount_due`, `fee`, `gross_amount`, `expires_at`. Errors: 404 `not_found` (unknown
  token), 409 `bill_paid | bill_void | bill_needs_review`, 410 `token_expired`, 422
  `unsupported_method | invalid_params`, 502 `gateway_error`; each with an Indonesian
  `message`.
  """
  use PetepeteWeb, :controller

  alias Petepete.{Payments, Wib}
  alias Petepete.Payments.PaymentAttempt
  alias PetepeteWeb.LedgerError

  @status_labels %{
    "unpaid" => "Belum bayar",
    "paid" => "Lunas",
    "needs_review" => "Perlu dicek",
    "void" => "Dibatalkan"
  }

  @status_messages %{
    "paid" => "Tagihan ini sudah lunas. Makasih ya!",
    "needs_review" => "Pembayaranmu lagi dicek host. Tunggu sebentar ya.",
    "void" => "Tagihan dibatalkan"
  }

  @method_labels %{"qris" => "QRIS", "va" => "Virtual Account", "ewallet" => "E-wallet"}

  @errors %{
    not_found: {404, "Link bayar tidak ditemukan."},
    unsupported_method:
      {422, "Metode bayar tidak dikenal. Pilih QRIS, Virtual Account, atau e-wallet."},
    bill_paid: {409, "Tagihan ini sudah lunas."},
    bill_void: {409, "Tagihan dibatalkan"},
    bill_needs_review: {409, "Pembayaranmu lagi dicek host. Tunggu sebentar ya."},
    token_expired: {410, "Link bayar sudah kedaluwarsa. Minta link baru ke host."},
    gateway_error: {502, "Gateway sedang bermasalah. Coba lagi nanti."}
  }

  def show(conn, %{"token" => token}) do
    case Payments.pay_page(token) do
      {:ok, view} -> json(conn, page(view))
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def create_payment(conn, %{"token" => token, "method" => method}) do
    case Payments.start_payment(token, method) do
      {:ok, %{attempt: attempt, reused: reused}} ->
        conn
        |> put_status(if reused, do: 200, else: 201)
        |> json(Map.put(attempt_data(attempt), :reused, reused))

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def create_payment(conn, _params) do
    LedgerError.render_invalid(conn, %{"method" => "wajib diisi"})
  end

  defp render_error(conn, reason) do
    {status, message} = Map.fetch!(@errors, reason)

    conn
    |> put_status(status)
    |> json(%{error: Atom.to_string(reason), message: message})
  end

  defp page(%{bill: bill, page: page} = view) do
    base = %{
      group_name: page.group_name,
      event_name: page.event_name,
      session_date: page.session_starts_at |> Wib.date() |> Date.to_iso8601(),
      session_starts_at: page.session_starts_at,
      status: bill.status,
      status_label: Map.fetch!(@status_labels, bill.status),
      message: Map.get(@status_messages, bill.status),
      token_expired: view.token_expired,
      can_pay: view.can_pay
    }

    if bill.status == "void" do
      base
    else
      Map.merge(base, %{
        share: bill.share,
        credit_applied: bill.credit_applied,
        amount_due: bill.amount_due,
        rounding: page.rounding,
        lines: page.lines,
        paid_at: bill.paid_at,
        methods:
          for(m <- view.methods, do: Map.put(m, :label, Map.fetch!(@method_labels, m.method))),
        attempt: view.attempt && attempt_data(view.attempt),
        attempt_expired: view.attempt_expired
      })
    end
  end

  defp attempt_data(%PaymentAttempt{} = attempt) do
    %{
      method: attempt.method,
      action: attempt.action,
      amount_due: attempt.amount_due,
      fee: attempt.fee,
      gross_amount: attempt.gross_amount,
      expires_at: attempt.expires_at
    }
  end
end
