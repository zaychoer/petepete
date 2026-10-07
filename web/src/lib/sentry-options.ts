import type { Breadcrumb, ErrorEvent, Log, Metric } from "@sentry/core";
import { scrub } from "./sentry-scrub";

// Shared by the client and server Sentry.init calls.
// VITE_SENTRY_DSN is inlined at build time; unset or blank disables Sentry.
export const sentryOptions = {
  dsn: (import.meta.env.VITE_SENTRY_DSN as string | undefined)?.trim() || undefined,
  environment: import.meta.env.MODE === "production" ? "production" : "development",
  dataCollection: { userInfo: false },
  beforeSend: (event: ErrorEvent): ErrorEvent =>
    scrub({ ...event, tags: { ...event.tags, layer: "web" } }),
  beforeBreadcrumb: (breadcrumb: Breadcrumb): Breadcrumb => scrub(breadcrumb),
  beforeSendLog: (log: Log): Log => scrub(log),
  beforeSendMetric: (metric: Metric): Metric => scrub(metric),
};
