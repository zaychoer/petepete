import type { Phase } from "@/lib/pay-machine";

const CHIPS: Record<Phase, { icon: string; text: string; tone: string }> = {
  choose: {
    icon: "○",
    text: "Belum bayar",
    tone: "border-amber-600 text-amber-800 dark:text-amber-300",
  },
  awaiting: {
    icon: "◔",
    text: "Menunggu pembayaran",
    tone: "border-amber-600 text-amber-800 dark:text-amber-300",
  },
  expired: {
    icon: "◔",
    text: "Menyiapkan pembayaran baru",
    tone: "border-amber-600 text-amber-800 dark:text-amber-300",
  },
  needs_review: {
    icon: "!",
    text: "Perlu dicek host",
    tone: "border-orange-600 text-orange-800 dark:text-orange-300",
  },
  paid: {
    icon: "✓",
    text: "Lunas",
    tone: "border-green-700 text-green-800 dark:text-green-300",
  },
  void: {
    icon: "✕",
    text: "Tagihan dibatalkan",
    tone: "border-neutral-500 text-neutral-700 dark:text-neutral-300",
  },
  link_expired: {
    icon: "✕",
    text: "Link kedaluwarsa",
    tone: "border-neutral-500 text-neutral-700 dark:text-neutral-300",
  },
};

/** Status is always words first; the icon and border color only add to them. */
export function StatusChip({ phase }: { phase: Phase }) {
  const { icon, text, tone } = CHIPS[phase];
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-sm font-medium ${tone}`}
    >
      <span aria-hidden="true">{icon}</span>
      {text}
    </span>
  );
}
