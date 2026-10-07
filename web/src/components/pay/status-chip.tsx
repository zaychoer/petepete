import type { Phase } from "@/lib/pay-machine";

const CHIPS: Record<Phase, { icon: string; tone: string }> = {
  choose: {
    icon: "○",
    tone: "border-amber-600 text-amber-800 dark:text-amber-300",
  },
  awaiting: {
    icon: "◔",
    tone: "border-amber-600 text-amber-800 dark:text-amber-300",
  },
  expired: {
    icon: "◔",
    tone: "border-amber-600 text-amber-800 dark:text-amber-300",
  },
  needs_review: {
    icon: "!",
    tone: "border-orange-600 text-orange-800 dark:text-orange-300",
  },
  paid: {
    icon: "✓",
    tone: "border-green-700 text-green-800 dark:text-green-300",
  },
  void: {
    icon: "✕",
    tone: "border-neutral-500 text-neutral-700 dark:text-neutral-300",
  },
  link_expired: {
    icon: "✕",
    tone: "border-neutral-500 text-neutral-700 dark:text-neutral-300",
  },
};

/**
 * Status is always words first; the icon and border color only add to them. The words are the
 * server's `status_label`, only the icon and tone live here.
 */
export function StatusChip({ phase, label }: { phase: Phase; label: string }) {
  const { icon, tone } = CHIPS[phase];
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-sm font-medium ${tone}`}
    >
      <span aria-hidden="true">{icon}</span>
      {label}
    </span>
  );
}
