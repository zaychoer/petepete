/** Integer rupiah as "Rp12.500". Money is never a float: a non-integer is a bug. */
export function formatRupiah(amount: number): string {
  if (!Number.isSafeInteger(amount)) {
    throw new RangeError(`rupiah must be a safe integer, got ${amount}`);
  }
  const digits = Math.abs(amount)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return `${amount < 0 ? "-" : ""}Rp${digits}`;
}
