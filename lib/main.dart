import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:trackthetime/timedb.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Desktop-only plugins
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

/// Set by TimeTrackerHome when it mounts, so the tray menu (which has no
/// widget context) can trigger the settings dialog inside the app.
/// Only ever populated/invoked on desktop, since there's no tray on mobile.
VoidCallback? onOpenSettingsRequested;
double _targetHours = 8.0;
Set<int> _workingWeekdays = {1, 2, 3, 4, 5};

/// True on Windows/Linux/macOS, false on Android/iOS/web.
bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

final FlutterLocalNotificationsPlugin _mobileNotifications =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // --- Database setup ---
  // sqflite works natively on Android/iOS. On desktop we swap in the FFI
  // implementation so the same `sqflite` calls in timedb.dart work there too.
  if (_isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  if (_isDesktop) {
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
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );

    // 3. Configure Native Window Manager Engine
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = WindowOptions(
      size: Size(1024, 600),
      center: true,
      alwaysOnTop: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.normal,
      skipTaskbar: true,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.hide();
    });

    // 4. Attach System Tray and Trigger Splash Message
    try {
      await initSystemTray();
    } catch (e, st) {
      debugPrint('Tray init failed: $e\n$st');
    }
  } else {
    // Mobile: init flutter_local_notifications + request runtime permission
    await _initMobileNotifications();
  }

  showSplashNotification();

  runApp(const MyApp());
}

Future<void> _initMobileNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);

  await _mobileNotifications.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      // App is already foregrounded by the OS when a notification is
      // tapped, so there's nothing extra to do here on Android.
    },
  );

  await _mobileNotifications
      .resolvePlatformSpecificImplementation
          <AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

/// Unified notification helper — routes to local_notifier on desktop and
/// flutter_local_notifications on mobile.
void _showAppNotification({
  required String title,
  required String body,
  VoidCallback? onTap,
}) {
  if (_isDesktop) {
    LocalNotification notification = LocalNotification(
      title: title,
      body: body,
      silent: false,
    );
    notification.onClick = () => onTap?.call();
    notification.show();
  } else {
    const androidDetails = AndroidNotificationDetails(
      'trackthetime_channel',
      'Time Tracker',
      channelDescription: 'Time tracking reminders and status updates',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    _mobileNotifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      details,
    );
  }
}

