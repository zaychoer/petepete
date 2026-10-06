import { describe, expect, it } from "vitest";
import { readContractFile } from "../test/sample";
import { formatRupiah } from "./rupiah";

const cases = readContractFile<{ amount: number; text: string }[]>("rupiah.json");

describe("formatRupiah", () => {
  it.each(cases)("formats $amount as $text (contract/rupiah.json)", ({ amount, text }) => {
    expect(formatRupiah(amount)).toBe(text);
  });

  it("refuses fractions and unsafe numbers: money is integer rupiah", () => {
    expect(() => formatRupiah(10.5)).toThrow(RangeError);
    expect(() => formatRupiah(Number.NaN)).toThrow(RangeError);
    expect(() => formatRupiah(Number.MAX_SAFE_INTEGER + 2)).toThrow(RangeError);
  });
});
