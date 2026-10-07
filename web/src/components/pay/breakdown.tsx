import { formatRupiah } from "@/lib/rupiah";
import type { BillPayPage } from "@/lib/pay-types";

function Row({
  label,
  amount,
  strong = false,
}: {
  label: string;
  amount: string;
  strong?: boolean;
}) {
  return (
    <div
      className={`flex justify-between gap-4 ${strong ? "font-semibold" : ""}`}
    >
      <dt>{label}</dt>
      <dd className="shrink-0 tabular-nums">{amount}</dd>
    </div>
  );
}

/** Per-item breakdown of this person's share, then credit and the total to pay. */
export function Breakdown({ page }: { page: BillPayPage }) {
  return (
    <section aria-labelledby="rincian" className="flex flex-col gap-2">
      <h2 id="rincian" className="font-semibold">
        Rincian
      </h2>
      <dl className="flex flex-col gap-1.5 text-sm">
        {page.lines.map((line, i) => (
          <Row
            key={`${line.category}-${i}`}
            label={line.label ?? line.category}
            amount={formatRupiah(line.amount)}
          />
        ))}
        {page.rounding ? (
          <Row label="Pembulatan" amount={formatRupiah(page.rounding)} />
        ) : null}
        <Row label="Bagianmu" amount={formatRupiah(page.share)} />
        {page.credit_applied > 0 ? (
          <Row
            label="Kredit terpakai"
            amount={`-${formatRupiah(page.credit_applied)}`}
          />
        ) : null}
      </dl>
      <dl className="border-t border-current/20 pt-2 text-base">
        <Row label="Total tagihan" amount={formatRupiah(page.amount_due)} strong />
      </dl>
    </section>
  );
}
