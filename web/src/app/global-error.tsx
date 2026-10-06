"use client";

import * as Sentry from "@sentry/nextjs";
import { useEffect } from "react";

export default function GlobalError({
  error,
}: {
  error: Error & { digest?: string };
}) {
  useEffect(() => {
    Sentry.captureException(error);
  }, [error]);

  return (
    <html lang="id">
      <body>
        <main className="mx-auto flex min-h-screen max-w-md flex-col justify-center gap-2 p-6">
          <h1 className="text-2xl font-semibold">Ada yang error</h1>
          <p>Maaf, halaman ini gagal dimuat. Coba muat ulang ya.</p>
        </main>
      </body>
    </html>
  );
}
