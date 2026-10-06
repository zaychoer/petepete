import type { NextConfig } from "next";
import { withSentryConfig } from "@sentry/nextjs/config";

const nextConfig: NextConfig = {
  /* config options here */
};

// Source map upload only runs when SENTRY_AUTH_TOKEN, org and project are set in CI.
export default withSentryConfig(nextConfig, {
  silent: !process.env.CI,
  telemetry: false,
});