Future<void> _showAndFocusWindow() async {
  if (_isDesktop) {
    await windowManager.show();
    await windowManager.focus();
  }
  // On mobile there's nothing to do — the app is already in the foreground.
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

/// Sets up the persistent icon tray and its respective context menus.
/// Desktop-only — never called on Android.
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

  await menu.buildFrom([
    MenuItemLabel(
      label: 'Open Dashboard',
      onClicked: (menuItem) => windowManager.show(),
    ),
    MenuItemLabel(
      label: 'Set Daily Target',
      onClicked: (menuItem) async {
        await windowManager.show();
        await windowManager.focus();
        onOpenSettingsRequested?.call();
      },
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

  systemTray.registerSystemTrayEventHandler((eventName) {
    debugPrint("Tray event: $eventName");
    if (eventName == kSystemTrayEventClick) {
      windowManager.isVisible().then((visible) {
        visible ? windowManager.hide() : windowManager.show();
      });
    } else if (eventName == kSystemTrayEventRightClick) {
      systemTray.popUpContextMenu();
    }
  });
}

void showSplashNotification() {
  _showAppNotification(
    title: 'App Initialized Successfully',
    body: _isDesktop
        ? 'The utility is running smoothly inside your system tray.'
        : 'Time Tracker is ready to use.',
    onTap: _showAndFocusWindow,
  );
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
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const Expanded(child: TimeTrackerHome()),
            // Tray/minimize messaging only makes sense on desktop — on
            // Android the app just runs normally in the foreground.
            if (_isDesktop)
              Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Icon(Icons.dns_rounded,
                      size: 12, color: Colors.deepPurple),
                  const SizedBox(height: 16),
                  const Text(
                    'Background Service Status: Active',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
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
              ),
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

  // --- Anomaly detection state ---
  List<SessionAnomaly> _anomalies = [];
  bool _anomalyBannerDismissed = false;
  bool _hasWarnedActiveSession = false;

  @override
  void initState() {
    super.initState();
    _loadEntries();
    _startTimer();
    _loadTargetHours();
    onOpenSettingsRequested = _showTargetSettingsDialog;
  }

  @override
  void dispose() {
    _notesController.dispose();
    _timer?.cancel();
    if (onOpenSettingsRequested == _showTargetSettingsDialog) {
      onOpenSettingsRequested = null;
    }
    super.dispose();
  }

  Future<void> _loadTargetHours() async {
    final prefs = await SharedPreferences.getInstance();
    final storedDays = prefs.getStringList('working_weekdays');
    setState(() {
      _targetHours = prefs.getDouble('target_hours') ?? 8.0;
      if (storedDays != null && storedDays.isNotEmpty) {
        _workingWeekdays = storedDays.map(int.parse).toSet();
      }
    });
  }

  Future<void> _saveTargetHours(double hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('target_hours', hours);
    setState(() => _targetHours = hours);
  }

  Future<void> _saveWorkingWeekdays(Set<int> days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'working_weekdays',
      days.map((d) => d.toString()).toList(),
    );
    setState(() => _workingWeekdays = days);
  }

  int _workingDaysInMonth(int year, int month) {
    final daysInMonth = DateTime(year, month + 1, 0).day;
    int count = 0;
    for (int day = 1; day <= daysInMonth; day++) {
      final weekday = DateTime(year, month, day).weekday;
      if (_workingWeekdays.contains(weekday)) count++;
    }
    return count;
  }

  Future<void> _showMonthlyReport() async {
    DateTime selectedMonth =
        DateTime(DateTime.now().year, DateTime.now().month);

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return FutureBuilder<Map<String, int>>(
              future: TimeDb.getMonthlyWorkSeconds(
                  selectedMonth.year, selectedMonth.month),
              builder: (context, snapshot) {
                final dailyTotals = snapshot.data ?? {};
                final totalSeconds =
                    dailyTotals.values.fold<int>(0, (a, b) => a + b);
                final daysLogged = dailyTotals.length;
                final targetSecondsPerDay = (_targetHours * 3600).round();
                final daysMetTarget = dailyTotals.values
                    .where((s) => s >= targetSecondsPerDay)
                    .length;

                final workingDaysThisMonth = _workingDaysInMonth(
                    selectedMonth.year, selectedMonth.month);
                final monthlyTargetSeconds =
                    workingDaysThisMonth * targetSecondsPerDay;
                final monthlyProgress = monthlyTargetSeconds == 0
                    ? 0.0
                    : (totalSeconds / monthlyTargetSeconds).clamp(0.0, 1.0);
                final monthlyMet = totalSeconds >= monthlyTargetSeconds;

                return AlertDialog(
                  title: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: () {
                          setDialogState(() {
                            selectedMonth = DateTime(
                                selectedMonth.year, selectedMonth.month - 1);
                          });
                        },
                      ),
                      Text(DateFormat('MMMM yyyy').format(selectedMonth)),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: selectedMonth.year == DateTime.now().year &&
                                selectedMonth.month == DateTime.now().month
                            ? null
                            : () {
                                setDialogState(() {
                                  selectedMonth = DateTime(selectedMonth.year,
                                      selectedMonth.month + 1);
                                });
                              },
                      ),
                    ],
                  ),
                  content: SizedBox(
                    width: 320,
                    child: snapshot.connectionState == ConnectionState.waiting
                        ? const SizedBox(
                            height: 120,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _reportStat(
                                  'Total hours', _formatHoursMinutes(totalSeconds)),
                              _reportStat('Days logged', '$daysLogged'),
                              _reportStat(
                                'Avg per logged day',
                                daysLogged == 0
                                    ? '—'
                                    : _formatHoursMinutes(
                                        totalSeconds ~/ daysLogged),
                              ),
                              _reportStat('Days met target',
                                  '$daysMetTarget / $daysLogged'),
                              const Divider(height: 24),
                              _reportStat(
                                  'Working days this month', '$workingDaysThisMonth'),
                              _reportStat(
                                'Est. monthly target',
                                _formatHoursMinutes(monthlyTargetSeconds),
                              ),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: monthlyProgress,
                                  backgroundColor: Colors.grey[300],
                                  color: monthlyMet
                                      ? Colors.green
                                      : Colors.deepPurple,
                                  minHeight: 8,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                monthlyMet
                                    ? '${_formatHoursMinutes(totalSeconds - monthlyTargetSeconds)} over monthly target'
                                    : '${_formatHoursMinutes(monthlyTargetSeconds - totalSeconds)} remaining of monthly target',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: monthlyMet
                                      ? Colors.green[800]
                                      : Colors.deepPurple[700],
                                ),
                              ),
                              const Divider(height: 24),
                              SizedBox(
                                height: 220,
                                child: dailyTotals.isEmpty
                                    ? const Center(
                                        child: Text('No entries this month',
                                            style:
                                                TextStyle(color: Colors.grey)),
                                      )
                                    : ListView(
                                        children:
                                            dailyTotals.entries.map((e) {
                                          final met =
                                              e.value >= targetSecondsPerDay;
                                          return ListTile(
                                            dense: true,
                                            contentPadding: EdgeInsets.zero,
                                            leading: Icon(
                                              met
                                                  ? Icons.check_circle
                                                  : Icons
                                                      .remove_circle_outline,
                                              color: met
                                                  ? Colors.green
                                                  : Colors.grey,
                                              size: 20,
                                            ),
                                            title: Text(
                                              DateFormat('EEE, MMM d').format(
                                                  DateTime.parse(e.key)),
                                            ),
                                            trailing:
                                                Text(_formatHoursMinutes(e.value)),
                                          );
                                        }).toList(),
                                      ),
                              ),
                            ],
                          ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _reportStat(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[700])),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  String _formatHoursMinutes(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    return '${hours}h ${minutes}m';
  }

  Future<void> _showTargetSettingsDialog() async {
    final controller = TextEditingController(
      text: _targetHours == _targetHours.roundToDouble()
          ? _targetHours.toStringAsFixed(0)
          : _targetHours.toString(),
    );
    String? errorText;
    Set<int> selectedDays = Set.from(_workingWeekdays);

    const weekdayLabels = {
      1: 'Mon',
      2: 'Tue',
      3: 'Wed',
      4: 'Thu',
      5: 'Fri',
      6: 'Sat',
      7: 'Sun',
    };

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Target Settings'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Target hours per day',
                        border: OutlineInputBorder(),
                        suffixText: 'hrs',
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(errorText!,
                          style:
                              const TextStyle(color: Colors.red, fontSize: 13)),
                    ],
                    const SizedBox(height: 20),
                    const Text(
                      'Working Days',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Used to estimate your monthly target',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: weekdayLabels.entries.map((e) {
                        final selected = selectedDays.contains(e.key);
                        return FilterChip(
                          label: Text(e.value),
                          selected: selected,
                          onSelected: (value) {
                            setDialogState(() {
                              if (value) {
                                selectedDays.add(e.key);
                              } else {
                                selectedDays.remove(e.key);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${selectedDays.length} working day${selectedDays.length == 1 ? '' : 's'} per week',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
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
                    final value = double.tryParse(controller.text);
                    if (value == null || value <= 0 || value > 24) {
                      setDialogState(() {
                        errorText = 'Enter a valid number between 0 and 24';
                      });
                      return;
                    }
                    if (selectedDays.isEmpty) {
                      setDialogState(() {
                        errorText = 'Select at least one working day';
                      });
                      return;
                    }
                    await _saveTargetHours(value);
                    await _saveWorkingWeekdays(selectedDays);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
  }

  Widget _buildTargetProgress() {
    final workTime = _calculateDailySummary()['work']!;
    final target = Duration(minutes: (_targetHours * 60).round());
    final diff = workTime - target;
    final metTarget = diff >= Duration.zero;
    final remaining = metTarget ? Duration.zero : target - workTime;

    final isActivelyWorking =
        _activeEntry != null && _activeEntry!.entry.isWorkSession;
    final expectedCompletion = (!metTarget && isActivelyWorking)
        ? DateTime.now().add(remaining)
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: metTarget ? Colors.green[50] : Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Daily Target',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                GestureDetector(
                  onTap: _showTargetSettingsDialog,
                  child: Row(
                    children: [
                      Text(
                          '${_targetHours.toStringAsFixed(_targetHours == _targetHours.roundToDouble() ? 0 : 1)} hrs',
                          style: TextStyle(color: Colors.grey[700])),
                      const SizedBox(width: 4),
                      Icon(Icons.edit, size: 14, color: Colors.grey[500]),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: target.inSeconds == 0
                    ? 0
                    : (workTime.inSeconds / target.inSeconds).clamp(0.0, 1.0),
                backgroundColor: Colors.grey[300],
                color: metTarget ? Colors.green : Colors.blue,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              metTarget
                  ? '${_formatDuration(diff)} over target'
                  : '${_formatDuration(diff.abs())} remaining to target',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: metTarget ? Colors.green[800] : Colors.blue[800],
              ),
            ),
            if (expectedCompletion != null) ...[
              const SizedBox(height: 4),
              Text(
                'Est. target completion: ${_formatTime(expectedCompletion)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ] else if (!metTarget) ...[
              const SizedBox(height: 4),
              Text(
                'Start a work session to see the estimated completion time',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[500],
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_activeEntry != null) {
        setState(() {
          _elapsedTime = DateTime.now().difference(_activeEntry!.entry.checkIn);
        });

        // Live watchdog: fire once per active session (not once per second)
        // if it's been running implausibly long. This catches "forgot to
        // check out" in the moment, rather than after the fact in history.
        if (!_hasWarnedActiveSession && _elapsedTime > const Duration(hours: 10)) {
          _hasWarnedActiveSession = true;
          _showAppNotification(
            title: 'Still checked in',
            body:
                'Your ${_activeEntry!.entry.sessionLabel.toLowerCase()} session has been '
                'running for ${_formatDuration(_elapsedTime)}. Still working?',
            onTap: _showAndFocusWindow,
          );
        }
      } else {
        // Reset so the next session gets its own fresh warning.
        _hasWarnedActiveSession = false;
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
                    entry.notes =
                        notesController.text.isEmpty ? null : notesController.text;

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
    final anomalies = await TimeDb.detectAnomalies(entries);
    setState(() {
      _entries = entries;
      _activeEntry = entries.where((e) => e.entry.checkOut == null).firstOrNull;
      if (_activeEntry != null) {
        _elapsedTime = DateTime.now().difference(_activeEntry!.entry.checkIn);
      }
      _anomalies = anomalies;
      // Re-show the banner if new anomalies showed up since it was dismissed.
      if (anomalies.isNotEmpty) {
        _anomalyBannerDismissed = false;
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

    final duration = DateTime.now().difference(_activeEntry!.entry.checkIn);
    if (duration.inSeconds < 10) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Very Short Session'),
          content: const Text(
              'This session is less than 10 seconds. Are you sure you want to check out?'),
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
    _activeEntry!.entry.notes =
        _notesController.text.isEmpty ? null : _notesController.text;

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
      entryWithId.entry.notes =
          notesController.text.isEmpty ? null : notesController.text;
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

    final active = _activeEntry?.entry;
    if (active != null &&
        active.checkIn.year == today.year &&
        active.checkIn.month == today.month &&
        active.checkIn.day == today.day) {
      if (active.isWorkSession) {
        workTime += _elapsedTime;
      } else {
        breakTime += _elapsedTime;
      }
    }

    return {'work': workTime, 'break': breakTime};
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('MMM dd, yyyy • HH:mm').format(dt);
  }

  String _formatTime(DateTime dt) {
    return DateFormat('h:mm a').format(dt);
  }

  // --- Anomaly banner helpers ---

  IconData _iconForAnomaly(AnomalyType type) {
    switch (type) {
      case AnomalyType.forgottenCheckout:
        return Icons.timer_off;
      case AnomalyType.unusuallyShort:
        return Icons.bolt;
      case AnomalyType.overlapping:
        return Icons.compare_arrows;
      case AnomalyType.overnightSpan:
        return Icons.nights_stay;
    }
  }

  String _titleForAnomaly(AnomalyType type) {
    switch (type) {
      case AnomalyType.forgottenCheckout:
        return 'Possible forgotten checkout';
      case AnomalyType.unusuallyShort:
        return 'Unusually short entry';
      case AnomalyType.overlapping:
        return 'Overlapping entries';
      case AnomalyType.overnightSpan:
        return 'Session spans midnight';
    }
  }

  void _showAnomalyDetails() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber[800]),
            const SizedBox(width: 8),
            const Text('Possible data issues'),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _anomalies.map((a) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_iconForAnomaly(a.type), color: Colors.amber[800]),
                  title: Text(
                    _titleForAnomaly(a.type),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  subtitle: Text(a.message, style: const TextStyle(fontSize: 12)),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit, size: 18),
                    tooltip: 'Edit this entry',
                    onPressed: () {
                      Navigator.pop(context);
                      final match = _entries
                          .where((e) => e.id == a.entryId)
                          .firstOrNull;
                      if (match != null) _editEntry(match);
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildAnomalyBanner() {
    if (_anomalies.isEmpty || _anomalyBannerDismissed) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber[200]!),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.amber[800], size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: _showAnomalyDetails,
              child: Text(
                _anomalies.length == 1
                    ? '1 entry looks worth a second look'
                    : '${_anomalies.length} entries look worth a second look',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.amber[900],
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: _showAnomalyDetails,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Review', style: TextStyle(fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: Colors.amber[900],
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _anomalyBannerDismissed = true),
          ),
        ],
      ),
    );
  }

  Widget _buildDailySummary() {
    final summary = _calculateDailySummary();
    final workTime = summary['work']!;
    final breakTime = summary['break']!;

    if (workTime == Duration.zero && breakTime == Duration.zero) {
      return const SizedBox.shrink();
    }

    final target = Duration(minutes: (_targetHours * 60).round());
    final metTarget = workTime >= target;
    final remaining = metTarget ? Duration.zero : target - workTime;

    final isActivelyWorking =
        _activeEntry != null && _activeEntry!.entry.isWorkSession;
    final expectedCompletion = (!metTarget && isActivelyWorking)
        ? DateTime.now().add(remaining)
        : null;

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
            if (metTarget) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.check_circle, size: 16, color: Colors.green[700]),
                  const SizedBox(width: 6),
                  Text(
                    'Daily target reached',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.green[700],
                    ),
                  ),
                ],
              ),
            ] else if (expectedCompletion != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: Colors.grey[700]),
                  const SizedBox(width: 6),
                  Text(
                    'Target expected at ${_formatTime(expectedCompletion)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[800],
                    ),
                  ),
                ],
              ),
            ] else ...[
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: Colors.grey[400]),
                  const SizedBox(width: 6),
                  Text(
                    'Start a work session to estimate target time',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[500],
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ],
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
    _showAppNotification(
      title: 'Start Time Tracking',
      body: "You're logged in — don't forget to start a work session.",
      onTap: _showAndFocusWindow,
    );
  }

  @override
  Widget build(BuildContext context) {
    final completedEntries =
        _entries.where((e) => e.entry.checkOut != null).toList();

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
            icon: const Icon(Icons.calendar_month),
            onPressed: _showMonthlyReport,
            tooltip: 'Monthly report',
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
                  content: const Text(
                      'Are you sure you want to delete all entries? This cannot be undone.'),
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
                _buildAnomalyBanner(),
                _buildDailySummary(),
                _buildTargetProgress(),
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
                            final isFlagged = _anomalies
                                .any((a) => a.entryId == entryWithId.id);
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              shape: isFlagged
                                  ? RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(4),
                                      side: BorderSide(
                                          color: Colors.amber[400]!, width: 1.5),
                                    )
                                  : null,
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: entry.isWorkSession
                                      ? Colors.blue
                                      : Colors.orange,
                                  child: Icon(
                                    entry.isWorkSession
                                        ? Icons.work
                                        : Icons.coffee,
                                    color: Colors.white,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        '${entry.sessionLabel} • ${entry.durationString}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    if (isFlagged) ...[
                                      const SizedBox(width: 6),
                                      Icon(Icons.warning_amber_rounded,
                                          size: 16, color: Colors.amber[800]),
                                    ],
                                  ],
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
                                      icon: const Icon(Icons.edit,
                                          color: Colors.blue),
                                      onPressed: () => _editEntry(entryWithId),
                                      tooltip: 'Edit notes',
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          color: Colors.red),
                                      onPressed: () =>
                                          _deleteEntry(entryWithId.id),
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