import 'dart:math' as math;
import 'package:path/path.dart';
//import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';

class TimeEntry {
  DateTime checkIn;
  DateTime? checkOut;
  String? notes;
  bool isWorkSession;
  bool wasAutoConverted;

  TimeEntry({
    required this.checkIn,
    this.checkOut,
    this.notes,
    this.isWorkSession = true,
    this.wasAutoConverted = false,
  });

  Duration get duration {
    if (checkOut == null) return Duration.zero;
    return checkOut!.difference(checkIn);
  }

  String get durationString {
    if (checkOut == null) return 'In progress';
    final d = duration;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    return '${hours}h ${minutes}m';
  }

  String get sessionLabel => isWorkSession ? 'Work' : 'Break';

  Map<String, dynamic> toJson() => {
        'checkIn': checkIn.toIso8601String(),
        'checkOut': checkOut?.toIso8601String(),
        'notes': notes,
        'isWorkSession': isWorkSession,
        'wasAutoConverted': wasAutoConverted,
      };

  factory TimeEntry.fromJson(Map<String, dynamic> json) => TimeEntry(
        checkIn: DateTime.parse(json['checkIn']),
        checkOut:
            json['checkOut'] != null ? DateTime.parse(json['checkOut']) : null,
        notes: json['notes'],
        isWorkSession: json['isWorkSession'] ?? true,
        wasAutoConverted: json['wasAutoConverted'] ?? false,
      );
}

// Helper class to pair entry with its database ID
class EntryWithId {
  final int id;
  final TimeEntry entry;

  EntryWithId(this.id, this.entry);
}

extension TimeEntryDb on TimeEntry {
  Map<String, dynamic> toDb() => {
        'checkIn': checkIn.toIso8601String(),
        'checkOut': checkOut?.toIso8601String(),
        'notes': notes,
        'isWorkSession': isWorkSession ? 1 : 0,
        'wasAutoConverted': wasAutoConverted ? 1 : 0,
      };

  static TimeEntry fromDb(Map<String, dynamic> map) => TimeEntry(
        checkIn: DateTime.parse(map['checkIn'] as String),
        checkOut: map['checkOut'] != null
            ? DateTime.parse(map['checkOut'] as String)
            : null,
        notes: map['notes'] as String?,
        isWorkSession: (map['isWorkSession'] as int) == 1,
        wasAutoConverted: (map['wasAutoConverted'] as int) == 1,
      );
}

// ---------------------------------------------------------------------------
// Anomaly detection support
// ---------------------------------------------------------------------------

enum AnomalyType {
  forgottenCheckout,
  unusuallyShort,
  overlapping,
  overnightSpan,
}

class SessionAnomaly {
  final int entryId;
  final AnomalyType type;
  final String message;
  final DateTime checkIn;

  SessionAnomaly({
    required this.entryId,
    required this.type,
    required this.message,
    required this.checkIn,
  });
}

class SessionStats {
  final double meanSeconds;
  final double stdDevSeconds;
  SessionStats(this.meanSeconds, this.stdDevSeconds);
}

class TimeDb {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'office_time_tracker.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE time_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            checkIn TEXT NOT NULL,
            checkOut TEXT,
            notes TEXT,
            isWorkSession INTEGER NOT NULL,
            wasAutoConverted INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  static Future<List<TimeEntry>> getAllEntries() async {
    final db = await database;
    final maps = await db.query(
      'time_entries',
      orderBy: 'checkIn DESC',
    );
    return maps.map(TimeEntryDb.fromDb).toList();
  }

  // Get entries with their database IDs
  static Future<List<EntryWithId>> getAllEntriesWithIds() async {
    final db = await database;
    final maps = await db.query(
      'time_entries',
      orderBy: 'checkIn DESC',
    );
    return maps.map((map) {
      final id = map['id'] as int;
      final entry = TimeEntryDb.fromDb(map);
      return EntryWithId(id, entry);
    }).toList();
  }

  static Future<int> insertEntry(TimeEntry entry) async {
    final db = await database;
    return db.insert('time_entries', entry.toDb());
  }

