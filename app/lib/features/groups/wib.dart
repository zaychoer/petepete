const _days = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'Mei',
  'Jun',
  'Jul',
  'Agu',
  'Sep',
  'Okt',
  'Nov',
  'Des', //
];

/// Wall-clock time in WIB (UTC+7) of an API timestamp, as a plain [DateTime] whose
/// fields are the WIB fields.
DateTime toWib(String isoUtc) =>
    DateTime.parse(isoUtc).toUtc().add(const Duration(hours: 7));

String _two(int n) => n.toString().padLeft(2, '0');

/// `Kamis, 8 Okt 2026 · 19:00 WIB` from an API timestamp.
String formatSessionTime(String isoUtc) {
  final t = toWib(isoUtc);
  return '${_days[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} ${t.year}'
      ' · ${_two(t.hour)}:${_two(t.minute)} WIB';
}

/// `Kamis, 8 Okt 2026` from a calendar date.
String formatDate(DateTime date) =>
    '${_days[date.weekday - 1]}, ${date.day} ${_months[date.month - 1]} ${date.year}';

/// `19:30`.
String formatClock(int hour, int minute) => '${_two(hour)}:${_two(minute)}';

/// The ISO 8601 timestamp with the WIB offset the events API wants, e.g.
/// `2026-10-08T19:00:00+07:00`.
String wibIso(DateTime date, int hour, int minute) =>
    '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}'
    'T${_two(hour)}:${_two(minute)}:00+07:00';
