import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:system_tray/system_tray.dart';
import 'package:trackthetime/timedb.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:intl/intl.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize sqflite for desktop
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  // 1. Setup App Utilities and Startup Registration
  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  LaunchAtStartup.instance.setup(
    appName: packageInfo.appName,
    appPath: Platform.resolvedExecutable,
  );
  await LaunchAtStartup.instance.enable();

  // 2. Initialize Native Toast Notification Engine safely via Dart
  await localNotifier.setup(
    appName: packageInfo.appName,
    // Setting a unique appId here forces the package to handle the Windows AUMID registration automatically
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );

  // 3. Configure Native Window Manager Engine
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    title: "Daily Time Tracker",
    size: Size(450, 650),
    minimumSize: Size(300, 400),
    center: true,
    skipTaskbar: true, // Hides the app from the primary taskbar row
  );

  // Ready the window, but force it to stay hidden initially
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.hide();
  });

  // 4. Attach System Tray and Trigger Splash Message
try {
  await initSystemTray();
} catch (e, st) {
  debugPrint('Tray init failed: $e\n$st');
}
showSplashNotification();

  runApp(const MyApp());
}

String getTrayIconPath(String fileName) {
  return path.join(
    path.dirname(Platform.resolvedExecutable),
    'data',
    'flutter_assets',
    'assets',
    fileName,
  );
}
/// Sets up the persistent icon tray and its respective context menus
Future<void> initSystemTray() async {
   final SystemTray systemTray = SystemTray();
  final Menu menu = Menu();

  final iconFile = Platform.isWindows ? 'app_icon.ico' : 'app_icon.png';
  final iconPath = path.join(
    path.dirname(Platform.resolvedExecutable),
    'data',
    'flutter_assets',
    'assets',
    iconFile,
  );

  debugPrint('Resolved icon path: $iconPath');
  debugPrint('File exists: ${File(iconPath).existsSync()}');

  await systemTray.initSystemTray(
    title: "Tray Utility",
    iconPath: iconPath,
  );
  // Construct context dropdown items
  await menu.buildFrom([
    MenuItemLabel(
      label: 'Open Dashboard', 
      onClicked: (menuItem) => windowManager.show(),
    ),
    MenuItemLabel(
      label: 'Minimize to Tray', 
      onClicked: (menuItem) => windowManager.hide(),
    ),
    MenuSeparator(),
    MenuItemLabel(
      label: 'Close Completely', 
      onClicked: (menuItem) => windowManager.destroy(),
    ),
  ]);

  await systemTray.setContextMenu(menu);

  // Map left click behavior to toggle application display state
 systemTray.registerSystemTrayEventHandler((eventName) {
  debugPrint("Tray event: $eventName"); // helpful to confirm events are firing at all
  if (eventName == kSystemTrayEventClick) {
    windowManager.isVisible().then((visible) {
      visible ? windowManager.hide() : windowManager.show();
    });
  } else if (eventName == kSystemTrayEventRightClick) {
    systemTray.popUpContextMenu();
  }
});
}

/// Pushes a native action toast alert down on the desktop surface
void showSplashNotification() {
  LocalNotification notification = LocalNotification(
    title: "App Initialized Successfully",
    body: "The utility is running smoothly inside your system tray.",
    silent: false, // Triggers standard OS alert audio chime
  );

  // Maximize UI dashboard focus if user interacts with the alert banner
  notification.onClick = () {
    windowManager.show();
    windowManager.focus();
  };

  notification.show();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // appBar: AppBar(
      //   title: const Text('WELCOME'),
      //   centerTitle: false,
      //   leading: IconButton(
      //     icon: const Icon(Icons.arrow_back),
      //     onPressed: () => windowManager.hide(),
      //   ),
      // ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Expanded(child: 
                  TimeTrackerHome()),
            Column(
               mainAxisAlignment: MainAxisAlignment.end,
              children: [
          
                const Icon(Icons.dns_rounded, size: 12, color: Colors.deepPurple),
            const SizedBox(height: 16),
            const Text(
              'Background Service Status: Active',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Closing this interface page keeps the operation active inside your taskbar utility ecosystem.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.hide_source),
              label: const Text(''),
              onPressed: () async {
                await windowManager.hide();
              },
            ),
            ],
            )
          
          ],
        ),
      ),
    );
  }
}

class TimeTrackerHome extends StatefulWidget {
  const TimeTrackerHome({Key? key}) : super(key: key);

  @override
  State<TimeTrackerHome> createState() => _TimeTrackerHomeState();
}

class _TimeTrackerHomeState extends State<TimeTrackerHome> {
  bool _hasShownStartupReminder = false;
  List<EntryWithId> _entries = [];
  EntryWithId? _activeEntry;
  bool _isLoading = true;
  final TextEditingController _notesController = TextEditingController();
  Timer? _timer;
  Duration _elapsedTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadEntries();
    _startTimer();
  }

  @override
  void dispose() {
    _notesController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_activeEntry != null) {
        setState(() {
          _elapsedTime = DateTime.now().difference(_activeEntry!.entry.checkIn);
        });
      }
    });
  }
