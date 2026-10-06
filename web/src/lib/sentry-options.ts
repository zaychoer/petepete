import type { Breadcrumb, ErrorEvent, Log, Metric } from "@sentry/nextjs";
import { scrub } from "./sentry-scrub";

// Shared by the client, server and edge Sentry.init calls.
// NEXT_PUBLIC_SENTRY_DSN is inlined at build time; unset or blank disables Sentry.
export const sentryOptions = {
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN?.trim() || undefined,
  environment:
    process.env.NEXT_PUBLIC_VERCEL_ENV ?? process.env.NODE_ENV ?? "production",
  dataCollection: { userInfo: false },
  beforeSend: (event: ErrorEvent): ErrorEvent =>
    scrub({ ...event, tags: { ...event.tags, layer: "web" } }),
  beforeBreadcrumb: (breadcrumb: Breadcrumb): Breadcrumb => scrub(breadcrumb),
  beforeSendLog: (log: Log): Log => scrub(log),
  beforeSendMetric: (metric: Metric): Metric => scrub(metric),
};
