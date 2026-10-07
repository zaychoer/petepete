import { createFileRoute } from "@tanstack/react-router";
import { createServerFn } from "@tanstack/react-start";
import { ApiError, apiFetch } from "@/lib/api";
import { JoinForm } from "@/components/join-form";

const fetchInvite = createServerFn({ method: "GET" })
  .validator((token: string) => token)
  .handler(async ({ data: token }) => {
    type LoaderResult =
      | { kind: "ok"; groupName: string }
      | { kind: "not_found"; message: string };

    try {
      const { group_name } = await apiFetch<{ group_name: string }>(
        `/api/invites/${encodeURIComponent(token)}`,
      );
      return { kind: "ok", groupName: group_name } as LoaderResult;
    } catch (error) {
      if (error instanceof ApiError && error.code === "invite_not_found") {
        return { kind: "not_found", message: error.message } as LoaderResult;
      }
      throw error;
    }
  });

export const Route = createFileRoute("/join/$token")({
  head: () => ({
    meta: [
      { title: "Gabung grup · Petepete" },
      { name: "robots", content: "noindex, nofollow" },
      { name: "referrer", content: "no-referrer" },
    ],
  }),
  loader: ({ params }) => fetchInvite({ data: params.token }),
  component: JoinRoute,
});

function JoinRoute() {
  const result = Route.useLoaderData();
  const { token } = Route.useParams();

  if (result.kind === "not_found") {
    return (
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col justify-center gap-2 p-6">
        <p role="alert" className="text-lg font-semibold">
          {result.message}
        </p>
      </main>
    );
  }

  return (
    <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-5 p-6">
      <JoinForm token={token} groupName={result.groupName} />
    </main>
  );
}
