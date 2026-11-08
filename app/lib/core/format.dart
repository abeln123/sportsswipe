import 'package:intl/intl.dart';

final _int = NumberFormat.decimalPattern('en_US');

String coins(num n) => _int.format(n);

String line(num v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String signed(num n) => n > 0 ? '+${coins(n)}' : n < 0 ? '−${coins(n.abs())}' : '0';

String time(DateTime d) => DateFormat('h:mm a').format(d.toLocal());

String dayTime(DateTime d) => DateFormat('EEE h:mm a').format(d.toLocal());

String shortDate(DateTime d) => DateFormat('MMM d').format(d.toLocal());

String two(int? n) => (n ?? 0).toString().padLeft(2, '0');

String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

DateTime? parseTime(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());
