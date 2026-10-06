import { describe, expect, it } from "vitest";
import { formatRupiah } from "./rupiah";

describe("formatRupiah", () => {
  it("groups thousands with dots", () => {
    expect(formatRupiah(0)).toBe("Rp0");
    expect(formatRupiah(999)).toBe("Rp999");
    expect(formatRupiah(1000)).toBe("Rp1.000");
    expect(formatRupiah(34_000)).toBe("Rp34.000");
    expect(formatRupiah(1_234_567)).toBe("Rp1.234.567");
  });

  it("puts the minus sign before Rp", () => {
    expect(formatRupiah(-1500)).toBe("-Rp1.500");
  });

  it("refuses fractions and unsafe numbers: money is integer rupiah", () => {
    expect(() => formatRupiah(10.5)).toThrow(RangeError);
    expect(() => formatRupiah(Number.NaN)).toThrow(RangeError);
    expect(() => formatRupiah(Number.MAX_SAFE_INTEGER + 2)).toThrow(RangeError);
  });
});
