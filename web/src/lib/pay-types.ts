/** Shapes of `GET /api/pay/:token` and `POST /api/pay/:token/payment`. No phone numbers exist here. */

export type Method = "qris" | "va" | "ewallet";

export type PayAction =
  | { type: "qr_string"; qr_string: string }
  | { type: "va_number"; va_number: string }
  | { type: "redirect_url"; redirect_url: string };

export interface PayAttempt {
  method: Method;
  action: PayAction;
  amount_due: number;
  fee: number;
  gross_amount: number;
  /** ISO-8601 instant. */
  expires_at: string;
  reused?: boolean;
}

export interface PayLine {
  category: string;
  label: string | null;
  amount: number;
}

export interface MethodOption {
  method: Method;
  label: string;
  fee: number;
  gross_amount: number;
}

interface PageBase {
  group_name: string | null;
  event_name: string;
  /** WIB calendar date, "YYYY-MM-DD". */
  session_date: string;
  session_starts_at: string;
  /** The server's Indonesian text for `status` (the chip shows it as is). */
  status_label: string;
  message: string | null;
  token_expired: boolean;
  can_pay: boolean;
}

/** A void bill has no payable amount: the API sends no amounts at all. */
export interface VoidPayPage extends PageBase {
  status: "void";
}

export interface BillPayPage extends PageBase {
  status: "unpaid" | "paid" | "needs_review";
  share: number;
  credit_applied: number;
  amount_due: number;
  /** Rounding added to this person's share; null when the lines could not be recomputed. */
  rounding: number | null;
  lines: PayLine[];
  paid_at: string | null;
  methods: MethodOption[];
  attempt: PayAttempt | null;
  attempt_expired: boolean;
  /** Method of the expired attempt while `attempt_expired`, else null. */
  expired_method: Method | null;
}

export type PayPage = VoidPayPage | BillPayPage;

/** `typeof` per field; a trailing `?` also allows `null`. */
type Fields = Record<string, "string" | "number" | "boolean" | "string?" | "number?">;

const BASE_FIELDS: Fields = {
  group_name: "string?",
  event_name: "string",
  session_date: "string",
  session_starts_at: "string",
  status_label: "string",
  message: "string?",
  token_expired: "boolean",
  can_pay: "boolean",
};

const BILL_FIELDS: Fields = {
  share: "number",
  credit_applied: "number",
  amount_due: "number",
  rounding: "number?",
  paid_at: "string?",
  attempt_expired: "boolean",
  expired_method: "string?",
};

const LINE_FIELDS: Fields = { category: "string", label: "string?", amount: "number" };
const METHOD_FIELDS: Fields = { method: "string", label: "string", fee: "number", gross_amount: "number" };
const ATTEMPT_FIELDS: Fields = {
  method: "string",
  amount_due: "number",
  fee: "number",
  gross_amount: "number",
  expires_at: "string",
};

const ACTION_TYPES: readonly PayAction["type"][] = ["qr_string", "va_number", "redirect_url"];

function checkFields(value: unknown, fields: Fields, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`pay API: ${path} is not an object`);
  }
  const object = value as Record<string, unknown>;
  for (const [key, expected] of Object.entries(fields)) {
    const actual = object[key];
    const nullable = expected.endsWith("?");
    if (actual === null && nullable) continue;
    if (typeof actual !== expected.replace("?", "")) {
      throw new Error(`pay API: ${path}.${key} should be ${expected}, got ${JSON.stringify(actual)}`);
    }
  }
  return object;
}

function checkList(value: unknown, fields: Fields, path: string): void {
  if (!Array.isArray(value)) throw new Error(`pay API: ${path} is not an array`);
  value.forEach((element, i) => checkFields(element, fields, `${path}.${i}`));
}

/** Validates the body of `POST /api/pay/:token/payment` (or a page's `attempt`) as a `PayAttempt`. */
export function parsePayAttempt(body: unknown, path = "attempt"): PayAttempt {
  const attempt = checkFields(body, ATTEMPT_FIELDS, path);
  const action = checkFields(attempt.action, { type: "string" }, `${path}.action`);
  const type = ACTION_TYPES.find((t) => t === action.type);
  if (!type || typeof action[type] !== "string") {
    throw new Error(`pay API: ${path}.action has no known type and value`);
  }
  return attempt as unknown as PayAttempt;
}

/**
 * Validates the body of `GET /api/pay/:token` as a `PayPage`, so a server shape change fails
 * here with a path instead of rendering `undefined`. Extra keys are ignored.
 */
export function parsePayPage(body: unknown): PayPage {
  const base = checkFields(body, BASE_FIELDS, "page");
  if (base.status === "void") return body as VoidPayPage;
  if (base.status !== "unpaid" && base.status !== "paid" && base.status !== "needs_review") {
    throw new Error(`pay API: page.status is unknown: ${JSON.stringify(base.status)}`);
  }
  const bill = checkFields(body, BILL_FIELDS, "page");
  checkList(bill.lines, LINE_FIELDS, "page.lines");
  checkList(bill.methods, METHOD_FIELDS, "page.methods");
  if (bill.attempt !== null) parsePayAttempt(bill.attempt, "page.attempt");
  return body as BillPayPage;
}
