import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:gemini_nano_android/gemini_nano_android.dart';

/// Wraps on-device Gemini Nano behind a small interface so the rest of the
/// app never depends on the underlying package directly. If you later add
/// flutter_local_ai for iOS/Windows coverage, only this file needs to change.
class GeminiNanoService {
  static final GeminiNanoAndroid _gemini = GeminiNanoAndroid();
  static bool? _availableCache;

  /// True only on Android — this backend has no iOS/Windows implementation.
  static bool get _isSupportedPlatform => !kIsWeb && Platform.isAndroid;

  /// Checks device support once per app session. Cheap to call repeatedly
  /// after the first check since the result is cached.
  static Future<bool> isAvailable() async {
    if (!_isSupportedPlatform) return false;
    if (_availableCache != null) return _availableCache!;
    try {
      // gemini_nano_android has no explicit isAvailable() call at the time
      // of writing — availability is discovered by attempting a cheap
      // generation and catching failure. Adjust this if a future version
      // adds a dedicated capability check.
      final result = await _gemini.generate(prompt: 'ok', temperature: 0.0)
          .timeout(const Duration(seconds: 5));
      _availableCache = result.isNotEmpty;
    } catch (_) {
      _availableCache = false;
    }
    return _availableCache!;
  }

  /// Asks the on-device model to extract a structured time entry from free
  /// text, returning null on any failure (unsupported device, model still
  /// downloading, malformed response) so callers can fall back to the
  /// offline regex parser without special-casing errors.
  static Future<Map<String, dynamic>?> extractEntryJson(String text) async {
    if (!await isAvailable()) return null;

    final prompt = '''
Extract a work-log entry from this text. Respond with ONLY raw JSON, no
markdown fences, no explanation. Use this exact shape:
{"checkInIso": "<ISO8601 or null>", "checkOutIso": "<ISO8601 or null>", "isWorkSession": true|false, "notes": "<short string or null>"}
Assume today's date is ${DateTime.now().toIso8601String().substring(0, 10)}
if no date is mentioned. Text: "$text"
''';

    try {
      final results = await _gemini
          .generate(prompt: prompt, temperature: 0.1)
          .timeout(const Duration(seconds: 8));
      if (results.isEmpty) return null;

      final raw = results.first.trim();
      final cleaned = raw.replaceAll(RegExp(r'```json|```'), '').trim();
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      // Model unavailable, timed out, or returned non-JSON — caller falls
      // back to the offline parser. Never surface this as a user-facing
      // error since the regex path is always a safe fallback.
      return null;
    }
  }
}