import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { ApiError, apiFetch } from "@/lib/api";
import { JoinForm } from "./join-form";

// The invite token is a credential: keep it out of search results and Referer headers.
export const metadata: Metadata = {
  title: "Gabung grup · Petepete",
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

export default async function JoinRoute({ params }: PageProps<"/join/[token]">) {
  const { token } = await params;

  let groupName: string;
  try {
    ({ group_name: groupName } = await apiFetch<{ group_name: string }>(
      `/api/invites/${encodeURIComponent(token)}`,
    ));
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }

  return (
    <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-5 p-6">
      <JoinForm token={token} groupName={groupName} />
    </main>
  );
}
