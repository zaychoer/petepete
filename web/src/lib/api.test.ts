import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, apiFetch, errorMessage } from "./api";
import { loadError, readContractFile } from "../test/sample";

function answer(status: number, body: string): void {
  vi.stubGlobal("fetch", async () => new Response(body, { status }));
}

async function failure(): Promise<ApiError> {
  const error = await apiFetch("/api/anything").catch((e: unknown) => e);
  expect(error).toBeInstanceOf(ApiError);
  return error as ApiError;
}

afterEach(() => vi.unstubAllGlobals());

describe("apiFetch errors", () => {
  const codes = readContractFile<{ errors: string[] }>("manifest.json").errors;

  it.each(codes)("shows the server's message for %s", async (code) => {
    const sample = loadError(code).json;
    answer(422, JSON.stringify(sample));
    const error = await failure();
    expect(error.code).toBe(code);
    expect(error.message).toBe(sample.message);
  });

  it("keeps the first message of each flagged field", async () => {
    answer(
      422,
      JSON.stringify({ error: "invalid", message: "Cek lagi ya.", fields: { phone: ["a", "b"] } }),
    );
    expect((await failure()).fields).toEqual({ phone: "a" });
  });

  it("falls back to a generic Indonesian text when the body has no message", async () => {
    answer(502, "<html>Bad gateway</html>");
    const error = await failure();
    expect(error.code).toBe("unknown");
    expect(error.message).toBe(errorMessage(new Error("x")));
  });

  it("says the connection is bad when the request got no answer", async () => {
    vi.stubGlobal("fetch", async () => {
      throw new TypeError("failed to fetch");
    });
    const error = await failure();
    expect(error.status).toBe(0);
    expect(error.message).toMatch(/Koneksi/);
  });
});
