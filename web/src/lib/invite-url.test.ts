import { describe, expect, it } from "vitest";
import { appInviteUrl } from "./invite-url";

describe("appInviteUrl", () => {
  it("builds the https join link with the claim query", () => {
    expect(appInviteUrl("https://petepete.id", "abc123", 42)).toBe(
      "https://petepete.id/join/abc123?claim=42",
    );
  });

  it("drops trailing slashes from the base", () => {
    expect(appInviteUrl("https://petepete.id//", "abc", 7)).toBe(
      "https://petepete.id/join/abc?claim=7",
    );
  });

  it("URL-encodes the token so it stays one path segment", () => {
    const url = new URL(appInviteUrl("https://petepete.id", "a/b?c#d e", 1));
    expect(url.pathname).toBe("/join/a%2Fb%3Fc%23d%20e");
    expect(url.search).toBe("?claim=1");
    expect(url.hash).toBe("");
  });
});
