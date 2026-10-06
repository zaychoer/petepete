// Masks Indonesian phone numbers (08…, 62…, +62…) in everything Sentry would send.
// Same rules as api/lib/petepete/phone_mask.ex and the Flutter app's sentry_scrub.dart.

const PHONE =
  /(?<!\w)(?:\+|%2[Bb])?(?:62|0)[\s.-]?[1-9](?:[\s.-]?\d){7,12}(?!\d)/g;

export const PHONE_MASK = "[PHONE]";

export function maskPhones(text: string): string {
  return text.replace(PHONE, PHONE_MASK);
}

function isPlainObject(value: object): value is Record<string, unknown> {
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

/** Returns a copy of `value` with every string (and string object key) masked. */
export function scrub<T>(value: T, seen = new WeakMap<object, unknown>()): T {
  if (typeof value === "string") return maskPhones(value) as T;
  if (typeof value !== "object" || value === null) return value;

  const cached = seen.get(value);
  if (cached !== undefined) return cached as T;

  if (Array.isArray(value)) {
    const copy: unknown[] = [];
    seen.set(value, copy);
    for (const item of value) copy.push(scrub(item, seen));
    return copy as T;
  }

  if (!isPlainObject(value)) return value;

  const copy: Record<string, unknown> = {};
  seen.set(value, copy);
  for (const [key, item] of Object.entries(value)) {
    copy[maskPhones(key)] = scrub(item, seen);
  }
  return copy as T;
}