Future<DateTime?> _pickDateTime(BuildContext context, DateTime initial) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime.now().subtract(const Duration(days: 365)),
    lastDate: DateTime.now(),
  );
  if (date == null) return null;

  if (!context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;

  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

Future<void> _addManualEntry() async {
  bool isWorkSession = true;
  DateTime checkIn = DateTime.now().subtract(const Duration(hours: 1));
  DateTime checkOut = DateTime.now();
  final notesController = TextEditingController();
  String? errorText;

  await showDialog(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Add Manual Entry'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        label: Text('Work'),
                        icon: Icon(Icons.work),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text('Break'),
                        icon: Icon(Icons.coffee),
                      ),
                    ],
                    selected: {isWorkSession},
                    onSelectionChanged: (selection) {
                      setDialogState(() => isWorkSession = selection.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.login),
                    title: const Text('Check In'),
                    subtitle: Text(_formatDateTime(checkIn)),
                    trailing: const Icon(Icons.edit_calendar),
                    onTap: () async {
                      final picked = await _pickDateTime(context, checkIn);
                      if (picked != null) {
                        setDialogState(() {
                          checkIn = picked;
                          errorText = null;
                        });
                      }
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.logout),
                    title: const Text('Check Out'),
                    subtitle: Text(_formatDateTime(checkOut)),
                    trailing: const Icon(Icons.edit_calendar),
                    onTap: () async {
                      final picked = await _pickDateTime(context, checkOut);
                      if (picked != null) {
                        setDialogState(() {
                          checkOut = picked;
                          errorText = null;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 2,
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  if (!checkOut.isAfter(checkIn)) {
                    setDialogState(() {
                      errorText = 'Check out must be after check in';
                    });
                    return;
                  }

                  final overlaps = _entries.any((e) {
                    final existingOut = e.entry.checkOut ?? DateTime.now();
                    return checkIn.isBefore(existingOut) &&
                        checkOut.isAfter(e.entry.checkIn);
                  });

                  if (overlaps) {
                    setDialogState(() {
                      errorText = 'This overlaps with an existing entry';
                    });
                    return;
                  }

                  final entry = TimeEntry(
                    checkIn: checkIn,
                    isWorkSession: isWorkSession,
                  );
                  entry.checkOut = checkOut;
                  entry.notes = notesController.text.isEmpty
                      ? null
                      : notesController.text;

                  await TimeDb.insertEntry(entry);
                  if (context.mounted) Navigator.pop(context);
                  await _loadEntries();

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Manual entry added'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      );
    },
  );

  notesController.dispose();
}
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _loadEntries() async {
    setState(() => _isLoading = true);
    final entries = await TimeDb.getAllEntriesWithIds();
    setState(() {
      _entries = entries;
      _activeEntry = entries.where((e) => e.entry.checkOut == null).firstOrNull;
      if (_activeEntry != null) {
        _elapsedTime = DateTime.now().difference(_activeEntry!.entry.checkIn);
      }
      _isLoading = false;
    });

  
 

  if (!_hasShownStartupReminder) {
    _hasShownStartupReminder = true;
    if (_activeEntry == null) {
      _showStartTrackingReminder();
    }
  }
  }

  Future<void> _checkIn(bool isWorkSession) async {
    if (_activeEntry != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please check out of the current session first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final entry = TimeEntry(
      checkIn: DateTime.now(),
      isWorkSession: isWorkSession,
    );
    
    await TimeDb.insertEntry(entry);
    await _loadEntries();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${isWorkSession ? 'Work' : 'Break'} session started'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _checkOut() async {
    if (_activeEntry == null) return;

    // Check minimum duration (10 seconds)
    final duration = DateTime.now().difference(_activeEntry!.entry.checkIn);
    if (duration.inSeconds < 10) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Very Short Session'),
          content: const Text('This session is less than 10 seconds. Are you sure you want to check out?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Check Out'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    _activeEntry!.entry.checkOut = DateTime.now();
    _activeEntry!.entry.notes = _notesController.text.isEmpty 
        ? null 
        : _notesController.text;
    
    await TimeDb.updateEntry(_activeEntry!.entry, _activeEntry!.id);
    _notesController.clear();
    await _loadEntries();
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Session completed'),
        backgroundColor: Colors.blue,
      ),
    );
  }

  Future<void> _editEntry(EntryWithId entryWithId) async {
    final notesController = TextEditingController(text: entryWithId.entry.notes);
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Entry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${entryWithId.entry.sessionLabel} Session'),
            const SizedBox(height: 8),
            Text('Duration: ${entryWithId.entry.durationString}'),
            const SizedBox(height: 16),
            TextField(
              controller: notesController,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (result == true) {
      entryWithId.entry.notes = notesController.text.isEmpty 
          ? null 
          : notesController.text;
      await TimeDb.updateEntry(entryWithId.entry, entryWithId.id);
      await _loadEntries();
    }
    notesController.dispose();
  }

  Future<void> _deleteEntry(int id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text('Are you sure you want to delete this entry?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      await TimeDb.deleteEntry(id);
      await _loadEntries();
    }
  }

  Map<String, Duration> _calculateDailySummary() {
    final today = DateTime.now();
    final todayEntries = _entries.where((e) {
      return e.entry.checkIn.year == today.year &&
             e.entry.checkIn.month == today.month &&
             e.entry.checkIn.day == today.day &&
             e.entry.checkOut != null;
    });

    Duration workTime = Duration.zero;
    Duration breakTime = Duration.zero;

    for (final entry in todayEntries) {
      if (entry.entry.isWorkSession) {
        workTime += entry.entry.duration;
      } else {
        breakTime += entry.entry.duration;
      }
    }

    return {'work': workTime, 'break': breakTime};
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('MMM dd, yyyy • HH:mm').format(dt);
  }

  Widget _buildDailySummary() {
    final summary = _calculateDailySummary();
    final workTime = summary['work']!;
    final breakTime = summary['break']!;

    if (workTime == Duration.zero && breakTime == Duration.zero) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.grey[100],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Today\'s Summary',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    const Icon(Icons.work, color: Colors.blue),
                    const SizedBox(height: 4),
                    Text(
                      _formatDuration(workTime),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const Text('Work', style: TextStyle(color: Colors.grey)),
                  ],
                ),
                Column(
                  children: [
                    const Icon(Icons.coffee, color: Colors.orange),
                    const SizedBox(height: 4),
                    Text(
                      _formatDuration(breakTime),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                      ),
                    ),
                    const Text('Break', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveSession() {
    if (_activeEntry == null) {
      return Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Icon(Icons.timer_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                'No Active Session',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _checkIn(true),
                      icon: const Icon(Icons.work),
                      label: const Text('Start Work'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _checkIn(false),
                      icon: const Icon(Icons.coffee),
                      label: const Text('Start Break'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final entry = _activeEntry!.entry;
    return Card(
      margin: const EdgeInsets.all(16),
      color: entry.isWorkSession ? Colors.blue[50] : Colors.orange[50],
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  entry.isWorkSession ? Icons.work : Icons.coffee,
                  color: entry.isWorkSession ? Colors.blue : Colors.orange,
                ),
                const SizedBox(width: 8),
                Text(
                  '${entry.sessionLabel} Session',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                _formatDuration(_elapsedTime),
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: entry.isWorkSession ? Colors.blue : Colors.orange,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Started: ${_formatDateTime(entry.checkIn)}',
                style: TextStyle(color: Colors.grey[700]),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _checkOut,
                icon: const Icon(Icons.stop),
                label: const Text('Check Out'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

void _showStartTrackingReminder() {
  final notification = LocalNotification(
    title: 'Start Time Tracking',
    body: "You're logged in — don't forget to start a work session.",
    silent: false,
  );

  notification.onClick = () {
    windowManager.show();
    windowManager.focus();
  };

  notification.show();
}
  @override
  Widget build(BuildContext context) {
    final completedEntries = _entries.where((e) => e.entry.checkOut != null).toList();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Time Tracker'),
        actions: [
           IconButton(
    icon: const Icon(Icons.add_circle_outline),
    onPressed: _addManualEntry,
    tooltip: 'Add manual entry',
  ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadEntries,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear All Data'),
                  content: const Text('Are you sure you want to delete all entries? This cannot be undone.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Delete All'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await TimeDb.clearAll();
                await _loadEntries();
              }
            },
            tooltip: 'Clear all data',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildActiveSession(),
                _buildDailySummary(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'History',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: completedEntries.isEmpty
                      ? const Center(
                          child: Text(
                            'No history yet',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: completedEntries.length,
                          itemBuilder: (context, index) {
                            final entryWithId = completedEntries[index];
                            final entry = entryWithId.entry;
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: entry.isWorkSession
                                      ? Colors.blue
                                      : Colors.orange,
                                  child: Icon(
                                    entry.isWorkSession ? Icons.work : Icons.coffee,
                                    color: Colors.white,
                                  ),
                                ),
                                title: Text(
                                  '${entry.sessionLabel} • ${entry.durationString}',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_formatDateTime(entry.checkIn)),
                                    if (entry.notes != null)
                                      Text(
                                        entry.notes!,
                                        style: TextStyle(
                                          fontStyle: FontStyle.italic,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Colors.blue),
                                      onPressed: () => _editEntry(entryWithId),
                                      tooltip: 'Edit notes',
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red),
                                      onPressed: () => _deleteEntry(entryWithId.id),
                                      tooltip: 'Delete',
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
