import { createFileRoute } from "@tanstack/react-router";
import { createServerFn } from "@tanstack/react-start";
import { ApiError, apiFetch } from "@/lib/api";
import { parsePayPage, type PayPage } from "@/lib/pay-types";
import { PayView } from "@/components/pay/pay-view";

const fetchPayPage = createServerFn({ method: "GET" })
  .validator((token: string) => token)
  .handler(async ({ data: token }) => {
    type LoaderResult =
      | { kind: "ok"; page: PayPage }
      | { kind: "not_found" }
      | { kind: "error"; message: string };

    try {
      const page = parsePayPage(
        await apiFetch<unknown>(`/api/pay/${encodeURIComponent(token)}`),
      );
      return { kind: "ok", page } as LoaderResult;
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        return { kind: "not_found" } as LoaderResult;
      }
      throw error;
    }
  });

export const Route = createFileRoute("/pay/$token")({
  head: () => ({
    meta: [
      { title: "Bayar patungan · Petepete" },
      { name: "robots", content: "noindex, nofollow" },
      { name: "referrer", content: "no-referrer" },
    ],
  }),
  loader: ({ params }) => fetchPayPage({ data: params.token }),
  component: PayRoute,
});

function PayRoute() {
  const result = Route.useLoaderData();
  const { token } = Route.useParams();

  if (result.kind === "not_found") {
    return (
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col justify-center gap-2 p-6">
        <h1 className="text-2xl font-semibold">Link bayar nggak ketemu</h1>
        <p>Cek lagi link dari host grupmu, atau minta dikirim ulang.</p>
      </main>
    );
  }

  return (
    <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-5 p-6">
      <PayView token={token} initialPage={result.page} />
    </main>
  );
}