  static Future<int> updateEntry(TimeEntry entry, int id) async {
    final db = await database;
    return db.update(
      'time_entries',
      entry.toDb(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<int> deleteEntry(int id) async {
    final db = await database;
    return db.delete('time_entries', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> clearAll() async {
    final db = await database;
    await db.delete('time_entries');
  }

  /// Returns work seconds per day as {'2026-07-01': 28800, ...},
  /// only counting completed work sessions within the given range (inclusive).
  static Future<Map<String, int>> getDailyWorkSeconds({
    required DateTime from,
    required DateTime to,
  }) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT 
        date(checkIn) as day,
        SUM(
          (julianday(checkOut) - julianday(checkIn)) * 86400
        ) as totalSeconds
      FROM time_entries
      WHERE checkOut IS NOT NULL 
        AND isWorkSession = 1
        AND date(checkIn) >= date(?)
        AND date(checkIn) <= date(?)
      GROUP BY day
      ORDER BY day
    ''', [from.toIso8601String(), to.toIso8601String()]);

    return {
      for (final row in result)
        row['day'] as String: (row['totalSeconds'] as num).round()
    };
  }

  /// Convenience wrapper for a specific calendar month (1-12).
  static Future<Map<String, int>> getMonthlyWorkSeconds(int year, int month) {
    final from = DateTime(year, month, 1);
    final to = DateTime(year, month + 1, 0); // last day of month
    return getDailyWorkSeconds(from: from, to: to);
  }

  /// Mean + standard deviation of *your own* historical completed session
  /// durations, split by session type. Used so "unusually long" is judged
  /// relative to your own habits rather than an arbitrary fixed number.
  static Future<SessionStats> getSessionStats(bool isWorkSession) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT
        AVG((julianday(checkOut) - julianday(checkIn)) * 86400) as mean,
        AVG(((julianday(checkOut) - julianday(checkIn)) * 86400) *
            ((julianday(checkOut) - julianday(checkIn)) * 86400)) as meanSq
      FROM time_entries
      WHERE checkOut IS NOT NULL AND isWorkSession = ?
    ''', [isWorkSession ? 1 : 0]);

    final mean = (result.first['mean'] as num?)?.toDouble() ?? 0.0;
    final meanSq = (result.first['meanSq'] as num?)?.toDouble() ?? 0.0;
    final variance = meanSq - (mean * mean);
    final stdDev = variance > 0 ? math.sqrt(variance) : 0.0;
    return SessionStats(mean, stdDev);
  }

  /// Scans all entries with IDs and flags likely mistakes:
  /// - forgotten checkouts (session far longer than your own historical norm)
  /// - unusually short sessions (< 10s — catches manual/synced entries the
  ///   live check-out guard in the UI doesn't see)
  /// - overlapping entries
  /// - sessions that span midnight
  ///
  /// Thresholds are deliberately conservative starting points; tune the
  /// multiplier and floor below once you've seen what a week of real data
  /// flags.
  static Future<List<SessionAnomaly>> detectAnomalies(
    List<EntryWithId> entries,
  ) async {
    final anomalies = <SessionAnomaly>[];
    final workStats = await getSessionStats(true);
    final breakStats = await getSessionStats(false);

    final completed = entries.where((e) => e.entry.checkOut != null).toList()
      ..sort((a, b) => a.entry.checkIn.compareTo(b.entry.checkIn));

    for (int i = 0; i < completed.length; i++) {
      final id = completed[i].id;
      final e = completed[i].entry;
      final stats = e.isWorkSession ? workStats : breakStats;
      final seconds = e.duration.inSeconds;

      // 1. Forgotten checkout: far beyond your own historical pattern, with
      // a hard floor (6h) so a handful of early entries don't trigger noise.
      final threshold = stats.meanSeconds + (3 * stats.stdDevSeconds);
      if (stats.stdDevSeconds > 0 &&
          seconds > threshold &&
          seconds > 6 * 3600) {
        final usual = Duration(seconds: stats.meanSeconds.round());
        anomalies.add(SessionAnomaly(
          entryId: id,
          type: AnomalyType.forgottenCheckout,
          checkIn: e.checkIn,
          message:
              'This ${e.sessionLabel.toLowerCase()} session ran ${_formatDuration(e.duration)} '
              '— well beyond your usual ${_formatDuration(usual)}. Forgot to check out?',
        ));
      }

      // 2. Suspiciously short — catches manual/synced entries that skip the
      // live 10s confirmation dialog in the UI.
      if (seconds < 10) {
        anomalies.add(SessionAnomaly(
          entryId: id,
          type: AnomalyType.unusuallyShort,
          checkIn: e.checkIn,
          message: 'This entry is only ${seconds}s long — likely a mis-tap.',
        ));
      }

      // 3. Overnight span
      if (e.checkOut!.day != e.checkIn.day && seconds > 4 * 3600) {
        anomalies.add(SessionAnomaly(
          entryId: id,
          type: AnomalyType.overnightSpan,
          checkIn: e.checkIn,
          message: 'This session crosses midnight '
              '(${_formatDateTime(e.checkIn)} \u2192 ${_formatDateTime(e.checkOut!)}).',
        ));
      }

      // 4. Overlap with the next entry
      if (i + 1 < completed.length) {
        final next = completed[i + 1].entry;
        if (e.checkOut!.isAfter(next.checkIn)) {
          anomalies.add(SessionAnomaly(
            entryId: id,
            type: AnomalyType.overlapping,
            checkIn: e.checkIn,
            message: 'Overlaps with the next entry at '
                '${_formatDateTime(next.checkIn)}.',
          ));
        }
      }
    }

    return anomalies;
  }

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    return '${hours}h ${minutes}m';
  }

  static String _formatDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$y-$mo-$d $h:$mi';
  }
}