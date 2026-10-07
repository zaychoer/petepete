import { useState } from "react";

export function CopyButton({ value, label }: { value: string; label: string }) {
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");

  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setState("copied");
    } catch {
      setState("failed");
    }
  }

  return (
    <span className="flex flex-col items-start gap-1">
      <button
        type="button"
        onClick={copy}
        className="rounded-lg border border-current px-4 py-2 text-sm font-medium"
      >
        {label}
      </button>
      <span role="status" className="min-h-5 text-sm">
        {state === "copied" && "Tersalin!"}
        {state === "failed" && "Gagal menyalin. Salin manual ya."}
      </span>
    </span>
  );
}
