"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError, apiFetch } from "@/lib/api";
import { formatSessionDate, formatWibDateTime } from "@/lib/dates";
import {
  POLL_INTERVAL_MS,
  STALE_BILL_ERRORS,
  applyAttempt,
  createOpenRegeneration,
  initialMethod,
  phaseOf,
  shouldPoll,
} from "@/lib/pay-machine";
import type { Method, PayAttempt, PayPage } from "@/lib/pay-types";
import { formatRupiah } from "@/lib/rupiah";
import { AttemptAction } from "./attempt-action";
import { Breakdown } from "./breakdown";
import { StatusChip } from "./status-chip";

export function PayView({
  token,
  initialPage,
}: {
  token: string;
  initialPage: PayPage;
}) {
  const [page, setPage] = useState<PayPage>(initialPage);
  const [selected, setSelected] = useState<Method>(() =>
    initialMethod(initialPage),
  );
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [offline, setOffline] = useState(false);

  // Bumped whenever a POST starts, so a poll that began earlier cannot overwrite its result.
  const epoch = useRef(0);
  const inFlight = useRef(false);

  const phase = phaseOf(page);
  const path = `/api/pay/${encodeURIComponent(token)}`;

  const refresh = useCallback(
    async (signal?: AbortSignal) => {
      const startedAt = epoch.current;
      try {
        const next = await apiFetch<PayPage>(path, { signal });
        if (epoch.current === startedAt) setPage(next);
        setOffline(false);
      } catch (error) {
        if (error instanceof DOMException && error.name === "AbortError") return;
        setOffline(true);
      }
    },
    [path],
  );

  const startPayment = useCallback(
    async (method: Method) => {
      if (inFlight.current) return;
      inFlight.current = true;
      epoch.current += 1;
      setBusy(true);
      setActionError(null);
      try {
        const attempt = await apiFetch<PayAttempt>(`${path}/payment`, {
          method: "POST",
          body: { method },
        });
        setPage((current) => applyAttempt(current, attempt));
      } catch (error) {
        if (error instanceof ApiError && STALE_BILL_ERRORS.has(error.code)) {
          // The bill moved on (paid, voided, needs review, link expired): show the truth.
          await refresh();
        } else {
          setActionError(
            error instanceof ApiError ? error.message : "Ada yang salah. Coba lagi ya.",
          );
        }
      } finally {
        inFlight.current = false;
        setBusy(false);
      }
    },
    [path, refresh],
  );

  // Poll every 5 s while the bill can still change; a hidden tab waits and catches up on return.
  const polling = shouldPoll(phase);
  useEffect(() => {
    if (!polling) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;

    const schedule = () => {
      timer = setTimeout(tick, POLL_INTERVAL_MS);
    };
    const tick = async () => {
      if (document.visibilityState === "visible") {
        await refresh(controller.signal);
      }
      if (!controller.signal.aborted) schedule();
    };
    const onVisible = () => {
      if (document.visibilityState !== "visible") return;
      clearTimeout(timer);
      void tick();
    };

    schedule();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      controller.abort();
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [polling, refresh]);

  // PAY-06: an expired QRIS is replaced once, when the page is opened. Every later expiry
  // (and any expired VA / e-wallet) waits for the payer's own tap.
  const [openRegen] = useState(() => createOpenRegeneration(initialPage));
  useEffect(() => {
    // Deferred so the request starts outside the render commit; cleanup cancels it.
    const timer = setTimeout(() => {
      const method = openRegen.claim();
      if (method) void startPayment(method);
    }, 0);
    return () => clearTimeout(timer);
  }, [openRegen, startPayment]);

  const header = (
    <header className="flex flex-col gap-1">
      <p className="text-sm">Tagihan patungan</p>
      <h1 className="text-2xl font-semibold">
        {page.group_name ?? page.event_name}
      </h1>
      <p className="text-sm">
        {page.group_name ? `${page.event_name} · ` : ""}
        {formatSessionDate(page.session_date)}
      </p>
      <div aria-live="polite" className="pt-2">
        <StatusChip phase={phase} />
      </div>
    </header>
  );

  if (page.status === "void") {
    return (
      <>
        {header}
        <p role="alert" className="font-medium">
          {page.message ?? "Tagihan dibatalkan"}
        </p>
        <p className="text-sm">
          Link ini nggak bisa dipakai buat bayar. Tanya host kalau ada tagihan
          baru.
        </p>
      </>
    );
  }

  const active = page.attempt && page.attempt.method === selected ? page.attempt : null;
  const option = page.methods.find((m) => m.method === selected);

  return (
    <>
      {header}
      <Breakdown page={page} />

      {page.status === "paid" && (
        <p className="font-medium">
          Lunas{page.paid_at ? `, dibayar ${formatWibDateTime(page.paid_at)}` : ""}.{" "}
          {page.message ?? "Makasih ya!"}
        </p>
      )}

      {page.status === "needs_review" && (
        <p className="font-medium">
          {page.message ?? "Pembayaranmu lagi dicek host. Tunggu sebentar ya."}
        </p>
      )}

      {phase === "link_expired" && (
        <p role="alert" className="font-medium">
          Link bayar sudah kedaluwarsa. Minta link baru ke host.
        </p>
      )}

      {page.can_pay && page.methods.length > 0 && (
        <section aria-labelledby="metode" className="flex flex-col gap-3">
          <h2 id="metode" className="font-semibold">
            Pilih cara bayar
          </h2>
          <div role="radiogroup" aria-labelledby="metode" className="flex flex-col gap-2">
            {page.methods.map((m) => (
              <label
                key={m.method}
                className={`flex cursor-pointer items-center gap-3 rounded-xl border p-3 ${
                  m.method === selected
                    ? "border-green-700 ring-2 ring-green-700"
                    : "border-current/30"
                }`}
              >
                <input
                  type="radio"
                  name="method"
                  value={m.method}
                  checked={m.method === selected}
                  onChange={() => {
                    setSelected(m.method);
                    setActionError(null);
                  }}
                  className="size-4 accent-green-700"
                />
                <span className="flex flex-1 flex-col">
                  <span className="font-medium">
                    {m.label}
                    {m.method === "qris" && (
                      <span className="ml-2 text-xs font-normal">
                        (paling gampang)
                      </span>
                    )}
                  </span>
                  <span className="text-sm">
                    Biaya gateway {formatRupiah(m.fee)}
                  </span>
                </span>
                <span className="text-sm font-medium tabular-nums">
                  {formatRupiah(m.gross_amount)}
                </span>
              </label>
            ))}
          </div>

          {active ? (
            <AttemptAction attempt={active} />
          ) : (
            <button
              type="button"
              disabled={busy || !option}
              onClick={() => void startPayment(selected)}
              className="w-full rounded-lg bg-green-700 px-4 py-3 font-medium text-white disabled:opacity-60"
            >
              {busy
                ? "Menyiapkan pembayaran…"
                : option
                  ? `Bayar ${formatRupiah(option.gross_amount)} pakai ${option.label}`
                  : "Pilih cara bayar"}
            </button>
          )}

          {active === null && phase === "expired" && (
            <p className="text-sm">
              {busy
                ? "Pembayaran sebelumnya kedaluwarsa, bikin yang baru…"
                : "Pembayaran sebelumnya kedaluwarsa. Tekan tombol di atas buat bikin yang baru."}
            </p>
          )}
          {actionError && (
            <p role="alert" className="text-sm font-medium">
              {actionError}
            </p>
          )}
        </section>
      )}

      {offline && polling && (
        <p role="status" className="text-sm">
          Koneksi lagi bermasalah, nyoba lagi otomatis…
        </p>
      )}
    </>
  );
}
