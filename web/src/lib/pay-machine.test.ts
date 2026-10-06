import { describe, expect, it } from "vitest";
import {
  applyAttempt,
  createOpenRegeneration,
  initialMethod,
  openRegenerationMethod,
  phaseOf,
  shouldPoll,
} from "./pay-machine";
import { loadSample } from "../test/sample";
import type { BillPayPage, PayAttempt, PayPage, VoidPayPage } from "./pay-types";

const methods = loadSample<BillPayPage>("pay_page.unpaid").json.methods;

const qrisAttempt: PayAttempt = {
  method: "qris",
  action: { type: "qr_string", qr_string: "000201..." },
  amount_due: 35_000,
  fee: 700,
  gross_amount: 35_700,
  expires_at: "2026-10-08T13:30:00Z",
};

/** The recorded unpaid page (`contract/samples/pay_page.unpaid.json`) with overrides. */
function bill(overrides: Record<string, unknown> = {}): BillPayPage {
  return loadSample<BillPayPage>("pay_page.unpaid").with(overrides).json;
}

const voidPage = loadSample<VoidPayPage>("pay_page.void").json;

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

describe("openRegenerationMethod", () => {
  it("asks for a new QRIS when the page opens on an expired QRIS", () => {
    const page = bill({ attempt_expired: true, expired_method: "qris" });
    expect(openRegenerationMethod(page)).toBe("qris");
  });

  it("leaves an expired VA or e-wallet to the pay button", () => {
    expect(
      openRegenerationMethod(bill({ attempt_expired: true, expired_method: "va" })),
    ).toBe(null);
    expect(
      openRegenerationMethod(bill({ attempt_expired: true, expired_method: "ewallet" })),
    ).toBe(null);
  });

  it("does nothing when the expired method is unknown or QRIS is not offered", () => {
    expect(openRegenerationMethod(bill({ attempt_expired: true }))).toBe(null);
    const noQris = bill({
      attempt_expired: true,
      expired_method: "qris",
      methods: [methods[1]],
    });
    expect(openRegenerationMethod(noQris)).toBe(null);
  });

  it("does nothing in any other phase", () => {
    expect(openRegenerationMethod(bill())).toBe(null);
    expect(openRegenerationMethod(bill({ attempt: qrisAttempt }))).toBe(null);
    expect(openRegenerationMethod(voidPage)).toBe(null);
  });
});

describe("createOpenRegeneration", () => {
  it("hands out the QRIS regeneration exactly once", () => {
    const regen = createOpenRegeneration(
      bill({ attempt_expired: true, expired_method: "qris" }),
    );
    expect(regen.claim()).toBe("qris");
    expect(regen.claim()).toBe(null);
    expect(regen.claim()).toBe(null);
  });

  it("never regenerates when the page opened with a live QRIS that expires later", () => {
    // Decided from the page as opened: an active attempt, so nothing is pending even after
    // the polled page later shows the same QRIS as expired.
    const regen = createOpenRegeneration(bill({ attempt: qrisAttempt }));
    expect(regen.claim()).toBe(null);
  });

  it("never regenerates for an expired VA on open", () => {
    const regen = createOpenRegeneration(
      bill({ attempt_expired: true, expired_method: "va" }),
    );
    expect(regen.claim()).toBe(null);
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
