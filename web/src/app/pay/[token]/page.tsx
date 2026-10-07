import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { ApiError, apiFetch } from "@/lib/api";
import type { PayPage } from "@/lib/pay-types";
import { PayView } from "./pay-view";

// The link is the credential: keep it out of search results and Referer headers.
export const metadata: Metadata = {
  title: "Bayar patungan · Petepete",
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

export default async function PayRoute({ params }: PageProps<"/pay/[token]">) {
  const { token } = await params;

  let initialPage: PayPage;
  try {
    initialPage = await apiFetch<PayPage>(`/api/pay/${encodeURIComponent(token)}`);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }

  return (
    <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-5 p-6">
      <PayView token={token} initialPage={initialPage} />
    </main>
  );
}
