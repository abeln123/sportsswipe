import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final file = File('build/pack_performance.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    if (data != null) {
      for (final entry in data.entries) {
        if (entry.value is Map) {
          final metrics = Map.fromEntries((entry.value as Map).entries.where((e) => e.value is num));
          stdout.writeln('PACK_PERFORMANCE ${entry.key}: ${jsonEncode(metrics)}');
        }
      }
    }
  },
);
