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

export interface RegenerationContext {
  /** The method the payer used last on this page, if any. */
  lastMethod: Method | null;
  /** A POST is already running. */
  inFlight: boolean;
  /** The last automatic POST failed: wait for the payer instead of hammering the gateway. */
  failed: boolean;
}

/**
 * The method to request a new attempt for, or null. An expired attempt is replaced
 * automatically with the same method (QRIS when the page was just opened).
 */
export function regenerationMethod(
  page: PayPage,
  ctx: RegenerationContext,
): Method | null {
  if (phaseOf(page) !== "expired" || ctx.inFlight || ctx.failed) return null;
  const { methods } = page as BillPayPage;
  const wanted = ctx.lastMethod ?? DEFAULT_METHOD;
  if (methods.some((m) => m.method === wanted)) return wanted;
  return methods[0]?.method ?? null;
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
