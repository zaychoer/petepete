/**
 * The https invite link that opens the Petepete app (Android App Links) on the invite,
 * with the member entry just created so the app can claim it. Without the app it simply
 * lands back on this join page.
 */
export function appInviteUrl(baseUrl: string, token: string, memberId: number): string {
  const base = baseUrl.replace(/\/+$/, "");
  return `${base}/join/${encodeURIComponent(token)}?claim=${encodeURIComponent(String(memberId))}`;
}
