import { encode } from "uqr";

const QUIET_ZONE = 4;

/**
 * The QRIS payload drawn as an inline SVG: one path, black on a white square so it scans in
 * dark mode too. Rendered on the server as well, so there is no flash.
 */
export function QrCode({ value }: { value: string }) {
  let rows: boolean[][];
  try {
    rows = encode(value, { ecc: "M", border: 0 }).data;
  } catch {
    return (
      <p role="alert" className="text-sm">
        Kode QR tidak bisa ditampilkan. Muat ulang halaman ini ya.
      </p>
    );
  }

  const size = rows.length;
  let path = "";
  rows.forEach((row, y) => {
    let x = 0;
    while (x < size) {
      if (!row[x]) {
        x += 1;
        continue;
      }
      const start = x;
      while (x < size && row[x]) x += 1;
      path += `M${start} ${y}h${x - start}v1h-${x - start}z`;
    }
  });

  const total = size + QUIET_ZONE * 2;
  return (
    <svg
      role="img"
      aria-label="Kode QRIS untuk dipindai"
      viewBox={`${-QUIET_ZONE} ${-QUIET_ZONE} ${total} ${total}`}
      shapeRendering="crispEdges"
      className="h-auto w-full max-w-64 rounded-lg bg-white"
    >
      <rect
        x={-QUIET_ZONE}
        y={-QUIET_ZONE}
        width={total}
        height={total}
        fill="#ffffff"
      />
      <path d={path} fill="#000000" />
    </svg>
  );
}
