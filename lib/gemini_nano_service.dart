import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:gemini_nano_android/gemini_nano_android.dart';

/// Thin wrapper around the gemini_nano_android plugin. Isolates the rest of
/// the app from the plugin's API and from platform quirks — Gemini Nano via
/// AICore only exists on Android, and only on a subset of devices even
/// there, so every entry point here fails soft (returns false/null) rather
/// than throwing. Callers should always be prepared to fall back to the
/// offline regex parser.
///
/// NOTE: this file was reconstructed to add device-support validation —
/// diff it against your existing gemini_nano_service.dart and keep whatever
/// you already had beyond isAvailable()/extractEntryJson() if it differs.
class GeminiNanoService {
  static final GeminiNanoAndroid _gemini = GeminiNanoAndroid();

  // Cached after the first check — availability is a property of the
  // device/OS install, not something that changes mid-session, and the
  // underlying check involves a platform channel round-trip we don't want
  // to repeat on every auto-fill tap.
  static bool? _availableCache;

  /// True only on Android, and only when AICore reports Gemini Nano as
  /// installed and usable on this specific device. Never throws — any
  /// platform-channel error is treated as "not available".
  static Future<bool> isAvailable() async {
    if (_availableCache != null) return _availableCache!;

    if (kIsWeb || !Platform.isAndroid) {
      _availableCache = false;
      return false;
    }

    try {
      _availableCache = await _gemini.isAvailable();
    } catch (e, st) {
      debugPrint('Gemini Nano availability check failed: $e\n$st');
      _availableCache = false;
    }
    return _availableCache!;
  }

  /// Clears the cached availability result so the next [isAvailable] call
  /// re-checks the device — e.g. call this after the user installs the
  /// AICore module and returns to the app, or after an app resume.
  static void resetAvailabilityCache() {
    _availableCache = null;
  }

  /// Asks Gemini Nano to turn a free-text time-entry description into
  /// structured JSON. Returns null (never throws) if the model is
  /// unavailable, the request fails, or the response isn't valid JSON —
  /// callers are expected to fall back to the regex parser in that case.
  static Future<Map<String, dynamic>?> extractEntryJson(String input) async {
    if (!await isAvailable()) return null;

    final prompt = '''
Extract a work/break time entry from the text below. Respond with ONLY a
JSON object, no other words, no markdown fences, in this exact shape:
{"checkInIso": "<ISO-8601 datetime or null>", "checkOutIso": "<ISO-8601 datetime or null>", "isWorkSession": true|false, "notes": "<short string or null>"}

Current date/time (use this to resolve relative times like "today" or "2pm"): ${DateTime.now().toIso8601String()}

Text: "$input"
''';

    try {
      final results = await _gemini.generate(
        prompt: prompt,
        temperature: 0.1,
        candidateCount: 1,
      );
      if (results.isEmpty) return null;

      var raw = results.first.trim();
      // Models sometimes wrap JSON in markdown fences despite instructions
      // not to — strip those before decoding.
      raw = raw.replaceAll(RegExp(r'^```json|^```|```$', multiLine: true), '').trim();

      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e, st) {
      debugPrint('Gemini Nano extraction failed: $e\n$st');
      return null;
    }
  }
}