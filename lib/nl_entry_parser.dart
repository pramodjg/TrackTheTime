import 'gemini_nano_service.dart';

class ParsedEntry {
  final DateTime? checkIn;
  final DateTime? checkOut;
  final bool isWorkSession;
  final String? notes;
  final List<String> warnings;

  ParsedEntry({
    this.checkIn,
    this.checkOut,
    required this.isWorkSession,
    this.notes,
    this.warnings = const [],
  });

  bool get isComplete => checkIn != null && checkOut != null;
}

/// Deterministic, offline parser for phrases like:
///   "worked 2 to 4:30 today on the billing module"
///   "break yesterday 1 to 1:30"
///   "9am-5pm client calls"
///   "worked for 2 hours starting at 9 on the invoice bug"
///
/// Designed to be swapped out later for an LLM-backed parser without
/// touching the UI — callers only depend on ParsedEntry, not on how it
/// was produced.
class NaturalLanguageEntryParser {
  static final _weekdays = {
    'monday': DateTime.monday,
    'tuesday': DateTime.tuesday,
    'wednesday': DateTime.wednesday,
    'thursday': DateTime.thursday,
    'friday': DateTime.friday,
    'saturday': DateTime.saturday,
    'sunday': DateTime.sunday,
  };

  static final _rangeRegex = RegExp(
    r'(?:from\s+)?(\d{1,2}(?::\d{2})?\s?(?:am|pm)?)\s*(?:to|-|–|until)\s*(\d{1,2}(?::\d{2})?\s?(?:am|pm)?)',
  );

  static final _durationRegex = RegExp(
    r'(?:for\s+)?(\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h)\b(?:\s+starting\s+(?:at\s+)?(\d{1,2}(?::\d{2})?\s?(?:am|pm)?))?',
  );

  static ParsedEntry parse(String input) {
    final warnings = <String>[];
    String text = ' ${input.trim().toLowerCase()} ';

    // Session type
    final isBreak = ['break', 'lunch', 'coffee'].any((w) => text.contains(w));
    final isWorkSession = !isBreak;

    // Date
    DateTime baseDate = DateTime.now();
    if (text.contains(' yesterday ')) {
      baseDate = baseDate.subtract(const Duration(days: 1));
      text = text.replaceAll('yesterday', ' ');
    } else if (text.contains(' today ')) {
      text = text.replaceAll('today', ' ');
    } else {
      for (final e in _weekdays.entries) {
        if (text.contains(e.key)) {
          final diff = (baseDate.weekday - e.value) % 7;
          baseDate =
              baseDate.subtract(Duration(days: diff < 0 ? diff + 7 : diff));
          text = text.replaceAll(e.key, ' ');
          break;
        }
      }
    }

    // Time range, or duration + optional start time
    DateTime? checkIn;
    DateTime? checkOut;

    final rangeMatch = _rangeRegex.firstMatch(text);
    if (rangeMatch != null) {
      checkIn = _resolveTime(rangeMatch.group(1)!, baseDate);
      checkOut = _resolveTime(rangeMatch.group(2)!, baseDate);
      text = text.replaceRange(rangeMatch.start, rangeMatch.end, ' ');
    } else {
      final durMatch = _durationRegex.firstMatch(text);
      if (durMatch != null) {
        final hours = double.tryParse(durMatch.group(1)!) ?? 0;
        final startStr = durMatch.group(2);
        checkIn = startStr != null
            ? _resolveTime(startStr, baseDate)
            : DateTime.now()
                .subtract(Duration(minutes: (hours * 60).round()));
        checkOut = checkIn.add(Duration(minutes: (hours * 60).round()));
        text = text.replaceRange(durMatch.start, durMatch.end, ' ');
      }
    }

    if (checkIn == null || checkOut == null) {
      warnings.add(
          "Couldn't find a clear time range — fill in check-in/check-out manually.");
    } else if (!checkOut.isAfter(checkIn)) {
      // "2 to 4:30" with no am/pm on either side, both meant afternoon
      checkOut = checkOut.add(const Duration(hours: 12));
      warnings.add('Assumed check-out was PM since it read as before check-in.');
    }

    // Whatever's left after stripping the time/date phrase becomes notes
    final notes = text
        .replaceAll(RegExp(r'\b(on|for|worked|work|break|session)\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return ParsedEntry(
      checkIn: checkIn,
      checkOut: checkOut,
      isWorkSession: isWorkSession,
      notes: notes.isEmpty ? null : notes[0].toUpperCase() + notes.substring(1),
      warnings: warnings,
    );
  }

  static DateTime _resolveTime(String raw, DateTime date) {
    raw = raw.trim();
    final pm = raw.contains('pm');
    final am = raw.contains('am');
    raw = raw.replaceAll(RegExp(r'[ap]m'), '').trim();
    final parts = raw.split(':');
    int hour = int.tryParse(parts[0]) ?? 0;
    final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

    if (pm && hour < 12) hour += 12;
    if (am && hour == 12) hour = 0;
    // No am/pm given and it's a low number typed for manual work entry —
    // "2 to 4:30" almost always means afternoon, not 2am.
    if (!am && !pm && hour > 0 && hour < 7) hour += 12;

    return DateTime(date.year, date.month, date.day, hour, minute);
  }

  /// Tries the fast offline regex parser first. Only reaches for on-device
  /// Gemini Nano (Android only, and only on supported devices) when the
  /// regex parser couldn't find a complete time range — e.g. messier
  /// phrasing like "worked most of the afternoon on the invoice bug".
  /// Falls back to whatever the regex parser produced if AI is unavailable,
  /// times out, or returns something unparseable — this call never throws.
  static Future<ParsedEntry> parseWithAiFallback(String input) async {
    final regexResult = parse(input);
    if (regexResult.isComplete) return regexResult;

    final json = await GeminiNanoService.extractEntryJson(input);
    if (json == null) return regexResult;

    try {
      return ParsedEntry(
        checkIn:
            json['checkInIso'] != null ? DateTime.parse(json['checkInIso']) : null,
        checkOut: json['checkOutIso'] != null
            ? DateTime.parse(json['checkOutIso'])
            : null,
        isWorkSession: json['isWorkSession'] ?? true,
        notes: json['notes'],
        warnings: const [
          'Parsed with on-device AI — please double-check the times.'
        ],
      );
    } catch (_) {
      return regexResult;
    }
  }
}