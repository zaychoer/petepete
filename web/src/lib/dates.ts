/**
 * Indonesian date/time text. Done by hand (no Intl) so the server and the browser print the
 * same string and hydration never mismatches. Times are shown in WIB (UTC+7), the
 * time zone of every session.
 */

const DAYS = ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"];
const MONTHS = [
  "Januari",
  "Februari",
  "Maret",
  "April",
  "Mei",
  "Juni",
  "Juli",
  "Agustus",
  "September",
  "Oktober",
  "November",
  "Desember",
];
const WIB_OFFSET_MS = 7 * 60 * 60 * 1000;

const pad = (n: number) => n.toString().padStart(2, "0");

/** "2026-10-08" -> "Kamis, 8 Oktober 2026". Unparseable input is returned as is. */
export function formatSessionDate(isoDate: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  if (!match) return isoDate;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const date = new Date(Date.UTC(year, month - 1, day));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    return isoDate;
  }
  return `${DAYS[date.getUTCDay()]}, ${day} ${MONTHS[month - 1]} ${year}`;
}

function wib(iso: string): Date | null {
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : new Date(ms + WIB_OFFSET_MS);
}

/** An instant -> "19.30 WIB". */
export function formatWibTime(iso: string): string {
  const d = wib(iso);
  return d ? `${pad(d.getUTCHours())}.${pad(d.getUTCMinutes())} WIB` : iso;
}

/** An instant -> "8 Oktober 2026, 19.30 WIB". */
export function formatWibDateTime(iso: string): string {
  const d = wib(iso);
  if (!d) return iso;
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}, ${formatWibTime(iso)}`;
}
