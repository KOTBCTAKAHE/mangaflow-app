/// Russian-friendly formatting helpers (no intl dependency).
library;

const _months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];

String formatDate(DateTime d, {DateTime? now}) {
  final l = d.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(l.year, l.month, l.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'сегодня';
  if (diff == 1) return 'вчера';
  if (diff > 1 && diff < 7) return '$diff ${plural(diff, 'день', 'дня', 'дней')} назад';
  final y = l.year == n.year ? '' : ' ${l.year}';
  return '${l.day} ${_months[l.month - 1]}$y';
}

String formatDateTime(DateTime d, {DateTime? now}) {
  final l = d.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${formatDate(d, now: now)}, $hh:$mm';
}

String formatDuration(int seconds) {
  if (seconds < 60) return '$seconds с';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h == 0) return '$m мин';
  return m == 0 ? '$h ч' : '$h ч $m мин';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  const units = ['КБ', 'МБ', 'ГБ'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// Russian plural: plural(5, 'глава', 'главы', 'глав') → 'глав'.
String plural(int n, String one, String few, String many) {
  final mod10 = n % 10, mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}
