import * as Sentry from "@sentry/nextjs";

// Sends one test error to Sentry so a human can check the layer tag and masking.
// Answers 404 unless SENTRY_TEST_TOKEN is set and matches ?token=.
export async function GET(request: Request) {
  const token = process.env.SENTRY_TEST_TOKEN;
  const given = new URL(request.url).searchParams.get("token");
  if (!token || given !== token) {
    return new Response("Not found", { status: 404 });
  }

  Sentry.captureException(new Error("Sentry test event (web) 081234567890"));
  await Sentry.flush(2000);
  return Response.json({ sent: true });
}
