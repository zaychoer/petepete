/**
 * Tiny client for the Petepete API, used by server loaders (first paint) and client
 * components (polling, forms). The base URL is public: `VITE_API_BASE_URL`.
 */

export class ApiError extends Error {
  /** HTTP status, or 0 when the request never got an answer (offline, DNS, CORS). */
  readonly status: number;
  /** The API's `error` code, e.g. `bill_void`, `not_found`, `invalid`. */
  readonly code: string;
  /** Per-field messages of a 422 (`fields`), keyed by field name. */
  readonly fields: Record<string, string>;

  constructor(
    status: number,
    code: string,
    message: string,
    fields: Record<string, string> = {},
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.fields = fields;
  }
}

export function apiBaseUrl(): string {
  const configured = import.meta.env.VITE_API_BASE_URL as string | undefined;
  if (configured) return configured.replace(/\/+$/, "");
  if (import.meta.env.DEV) return "http://localhost:4000";
  throw new Error("VITE_API_BASE_URL is not set");
}

/** Only for requests that got no answer at all (offline, DNS, CORS). */
const NETWORK_MESSAGE = "Koneksi lagi bermasalah. Coba lagi ya.";

/** Only for an error answer that has no `message` (a proxy page, Phoenix's default error body). */
export const FALLBACK_MESSAGE = "Ada yang salah. Coba lagi ya.";

/** Text to show for a caught error: the server's `message` (or the fallback) of an `ApiError`. */
export function errorMessage(error: unknown): string {
  return error instanceof ApiError ? error.message : FALLBACK_MESSAGE;
}

/** `fields` of a 422 may hold a list of messages per field; keep the first. */
function readFields(body: unknown): Record<string, string> {
  if (typeof body !== "object" || body === null) return {};
  const raw = (body as { fields?: unknown }).fields;
  if (typeof raw !== "object" || raw === null) return {};
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw)) {
    const first = Array.isArray(value) ? value[0] : value;
    if (typeof first === "string") out[key] = first;
  }
  return out;
}

export async function apiFetch<T>(
  path: string,
  init: { method?: "GET" | "POST"; body?: unknown; signal?: AbortSignal } = {},
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${apiBaseUrl()}${path}`, {
      method: init.method ?? "GET",
      cache: "no-store",
      signal: init.signal,
      headers: {
        accept: "application/json",
        ...(init.body === undefined
          ? {}
          : { "content-type": "application/json" }),
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw error;
    }
    throw new ApiError(0, "network", NETWORK_MESSAGE);
  }

  let body: unknown = null;
  try {
    body = await response.json();
  } catch {
    // Non-JSON answer (proxy error page): handled below by status.
  }

  if (!response.ok) {
    const payload =
      typeof body === "object" && body !== null
        ? (body as { error?: unknown; message?: unknown })
        : {};
    throw new ApiError(
      response.status,
      typeof payload.error === "string" ? payload.error : "unknown",
      typeof payload.message === "string" ? payload.message : FALLBACK_MESSAGE,
      readFields(body),
    );
  }
  return body as T;
}
