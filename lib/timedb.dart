
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
}
