import { formatWibTime } from "@/lib/dates";
import { formatRupiah } from "@/lib/rupiah";
import type { PayAttempt } from "@/lib/pay-types";
import { CopyButton } from "./copy-button";
import { QrCode } from "./qr-code";

/** Only plain https links go to a button: the gateway is trusted, the check is cheap. */
function safeHttpsUrl(url: string): string | null {
  try {
    return new URL(url).protocol === "https:" ? url : null;
  } catch {
    return null;
  }
}

/** What the payer does next: scan, transfer to a VA number, or go to the e-wallet. */
export function AttemptAction({ attempt }: { attempt: PayAttempt }) {
  const { action } = attempt;
  const redirect =
    action.type === "redirect_url" ? safeHttpsUrl(action.redirect_url) : null;

  return (
    <div className="flex flex-col items-start gap-3">
      <p className="text-sm">
        Bayar tepat{" "}
        <strong className="tabular-nums">
          {formatRupiah(attempt.gross_amount)}
        </strong>{" "}
        (sudah termasuk biaya gateway {formatRupiah(attempt.fee)}).
      </p>

      {action.type === "qr_string" && (
        <>
          <QrCode value={action.qr_string} />
          <p className="text-sm">
            Scan pakai aplikasi bank atau e-wallet apa pun yang mendukung QRIS.
          </p>
        </>
      )}

      {action.type === "va_number" && (
        <>
          <p className="text-sm">Transfer ke nomor Virtual Account ini:</p>
          <p
            className="text-2xl font-semibold tracking-wider tabular-nums break-all"
            data-testid="va-number"
          >
            {action.va_number}
          </p>
          <CopyButton value={action.va_number} label="Salin nomor VA" />
        </>
      )}

      {action.type === "redirect_url" &&
        (redirect ? (
          <a
            href={redirect}
            rel="noopener noreferrer"
            className="w-full rounded-lg bg-green-700 px-4 py-3 text-center font-medium text-white"
          >
            Buka e-wallet
          </a>
        ) : (
          <p role="alert" className="text-sm">
            Link e-wallet tidak valid. Pilih metode lain atau muat ulang halaman.
          </p>
        ))}

      <p className="text-sm">
        Berlaku sampai {formatWibTime(attempt.expires_at)}. Halaman ini otomatis
        berubah ke Lunas setelah pembayaran masuk.
      </p>
    </div>
  );
}
