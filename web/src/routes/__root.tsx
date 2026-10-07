import {
  HeadContent,
  Outlet,
  Scripts,
  createRootRoute,
} from "@tanstack/react-router";
import * as Sentry from "@sentry/tanstackstart-react";
import { useEffect } from "react";
import appCss from "@/styles/globals.css?url";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Petepete" },
      {
        name: "description",
        content: "Bayar patungan grup olahraga tanpa install aplikasi.",
      },
    ],
    links: [{ rel: "stylesheet", href: appCss }],
  }),
  component: RootComponent,
  errorComponent: RootErrorComponent,
});

function RootComponent() {
  return (
    <html lang="id" className="h-full antialiased">
      <head>
        <HeadContent />
      </head>
      <body className="min-h-full flex flex-col font-sans">
        <Outlet />
        <Scripts />
      </body>
    </html>
  );
}

function RootErrorComponent({ error }: { error: Error }) {
  useEffect(() => {
    Sentry.captureException(error);
  }, [error]);

  return (
    <html lang="id">
      <head>
        <HeadContent />
      </head>
      <body>
        <main className="mx-auto flex min-h-screen max-w-md flex-col justify-center gap-2 p-6">
          <h1 className="text-2xl font-semibold">Ada yang error</h1>
          <p>Maaf, halaman ini gagal dimuat. Coba muat ulang ya.</p>
        </main>
        <Scripts />
      </body>
    </html>
  );
}
