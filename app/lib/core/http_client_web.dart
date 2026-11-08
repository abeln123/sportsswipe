import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// Sends the httpOnly session cookie, including when the API runs on a
/// different origin during development.
http.Client createHttpClient() => BrowserClient()..withCredentials = true;
