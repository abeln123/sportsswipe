import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'http_client.dart';

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, [this.body]);
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? body;
  bool get isNetwork => status == 0;
  @override
  String toString() => message;
}

class ApiResponse {
  ApiResponse(this.status, this.body);
  final int status;
  final dynamic body;
  bool get ok => status >= 200 && status < 300;
  Map<String, dynamic> get map => (body as Map?)?.cast<String, dynamic>() ?? {};
}

/// Thin JSON client for the Rust API. On the web the session lives in an
/// httpOnly cookie; native builds send it as a bearer token.
class Api {
  Api({String? base}) : base = base ?? _defaultBase();

  final String base;
  final http.Client _client = createHttpClient();
  String? _token;

  static String _defaultBase() {
    const fromEnv = String.fromEnvironment('API_BASE');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (kIsWeb) return Uri.base.origin;
    return 'http://localhost:8080';
  }

  static const _tokenKey = 'ss.session';

  Future<void> loadToken() async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
  }

  Future<void> setToken(String? token) async {
    _warm.clear();
    if (kIsWeb) return;
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    if (token == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, token);
    }
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  /// Returns the raw status and body. Network failures become status 0.
  Future<ApiResponse> raw(String method, String path, {Object? body, Duration timeout = const Duration(seconds: 12)}) async {
    final uri = Uri.parse('$base/v1$path');
    if (method != 'GET') _warm.clear();
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      final streamed = await _client.send(req).timeout(timeout);
      final res = await http.Response.fromStream(streamed);
      final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
      return ApiResponse(res.statusCode, decoded);
    } on TimeoutException {
      return ApiResponse(0, {'code': 'timeout', 'message': 'Checking status…'});
    } catch (_) {
      return ApiResponse(0, {'code': 'network', 'message': 'You appear to be offline.'});
    }
  }

  Future<Map<String, dynamic>> json(String method, String path, {Object? body}) async {
    final r = await raw(method, path, body: body);
    if (r.ok) return r.map;
    final m = r.map;
    throw ApiException(r.status, m['code']?.toString() ?? 'error', m['message']?.toString() ?? 'Something went wrong.', m);
  }

  final Map<String, (DateTime, Future<ApiResponse>)> _warm = {};

  /// Starts a GET in the background; the next [get] of the same path within
  /// a minute reuses it instead of hitting the network again.
  void prefetch(String path) {
    _warm[path] = (DateTime.now(), raw('GET', path));
  }

  Future<Map<String, dynamic>> get(String path) async {
    final hit = _warm.remove(path);
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(seconds: 60)) {
      final r = await hit.$2;
      if (r.ok) return r.map;
    }
    return json('GET', path);
  }
  Future<Map<String, dynamic>> post(String path, [Object? body]) => json('POST', path, body: body ?? {});
  Future<Map<String, dynamic>> patch(String path, Object body) => json('PATCH', path, body: body);
}

final api = Api();
