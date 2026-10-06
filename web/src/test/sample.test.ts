import { describe, expect, it } from "vitest";
import { SampleOverrideError, loadSample } from "./sample";

describe("loadSample().with", () => {
  const unpaid = () => loadSample("pay_page.unpaid");

  it("changes values, including through dotted paths, and leaves the sample alone", () => {
    const page = unpaid().with({ amount_due: 50_000, "lines.0.label": "Konsumsi" }).json as {
      amount_due: number;
      lines: { label: string }[];
    };
    expect(page.amount_due).toBe(50_000);
    expect(page.lines[0].label).toBe("Konsumsi");
    expect((unpaid().json as { amount_due: number }).amount_due).toBe(34_000);
  });

  it("lets a null sample value take any value and a value become null", () => {
    const withAttempt = unpaid().with({ attempt: { method: "qris" } }).json as {
      attempt: unknown;
    };
    expect(withAttempt.attempt).toEqual({ method: "qris" });
    expect((unpaid().with({ group_name: null }).json as { group_name: unknown }).group_name).toBe(
      null,
    );
  });

  it("rejects an override that changes a JSON type", () => {
    expect(() => unpaid().with({ amount_due: "50000" })).toThrow(SampleOverrideError);
    expect(() => unpaid().with({ can_pay: "ya" })).toThrow(/can_pay changes type from boolean/);
    expect(() => unpaid().with({ lines: {} })).toThrow(/lines changes type from array/);
  });

  it("rejects unknown keys and array elements with another shape", () => {
    expect(() => unpaid().with({ nope: 1 })).toThrow(/nope does not exist/);
    expect(() => unpaid().with({ lines: [{ amount: 1 }] })).toThrow(/key set/);
    expect(() => unpaid().with({ lines: [{ amount: "1", category: "x", label: "y" }] })).toThrow(
      /lines.0.amount changes type/,
    );
  });
});

describe("loadSample().withItems", () => {
  it("builds each element from the recorded first one", () => {
    const page = loadSample("pay_page.unpaid").withItems("methods", [{ fee: 1 }, {}]).json as {
      methods: { method: string; fee: number }[];
    };
    expect(page.methods.map((m) => [m.method, m.fee])).toEqual([
      ["qris", 1],
      ["qris", 268],
    ]);
  });

  it("refuses an empty sample array", () => {
    expect(() => loadSample("pay_page.paid").withItems("methods", [{}])).toThrow(/is empty/);
  });
});
