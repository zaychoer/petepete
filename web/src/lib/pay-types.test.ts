import { describe, expect, it } from "vitest";
import { loadSample, readContractFile } from "../test/sample";
import { parsePayAttempt, parsePayPage } from "./pay-types";

function without(object: Record<string, unknown>, key: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(object).filter(([k]) => k !== key));
}

const payPages = Object.entries(
  readContractFile<{ routes: Record<string, string[]> }>("manifest.json").routes,
)
  .filter(([route]) => route === "GET /api/pay/:token")
  .flatMap(([, names]) => names);

describe("parsePayPage", () => {
  it.each(payPages)("accepts the recorded %s", (name) => {
    expect(() => parsePayPage(loadSample(name).json)).not.toThrow();
  });

  it("accepts a page with an active attempt", () => {
    const page = loadSample("pay_page.unpaid").with({
      attempt: {
        method: "qris",
        action: { type: "qr_string", qr_string: "000201..." },
        amount_due: 34_000,
        fee: 268,
        gross_amount: 34_268,
        expires_at: "2026-10-06T04:00:00Z",
      },
    }).json;
    expect(parsePayPage(page)).toMatchObject({ attempt: { method: "qris" } });
  });

  it("names the field the server dropped or changed", () => {
    const unpaid = loadSample("pay_page.unpaid").json as Record<string, unknown>;
    const method = (unpaid.methods as Record<string, unknown>[])[0];

    expect(() => parsePayPage(without(unpaid, "status_label"))).toThrow(/page\.status_label/);
    expect(() => parsePayPage(without(unpaid, "methods"))).toThrow(/page\.methods/);
    expect(() => parsePayPage({ ...unpaid, methods: [without(method, "fee")] })).toThrow(
      /page\.methods\.0\.fee/,
    );
    expect(() => parsePayPage({ ...unpaid, amount_due: "34000" })).toThrow(/page\.amount_due/);
    expect(() => parsePayPage({ ...unpaid, status: "settled" })).toThrow(/status is unknown/);
  });

  it("does not need the amounts of a void bill", () => {
    expect(parsePayPage(loadSample("pay_page.void").json)).toMatchObject({ status: "void" });
  });
});

describe("parsePayAttempt", () => {
  it("rejects an action without its value", () => {
    expect(() =>
      parsePayAttempt({
        method: "va",
        action: { type: "va_number" },
        amount_due: 1,
        fee: 1,
        gross_amount: 2,
        expires_at: "2026-10-06T04:00:00Z",
      }),
    ).toThrow(/action/);
  });
});
