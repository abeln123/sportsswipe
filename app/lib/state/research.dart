import 'package:flutter_riverpod/flutter_riverpod.dart';

class ResearchRequest extends Notifier<Map<String, dynamic>?> {
  @override
  Map<String, dynamic>? build() => null;
  void ask(Map<String, dynamic> request) => state = request;
  void clear() => state = null;
}

final researchRequestProvider = NotifierProvider<ResearchRequest, Map<String, dynamic>?>(ResearchRequest.new);
