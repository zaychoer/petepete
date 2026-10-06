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
}

export type PayPage = VoidPayPage | BillPayPage;
