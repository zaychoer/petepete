import { describe, expect, it } from "vitest";
import {
  applyAttempt,
  initialMethod,
  phaseOf,
  regenerationMethod,
  shouldPoll,
} from "./pay-machine";
import type { BillPayPage, PayAttempt, PayPage, VoidPayPage } from "./pay-types";

const methods = [
  { method: "qris", label: "QRIS", fee: 700, gross_amount: 35_700 },
  { method: "va", label: "Virtual Account", fee: 4_440, gross_amount: 39_440 },
  { method: "ewallet", label: "E-wallet", fee: 700, gross_amount: 35_700 },
] as const;

const qrisAttempt: PayAttempt = {
  method: "qris",
  action: { type: "qr_string", qr_string: "000201..." },
  amount_due: 35_000,
  fee: 700,
  gross_amount: 35_700,
  expires_at: "2026-10-08T13:30:00Z",
};

function bill(overrides: Partial<BillPayPage> = {}): BillPayPage {
  return {
    group_name: "Futsal Kamis",
    event_name: "Futsal",
    session_date: "2026-10-08",
    session_starts_at: "2026-10-08T12:00:00Z",
    message: null,
    token_expired: false,
    can_pay: true,
    status: "unpaid",
    share: 35_000,
    credit_applied: 0,
    amount_due: 35_000,
    rounding: 0,
    lines: [],
    paid_at: null,
    methods: [...methods],
    attempt: null,
    attempt_expired: false,
    ...overrides,
  };
}

const voidPage: VoidPayPage = {
  group_name: "Futsal Kamis",
  event_name: "Futsal",
  session_date: "2026-10-08",
  session_starts_at: "2026-10-08T12:00:00Z",
  message: "Tagihan dibatalkan",
  token_expired: false,
  can_pay: false,
  status: "void",
};

describe("phaseOf", () => {
  it("follows the bill status and the attempt", () => {
    expect(phaseOf(bill())).toBe("choose");
    expect(phaseOf(bill({ attempt: qrisAttempt }))).toBe("awaiting");
    expect(phaseOf(bill({ attempt_expired: true }))).toBe("expired");
    expect(phaseOf(bill({ status: "needs_review", can_pay: false }))).toBe(
      "needs_review",
    );
    expect(phaseOf(bill({ status: "paid", can_pay: false }))).toBe("paid");
    expect(phaseOf(voidPage)).toBe("void");
  });

  it("a dead link wins over any attempt, but not over Lunas", () => {
    expect(
      phaseOf(bill({ token_expired: true, can_pay: false, attempt: qrisAttempt })),
    ).toBe("link_expired");
    expect(phaseOf(bill({ status: "paid", token_expired: false }))).toBe("paid");
  });
});

describe("shouldPoll", () => {
  it("polls until Lunas, Dibatalkan or a dead link", () => {
    expect(shouldPoll("choose")).toBe(true);
    expect(shouldPoll("awaiting")).toBe(true);
    expect(shouldPoll("expired")).toBe(true);
    expect(shouldPoll("needs_review")).toBe(true);
    expect(shouldPoll("paid")).toBe(false);
    expect(shouldPoll("void")).toBe(false);
    expect(shouldPoll("link_expired")).toBe(false);
  });
});

describe("regenerationMethod", () => {
  const idle = { lastMethod: null, inFlight: false, failed: false };

  it("asks for a new QRIS when the page opens on an expired attempt", () => {
    expect(regenerationMethod(bill({ attempt_expired: true }), idle)).toBe("qris");
  });

  it("keeps the method the payer used", () => {
    expect(
      regenerationMethod(bill({ attempt_expired: true }), {
        ...idle,
        lastMethod: "va",
      }),
    ).toBe("va");
  });

  it("falls back to the first available method when the wanted one is gone", () => {
    const page = bill({ attempt_expired: true, methods: [methods[1]] });
    expect(regenerationMethod(page, idle)).toBe("va");
    expect(regenerationMethod(bill({ attempt_expired: true, methods: [] }), idle)).toBe(
      null,
    );
  });

  it("never fires twice at once nor loops after a failure", () => {
    const page = bill({ attempt_expired: true });
    expect(regenerationMethod(page, { ...idle, inFlight: true })).toBe(null);
    expect(regenerationMethod(page, { ...idle, failed: true })).toBe(null);
  });

  it("does nothing in any other phase", () => {
    expect(regenerationMethod(bill(), idle)).toBe(null);
    expect(regenerationMethod(bill({ attempt: qrisAttempt }), idle)).toBe(null);
    expect(regenerationMethod(voidPage, idle)).toBe(null);
  });
});

describe("applyAttempt", () => {
  it("makes the new attempt the active one and clears the expired flag", () => {
    const next = applyAttempt(bill({ attempt_expired: true }), qrisAttempt);
    expect(phaseOf(next)).toBe("awaiting");
    expect((next as BillPayPage).attempt).toEqual(qrisAttempt);
  });

  it("leaves a bill that moved on alone", () => {
    const paid: PayPage = bill({ status: "paid", can_pay: false });
    expect(applyAttempt(paid, qrisAttempt)).toBe(paid);
    expect(applyAttempt(voidPage, qrisAttempt)).toBe(voidPage);
  });
});

describe("initialMethod", () => {
  it("defaults to QRIS, or the active attempt's method", () => {
    expect(initialMethod(bill())).toBe("qris");
    expect(
      initialMethod(
        bill({ attempt: { ...qrisAttempt, method: "va" } }),
      ),
    ).toBe("va");
    expect(initialMethod(bill({ methods: [methods[1]] }))).toBe("va");
  });
});
