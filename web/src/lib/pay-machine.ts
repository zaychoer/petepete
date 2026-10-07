import type { BillPayPage, Method, PayAttempt, PayPage } from "./pay-types";

/**
 * The pay page as a small state machine. The server owns the truth (`GET /api/pay/:token`);
 * the page only decides what to show, whether to keep polling and when to ask for a fresh
 * payment.
 *
 *   choose --POST--> awaiting --(paid)--> paid        (terminal)
 *      |                |  \--(expired)--> expired --POST--> awaiting
 *      |                \----(needs_review)--> needs_review --(host resolves)--> paid | void
 *      \--(void) --> void                           (terminal)
 *      \--(link past token_expires_at) --> link_expired   (terminal)
 */

export type Phase =
  | "choose"
  | "awaiting"
  | "expired"
  | "needs_review"
  | "paid"
  | "void"
  | "link_expired";

export const POLL_INTERVAL_MS = 5000;
export const DEFAULT_METHOD: Method = "qris";

export function phaseOf(page: PayPage): Phase {
  switch (page.status) {
    case "void":
      return "void";
    case "paid":
      return "paid";
    case "needs_review":
      return "needs_review";
    case "unpaid":
      if (page.token_expired) return "link_expired";
      if (page.attempt) return "awaiting";
      if (page.attempt_expired) return "expired";
      return "choose";
  }
}

/** Polling goes on until the bill is Lunas or Dibatalkan, or the link itself is dead. */
export function shouldPoll(phase: Phase): boolean {
  return phase !== "paid" && phase !== "void" && phase !== "link_expired";
}

/**
 * The method to request a new attempt for when the page is opened, or null (PAY-06): only an
 * expired QRIS is replaced automatically, and only for the page as first loaded. An expired
 * VA or e-wallet, and any expiry that happens while the page stays open, wait for the payer
 * to press the pay button.
 */
export function openRegenerationMethod(page: PayPage): Method | null {
  if (phaseOf(page) !== "expired") return null;
  const { methods, expired_method } = page as BillPayPage;
  if (expired_method !== "qris") return null;
  return methods.some((m) => m.method === "qris") ? "qris" : null;
}

/**
 * One-shot automatic regeneration, decided from the page as first loaded. `claim()` hands
 * out the method once, then null for good, so a later expiry while the page stays open (or
 * a failed POST) never triggers another automatic request.
 */
export function createOpenRegeneration(initialPage: PayPage): { claim(): Method | null } {
  let pending = openRegenerationMethod(initialPage);
  return {
    claim() {
      const method = pending;
      pending = null;
      return method;
    },
  };
}

/** The page after a successful `POST /payment`: the new attempt is the active one. */
export function applyAttempt(page: PayPage, attempt: PayAttempt): PayPage {
  if (page.status !== "unpaid") return page;
  return { ...page, attempt, attempt_expired: false };
}

/** The API answers these when the bill moved on under the payer: reload the page state. */
export const STALE_BILL_ERRORS: ReadonlySet<string> = new Set([
  "bill_paid",
  "bill_void",
  "bill_needs_review",
  "token_expired",
]);

/** The method shown selected: the active attempt's, else the last one, else QRIS. */
export function initialMethod(page: PayPage): Method {
  if (page.status === "void") return DEFAULT_METHOD;
  if (page.attempt) return page.attempt.method;
  if (page.methods.some((m) => m.method === DEFAULT_METHOD)) return DEFAULT_METHOD;
  return page.methods[0]?.method ?? DEFAULT_METHOD;
}
