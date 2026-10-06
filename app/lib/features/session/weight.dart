/// Weights are integer per mil: 1000 = 1×, 1200 = 1,2×, 500 = 0,5×.
///
/// The server rejects anything that is not a positive integer, and so does
/// [parseWeight]: the app never sends a float.
String formatWeight(int perMil) {
  final whole = perMil ~/ 1000;
  final rest = perMil % 1000;
  if (rest == 0) return '$whole×';
  var decimals = rest.toString().padLeft(3, '0');
  decimals = decimals.replaceFirst(RegExp(r'0+$'), '');
  return '$whole,$decimals×';
}

/// Reads what the host typed ("1,2", "0.5", "2") as per mil, or null when it is
/// not a positive number with at most three decimals.
int? parseWeight(String input) {
  final match = RegExp(
    r'^(\d{1,3})(?:[.,](\d{1,3}))?$',
  ).firstMatch(input.trim());
  if (match == null) return null;
  final whole = int.parse(match.group(1)!);
  final decimals = (match.group(2) ?? '').padRight(3, '0');
  final perMil = whole * 1000 + int.parse(decimals.isEmpty ? '0' : decimals);
  return perMil > 0 && perMil <= 100000 ? perMil : null;
}
