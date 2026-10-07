/// Formats whole rupiah as `Rp45.000` (dot thousands separators, no decimals).
///
/// Money is integer rupiah everywhere, so this takes an `int`; negatives read
/// `-Rp45.000`.
String formatRupiah(int amount) {
  final digits = amount.toString().replaceFirst('-', '');
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write('.');
    grouped.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}Rp$grouped';
}
