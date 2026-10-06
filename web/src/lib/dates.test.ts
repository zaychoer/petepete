import { describe, expect, it } from "vitest";
import { formatSessionDate, formatWibDateTime, formatWibTime } from "./dates";

describe("dates", () => {
  it("writes the session date with Indonesian day and month", () => {
    expect(formatSessionDate("2026-10-08")).toBe("Kamis, 8 Oktober 2026");
    expect(formatSessionDate("2026-01-01")).toBe("Kamis, 1 Januari 2026");
    expect(formatSessionDate("2024-02-29")).toBe("Kamis, 29 Februari 2024");
  });

  it("returns what it cannot read instead of inventing a date", () => {
    expect(formatSessionDate("2026-02-30")).toBe("2026-02-30");
    expect(formatSessionDate("besok")).toBe("besok");
  });

  it("shows instants in WIB, across midnight too", () => {
    expect(formatWibTime("2026-10-08T12:30:00Z")).toBe("19.30 WIB");
    expect(formatWibDateTime("2026-10-08T12:30:00Z")).toBe(
      "8 Oktober 2026, 19.30 WIB",
    );
    expect(formatWibDateTime("2026-12-31T18:05:00Z")).toBe(
      "1 Januari 2027, 01.05 WIB",
    );
  });
});
