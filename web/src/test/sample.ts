/**
 * Recorded API responses from `contract/` (ADR-0004) for vitest, with a builder that refuses
 * to change the shape the server really sends. Same rules as the app's `Sample` and the
 * server's `Petepete.Contract`: an override keeps the sample's JSON type per value, `null` on
 * either side is free, objects keep their key set, values/ids/timestamps are free.
 *
 *   const page = loadSample<BillPayPage>("pay_page.unpaid")
 *     .with({ amount_due: 50_000, attempt: { method: "qris", ... } })
 *     .withItems("lines", [{ label: "Konsumsi" }, {}])
 *     .json;
 *
 * JSON has one number type here: `1` and `1.0` are both "number", so the server's
 * integer-vs-float distinction is not enforced on the web.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** Thrown when an override does not fit the recorded sample. */
export class SampleOverrideError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SampleOverrideError";
  }
}

/** Body of an error sample: `{ error, message }` plus any detail keys. */
export interface ErrorBody {
  error: string;
  message: string;
  [detail: string]: unknown;
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };

const CONTRACT_DIR = fileURLToPath(new URL("../../../contract/", import.meta.url));

/** Reads and parses a file under `contract/`, e.g. `readContractFile("rupiah.json")`. */
export function readContractFile<T = unknown>(relativePath: string): T {
  return JSON.parse(readFileSync(`${CONTRACT_DIR}${relativePath}`, "utf8")) as T;
}

/** The recorded sample `name` (`"pay_page.unpaid"`, or `"errors/<code>"`). */
export function loadSample<T = JsonObject>(name: string): Sample<T> {
  let body: Json;
  try {
    body = readContractFile<Json>(`samples/${name}.json`);
  } catch (error) {
    throw new Error(`No contract sample ${name} under contract/samples: ${String(error)}`);
  }
  return new Sample<T>(name, body);
}

/** The recorded error sample `contract/samples/errors/<code>.json`. */
export function loadError(code: string): Sample<ErrorBody> {
  return loadSample<ErrorBody>(`errors/${code}`);
}

export class Sample<T = JsonObject> {
  constructor(
    readonly name: string,
    private readonly body: Json,
  ) {}

  /** A fresh deep copy of the body, safe to mutate. */
  get json(): T {
    return clone(this.body) as T;
  }

  /** The body as a JSON string, as the server would send it. */
  encode(): string {
    return JSON.stringify(this.body);
  }

  /**
   * A copy with `overrides` applied. A key is a field name or a dotted path
   * (`"attempt.method"`, `"lines.0.amount"`; numeric segments index arrays). An object value
   * merges into the sample's object (unknown keys throw), an array replaces the array with
   * every element matching the sample's first element, anything else replaces the value.
   * Throws `SampleOverrideError` when a path does not exist or a value changes a JSON type.
   */
  with(overrides: Record<string, unknown>): Sample<T> {
    const copy = clone(this.body);
    if (!isObject(copy)) throw new SampleOverrideError(`${this.name} is not a JSON object`);
    for (const [key, value] of Object.entries(overrides)) {
      assign(resolve(copy, key, ""), value as Json, key);
    }
    return new Sample<T>(this.name, copy);
  }

  /**
   * A copy whose array at `path` holds one element per entry of `items`. Each element starts
   * as the sample's first element with the entry's overrides applied (same rules as `with`);
   * `{}` keeps the first element as recorded, `[]` gives an empty array.
   */
  withItems(path: string, items: Record<string, unknown>[]): Sample<T> {
    const copy = clone(this.body);
    const slot = resolve(copy, path, "");
    const current = slot.read();
    if (!Array.isArray(current)) {
      throw new SampleOverrideError(`${path} is ${typeName(current)}, withItems needs an array`);
    }
    if (current.length === 0) {
      throw new SampleOverrideError(
        `${path} is empty in ${this.name}, record the sample with a non-empty array`,
      );
    }
    slot.write(
      items.map((overrides, i) => {
        const element = clone(current[0]);
        if (Object.keys(overrides).length > 0) {
          if (!isObject(element)) {
            throw new SampleOverrideError(`${path}.${i} overrides need object elements`);
          }
          for (const [key, value] of Object.entries(overrides)) {
            assign(resolve(element, key, `${path}.${i}`), value as Json, `${path}.${i}.${key}`);
          }
        }
        return element;
      }),
    );
    return new Sample<T>(this.name, copy);
  }
}

interface Slot {
  read(): Json | undefined;
  write(value: Json): void;
}

function typeName(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function clone(value: Json): Json {
  return JSON.parse(JSON.stringify(value)) as Json;
}

/** The slot of the last segment of the dotted `path` below `root` (`prefix` is for messages). */
function resolve(root: Json, path: string, prefix: string): Slot {
  const segments = path.split(".");
  let node: Json = root;
  let walked = prefix;
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i];
    const here = walked ? `${walked}.${segment}` : segment;
    let slot: Slot;
    if (isObject(node)) {
      const obj: JsonObject = node;
      if (!(segment in obj)) {
        throw new SampleOverrideError(
          `${here} does not exist in the sample (keys: ${Object.keys(obj).sort().join(", ")})`,
        );
      }
      slot = { read: () => obj[segment], write: (v) => void (obj[segment] = v) };
    } else if (Array.isArray(node)) {
      const arr: Json[] = node;
      const index = /^\d+$/.test(segment) ? Number(segment) : -1;
      if (index < 0 || index >= arr.length) {
        throw new SampleOverrideError(
          `${here} is not a valid index (array has ${arr.length} elements)`,
        );
      }
      slot = { read: () => arr[index], write: (v) => void (arr[index] = v) };
    } else {
      throw new SampleOverrideError(
        `${walked} is ${typeName(node)} in the sample, override it as a whole`,
      );
    }
    if (i === segments.length - 1) return slot;
    node = slot.read() as Json;
    walked = here;
  }
  throw new SampleOverrideError("empty path");
}

function assign(slot: Slot, value: Json, path: string): void {
  const current = slot.read();
  if (isObject(value) && isObject(current)) {
    for (const key of Object.keys(value)) {
      if (!(key in current)) {
        throw new SampleOverrideError(
          `${path}.${key} does not exist in the sample (keys: ${Object.keys(current).sort().join(", ")})`,
        );
      }
    }
    for (const [key, inner] of Object.entries(value)) {
      assign({ read: () => current[key], write: (v) => void (current[key] = v) }, inner, `${path}.${key}`);
    }
    return;
  }
  checkShape(current ?? null, value, path);
  slot.write(clone(value));
}

/** The server comparer's rules for one value: `null` is free, types and key sets must match. */
function checkShape(sample: Json, value: Json, path: string): void {
  if (sample === null || value === null) return;
  if (typeName(sample) !== typeName(value)) {
    throw new SampleOverrideError(
      `${path} changes type from ${typeName(sample)} to ${typeName(value)}`,
    );
  }
  if (isObject(sample) && isObject(value)) {
    const missing = Object.keys(sample).filter((k) => !(k in value)).sort();
    const extra = Object.keys(value).filter((k) => !(k in sample)).sort();
    if (missing.length > 0 || extra.length > 0) {
      throw new SampleOverrideError(
        `${path} changes the key set (missing: ${missing.join(", ")}; unexpected: ${extra.join(", ")})`,
      );
    }
    for (const key of Object.keys(sample)) checkShape(sample[key], value[key], `${path}.${key}`);
  } else if (Array.isArray(sample) && Array.isArray(value) && sample.length > 0) {
    value.forEach((element, i) => checkShape(sample[0], element, `${path}.${i}`));
  }
}
