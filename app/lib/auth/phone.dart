/// Normalises an Indonesian mobile number to the `62…` form the API stores.
///
/// Same rules as `Petepete.Accounts.normalize_phone/1`: accepts `08xx`, `+62 8xx`
/// and `628xx`, with spaces, dashes, dots or parentheses. Returns null when the
/// number is not a valid Indonesian mobile number. The server re-checks; this only
/// lets the screen hint early.
String? normalizePhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[\s\-.()]'), '');
  final normalized = switch (digits) {
    final d when d.startsWith('+') => d.substring(1),
    final d when d.startsWith('0') => '62${d.substring(1)}',
    final d => d,
  };
  return RegExp(r'^628\d{7,11}$').hasMatch(normalized) ? normalized : null;
}

/// `6281234567890` -> `+62 812-3456-7890`, for showing the user where the code goes.
String formatPhoneForDisplay(String normalized) {
  final local = normalized.startsWith('62')
      ? normalized.substring(2)
      : normalized;
  final groups = <String>[];
  var rest = local;
  for (final size in const [3, 4]) {
    if (rest.length <= size) break;
    groups.add(rest.substring(0, size));
    rest = rest.substring(size);
  }
  groups.add(rest);
  return '+62 ${groups.join('-')}';
}
