import { useState, type FormEvent } from "react";
import { ApiError, apiFetch, errorMessage } from "@/lib/api";
import { appInviteUrl } from "@/lib/invite-url";

interface JoinResult {
  member_id: number;
  group: { id: number; name: string };
}

export function JoinForm({
  token,
  groupName,
}: {
  token: string;
  groupName: string;
}) {
  const [displayName, setDisplayName] = useState("");
  const [phone, setPhone] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [joined, setJoined] = useState<JoinResult | null>(null);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting) return;

    setSubmitting(true);
    setFieldErrors({});
    setFormError(null);
    try {
      const body: { display_name: string; phone?: string } = {
        display_name: displayName.trim(),
      };
      if (phone.trim()) body.phone = phone.trim();
      setJoined(
        await apiFetch<JoinResult>(`/api/invites/${encodeURIComponent(token)}/join`, {
          method: "POST",
          body,
        }),
      );
    } catch (error) {
      if (error instanceof ApiError && Object.keys(error.fields).length > 0) {
        // Each field shows the server's own text for it.
        setFieldErrors(error.fields);
      } else {
        setFormError(errorMessage(error));
      }
    } finally {
      setSubmitting(false);
    }
  }

  if (joined) {
    return (
      <>
        <h1 className="text-2xl font-semibold">Kamu sudah masuk!</h1>
        <p>
          Selamat datang di <strong>{joined.group.name}</strong>. Host sudah
          bisa melihat namamu di daftar anggota.
        </p>
        <section className="flex flex-col gap-2 rounded-xl border border-current/30 p-4">
          <h2 className="font-semibold">Nggak perlu install aplikasi</h2>
          <p className="text-sm">
            Tagihan dari host datang sebagai link bayar. Buka linknya di browser,
            bayar lewat QRIS, VA, atau e-wallet, selesai. Aplikasi Petepete
            opsional: berguna buat lihat riwayat dan saldo grup.
          </p>
        </section>
        <a
          href={appInviteUrl(window.location.origin, token, joined.member_id)}
          className="w-full rounded-lg bg-green-700 px-4 py-3 text-center font-medium text-white"
        >
          Buka di aplikasi
        </a>
        <p className="text-sm">
          Kalau aplikasinya belum terpasang, tombol di atas cuma membuka halaman
          ini lagi. Lewati saja, kamu tetap bisa bayar lewat link dari host.
        </p>
      </>
    );
  }

  return (
    <>
      <header className="flex flex-col gap-1">
        <p className="text-sm">Kamu diundang ke grup</p>
        <h1 className="text-2xl font-semibold">{groupName}</h1>
      </header>
      <p className="text-sm">
        Isi namamu biar host tahu siapa kamu. Nggak perlu install aplikasi.
      </p>

      <form onSubmit={onSubmit} noValidate className="flex flex-col gap-4">
        <div className="flex flex-col gap-1">
          <label htmlFor="display_name" className="font-medium">
            Nama
          </label>
          <input
            id="display_name"
            name="display_name"
            type="text"
            autoComplete="name"
            required
            maxLength={60}
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
            aria-invalid={Boolean(fieldErrors.display_name)}
            aria-describedby={
              fieldErrors.display_name ? "display_name-error" : undefined
            }
            className="rounded-lg border border-current/40 bg-transparent px-3 py-2"
          />
          {fieldErrors.display_name && (
            <p id="display_name-error" role="alert" className="text-sm font-medium">
              {fieldErrors.display_name}
            </p>
          )}
        </div>

        <div className="flex flex-col gap-1">
          <label htmlFor="phone" className="font-medium">
            Nomor WhatsApp <span className="font-normal">(opsional)</span>
          </label>
          <input
            id="phone"
            name="phone"
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            placeholder="0812…"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            aria-invalid={Boolean(fieldErrors.phone)}
            aria-describedby={fieldErrors.phone ? "phone-error" : "phone-hint"}
            className="rounded-lg border border-current/40 bg-transparent px-3 py-2"
          />
          {fieldErrors.phone ? (
            <p id="phone-error" role="alert" className="text-sm font-medium">
              {fieldErrors.phone}
            </p>
          ) : (
            <p id="phone-hint" className="text-sm">
              Cuma dilihat host, buat kirim pengingat lewat WhatsApp. Boleh
              dikosongkan.
            </p>
          )}
        </div>

        {formError && (
          <p role="alert" className="text-sm font-medium">
            {formError}
          </p>
        )}

        <button
          type="submit"
          disabled={submitting}
          className="w-full rounded-lg bg-green-700 px-4 py-3 font-medium text-white disabled:opacity-60"
        >
          {submitting ? "Masuk…" : "Gabung grup"}
        </button>
      </form>
    </>
  );
}
