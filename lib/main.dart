import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:trackthetime/timedb.dart';
import 'package:trackthetime/nl_entry_parser.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:trackthetime/graphical_analysis.dart';
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
SystemTray? _trayInstance;

/// True only where system_tray actually supports tooltips — Windows and
/// macOS. Linux/AppIndicator has no tooltip API, so this stays false there.
bool get _trayTooltipSupported =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS);

/// Updates the tray icon's hover tooltip. No-op (and never throws) if
/// tooltips aren't supported on this platform or the tray hasn't
/// initialized yet.
Future<void> updateTrayTooltip(String tooltip) async {
  if (!_trayTooltipSupported || _trayInstance == null) return;
  try {
    await _trayInstance!.setToolTip(tooltip);
  } catch (e) {
    debugPrint('Failed to update tray tooltip: $e');
  }
}
double _targetHours = 8.0;
Set<int> _workingWeekdays = {1, 2, 3, 4, 5};

/// True on Windows/Linux/macOS, false on Android/iOS/web.
bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

final FlutterLocalNotificationsPlugin _mobileNotifications =
    FlutterLocalNotificationsPlugin();

// ---------------------------------------------------------------------------
// Design system — one place for the palette, spacing and shape language so
// individual widgets stop hard-coding Colors.blue/orange/etc. Work sessions
// are indigo, breaks are amber; both read clearly against the neutral
// surface without competing with the amber "needs attention" anomaly color.
// ---------------------------------------------------------------------------
class AppColors {
  static const work = Color(0xFF4F5FE8);
  static const workDark = Color(0xFF3B48C4);
  static const workSurface = Color(0xFFEEF0FD);
  static const breakColor = Color(0xFFE0912B);
  static const breakSurface = Color(0xFFFCF1E1);
  static const success = Color(0xFF1F9D66);
  static const successSurface = Color(0xFFE7F7EF);
  static const warning = Color(0xFFB4790A);
  static const warningSurface = Color(0xFFFDF3DD);
  static const danger = Color(0xFFD84C4C);
  static const surfaceMuted = Color(0xFFF6F6FA);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.work,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.surfaceMuted,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF1D1E2C),
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: const TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1D1E2C),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      margin: EdgeInsets.zero,
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontWeight: FontWeight.w700),
      titleSmall: TextStyle(fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceMuted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: Colors.grey.shade300),
      ),
    ),
    dividerTheme: DividerThemeData(color: Colors.grey.shade200, thickness: 1),
  );
}

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
  _trayInstance = systemTray;                 // NEW
  final Menu menu = Menu();
 await systemTray.initSystemTray(
    title: "Tray Utility",
    iconPath: iconPath,
    toolTip: "Time Tracker",                  // NEW
  );
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
      theme: buildAppTheme(),
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: Colors.grey.shade200)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Background service active',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Closing this window keeps tracking running from the system tray.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.remove_red_eye_outlined, size: 18),
                      label: const Text('Minimize to tray'),
                      onPressed: () async {
                        await windowManager.hide();
                      },
                    ),
                  ],
                ),
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
  bool? _aiAvailable;
  final TextEditingController _notesController = TextEditingController();
  Timer? _timer;
  Duration _elapsedTime = Duration.zero;

  // --- Anomaly detection state ---
  List<SessionAnomaly> _anomalies = [];
  bool _anomalyBannerDismissed = false;
  bool _hasWarnedActiveSession = false;

  // --- Mobile view toggle state ---
  // On phones/tablets there isn't room to show the active session and the
  // history list at once, so we show one at a time and let a button in the
  // AppBar flip between them. Desktop always shows both side by side.
  bool _showHistoryOnMobile = false;

  @override
  void initState() {
 super.initState();
  _loadEntries();
  _startTimer();
  _loadTargetHours();
  onOpenSettingsRequested = _showTargetSettingsDialog;
  NaturalLanguageEntryParser.aiAvailable()
      .then((v) => setState(() => _aiAvailable = v));
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
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
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
                                borderRadius: BorderRadius.circular(6),
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0, end: monthlyProgress),
                                  duration: const Duration(milliseconds: 500),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, value, _) =>
                                      LinearProgressIndicator(
                                    value: value,
                                    backgroundColor: Colors.grey[200],
                                    color: monthlyMet
                                        ? AppColors.success
                                        : AppColors.work,
                                    minHeight: 10,
                                  ),
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
                                      ? AppColors.success
                                      : AppColors.workDark,
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
                                                  ? AppColors.success
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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
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
                        suffixText: 'hrs',
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(errorText!,
                          style:
                              const TextStyle(color: AppColors.danger, fontSize: 13)),
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
                          showCheckmark: false,
                          selectedColor: AppColors.workSurface,
                          labelStyle: TextStyle(
                            color: selected ? AppColors.workDark : Colors.grey[700],
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                          side: BorderSide(
                            color: selected
                                ? AppColors.work
                                : Colors.grey.shade300,
                          ),
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
                FilledButton(
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
    final progress =
        target.inSeconds == 0 ? 0.0 : (workTime.inSeconds / target.inSeconds).clamp(0.0, 1.0);

    final isActivelyWorking =
        _activeEntry != null && _activeEntry!.entry.isWorkSession;
    final expectedCompletion = (!metTarget && isActivelyWorking)
        ? DateTime.now().add(remaining)
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.flag_rounded,
                        size: 18,
                        color: metTarget ? AppColors.success : AppColors.work),
                    const SizedBox(width: 6),
                    const Text('Daily Target',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ],
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _showTargetSettingsDialog,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        Text(
                            '${_targetHours.toStringAsFixed(_targetHours == _targetHours.roundToDouble() ? 0 : 1)} hrs',
                            style: TextStyle(
                                color: Colors.grey[700], fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Icon(Icons.edit, size: 14, color: Colors.grey[500]),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  backgroundColor: Colors.grey[200],
                  color: metTarget ? AppColors.success : AppColors.work,
                  minHeight: 10,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              metTarget
                  ? '${_formatDuration(diff)} over target'
                  : '${_formatDuration(diff.abs())} remaining to target',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: metTarget ? AppColors.success : AppColors.workDark,
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

  /// Runs the offline NL parser (falling back to on-device Gemini Nano on
  /// supported Android devices when the regex parser can't find a complete
  /// time range) against [descriptionController]'s text and applies the
  /// result to the manual-entry dialog's local state. Shared by both the
  /// auto-fill icon and pressing Enter in the description field.
  Future<void> _applyNlParse({
    required TextEditingController descriptionController,
    required TextEditingController notesController,
    required void Function(void Function()) setDialogState,
    required void Function(DateTime) setCheckIn,
    required void Function(DateTime) setCheckOut,
    required void Function(bool) setIsWorkSession,
    required void Function(String?) setParseWarning,
    required void Function(bool) setIsParsing,
  }) async {
    setDialogState(() => setIsParsing(true));
    final parsed = await NaturalLanguageEntryParser.parseWithAiFallback(
      descriptionController.text,
    );
    setDialogState(() {
      setIsParsing(false);
      if (parsed.checkIn != null) setCheckIn(parsed.checkIn!);
      if (parsed.checkOut != null) setCheckOut(parsed.checkOut!);
      setIsWorkSession(parsed.isWorkSession);
      if (parsed.notes != null) notesController.text = parsed.notes!;
      setParseWarning(parsed.warnings.isNotEmpty ? parsed.warnings.first : null);
    });
  }

  Future<void> _addManualEntry() async {
    bool isWorkSession = true;
    DateTime checkIn = DateTime.now().subtract(const Duration(hours: 1));
    DateTime checkOut = DateTime.now();
    final notesController = TextEditingController();
    final descriptionController = TextEditingController();
    String? errorText;
    String? parseWarning;
    bool isParsing = false;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> runParse() => _applyNlParse(
                  descriptionController: descriptionController,
                  notesController: notesController,
                  setDialogState: setDialogState,
                  setCheckIn: (v) => checkIn = v,
                  setCheckOut: (v) => checkOut = v,
                  setIsWorkSession: (v) => isWorkSession = v,
                  setParseWarning: (v) => parseWarning = v,
                  setIsParsing: (v) => isParsing = v,
                );

            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Add Manual Entry'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: descriptionController,
                      decoration: InputDecoration(
                        labelText: 'Describe it (optional)',
                        hintText:
                            'e.g. "worked 2 to 4:30 on the billing module"',
                        suffixIcon: isParsing
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.auto_awesome),
                                tooltip: 'Auto-fill from description',
                                onPressed: runParse,
                              ),
                      ),
                      enabled: !isParsing,
                      onSubmitted: (_) => runParse(),
                    ),
                    if (_aiAvailable == false) ...[
  const SizedBox(height: 6),
  Row(children: [
    Icon(Icons.info_outline, size: 14, color: Colors.grey[500]),
    const SizedBox(width: 4),
    Expanded(
      child: Text(
        'On-device AI isn\'t available on this device — offline parsing only.',
        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
      ),
    ),
  ]),
],
                    if (parseWarning != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            parseWarning!.contains('AI')
                                ? Icons.auto_awesome
                                : Icons.info_outline,
                            size: 14,
                            color: AppColors.warning,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              parseWarning!,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.warning),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    SegmentedButton<bool>(
                      style: SegmentedButton.styleFrom(
                        selectedBackgroundColor: AppColors.workSurface,
                        selectedForegroundColor: AppColors.workDark,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: true,
                          label: Text('Work'),
                          icon: Icon(Icons.work_outline),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text('Break'),
                          icon: Icon(Icons.coffee_outlined),
                        ),
                      ],
                      selected: {isWorkSession},
                      onSelectionChanged: (selection) {
                        setDialogState(() => isWorkSession = selection.first);
                      },
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.login),
                      title: const Text('Check In'),
                      subtitle: Text(_formatDateTime(checkIn)),
                      trailing: const Icon(Icons.edit_calendar, size: 20),
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
                      trailing: const Icon(Icons.edit_calendar, size: 20),
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
                    const SizedBox(height: 8),
                    TextField(
                      controller: notesController,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        isDense: true,
                      ),
                      maxLines: 2,
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorText!,
                        style: const TextStyle(color: AppColors.danger, fontSize: 13),
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
                FilledButton(
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
                        SnackBar(
                          content: const Text('Manual entry added'),
                          backgroundColor: AppColors.success,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
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
    descriptionController.dispose();
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
        SnackBar(
          content: const Text('Please check out of the current session first'),
          backgroundColor: AppColors.breakColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${isWorkSession ? 'Work' : 'Break'} session started'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _checkOut() async {
    if (_activeEntry == null) return;

    final duration = DateTime.now().difference(_activeEntry!.entry.checkIn);
    if (duration.inSeconds < 10) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Very Short Session'),
          content: const Text(
              'This session is less than 10 seconds. Are you sure you want to check out?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
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

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Session completed'),
          backgroundColor: AppColors.work,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _editEntry(EntryWithId entryWithId) async {
    final notesController = TextEditingController(text: entryWithId.entry.notes);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Entry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${entryWithId.entry.sessionLabel} Session',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Duration: ${entryWithId.entry.durationString}',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: notesController,
              decoration: const InputDecoration(labelText: 'Notes'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
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

  Future<bool> _confirmDeleteEntry() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Entry'),
        content: const Text('Are you sure you want to delete this entry?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  Future<void> _deleteEntry(int id) async {
    if (!await _confirmDeleteEntry()) return;
    await TimeDb.deleteEntry(id);
    await _loadEntries();
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
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
                  leading: Icon(_iconForAnomaly(a.type), color: AppColors.warning),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.warningSurface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: _showAnomalyDetails,
              child: Text(
                _anomalies.length == 1
                    ? '1 entry looks worth a second look'
                    : '${_anomalies.length} entries look worth a second look',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.warning,
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: _showAnomalyDetails,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.warning,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Review', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: AppColors.warning,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _anomalyBannerDismissed = true),
          ),
        ],
      ),
    );
  }

  Widget _statTile({
    required IconData icon,
    required Color color,
    required Color surface,
    required String value,
    required String label,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: color),
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ),
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
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Today's Summary",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _statTile(
                  icon: Icons.work_rounded,
                  color: AppColors.work,
                  surface: AppColors.workSurface,
                  value: _formatDuration(workTime),
                  label: 'Work',
                ),
                const SizedBox(width: 10),
                _statTile(
                  icon: Icons.coffee_rounded,
                  color: AppColors.breakColor,
                  surface: AppColors.breakSurface,
                  value: _formatDuration(breakTime),
                  label: 'Break',
                ),
              ],
            ),
            if (metTarget) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(Icons.check_circle, size: 16, color: AppColors.success),
                  const SizedBox(width: 6),
                  const Text(
                    'Daily target reached',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.success,
                    ),
                  ),
                ],
              ),
            ] else if (expectedCompletion != null) ...[
              const SizedBox(height: 14),
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
              const SizedBox(height: 14),
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
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.surfaceMuted,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.hourglass_empty_rounded,
                    size: 34, color: Colors.grey[500]),
              ),
              const SizedBox(height: 16),
              const Text(
                'No Active Session',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Start tracking to see your timer here',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _checkIn(true),
                      icon: const Icon(Icons.work_outline),
                      label: const Text('Start Work'),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.work),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _checkIn(false),
                      icon: const Icon(Icons.coffee_outlined),
                      label: const Text('Start Break'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.breakColor,
                        side: const BorderSide(color: AppColors.breakColor),
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
    final accent = entry.isWorkSession ? AppColors.work : AppColors.breakColor;
    final surface = entry.isWorkSession ? AppColors.workSurface : AppColors.breakSurface;

    return Card(
      margin: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: surface,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${entry.sessionLabel} session in progress',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  _formatDuration(_elapsedTime),
                  style: TextStyle(
                    fontSize: 46,
                    fontWeight: FontWeight.w800,
                    color: accent,
                    letterSpacing: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Started ${_formatDateTime(entry.checkIn)}',
                  style: TextStyle(color: Colors.grey[700], fontSize: 12),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                TextField(
                  controller: _notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    isDense: true,
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _checkOut,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Check Out'),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                  ),
                ),
              ],
            ),
          ),
        ],
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

  /// Everything above the history list: active session card, anomaly
  /// banner, today's summary, and target progress. Used as the left-hand
  /// panel on desktop, and as one of the two toggle-able panels on mobile.
  Widget _buildSessionPanel() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _buildActiveSession(),
        _buildAnomalyBanner(),
        _buildDailySummary(),
        _buildTargetProgress(),
      ],
    );
  }

  /// Groups completed entries by calendar day (most recent day first, and
  /// entries within a day kept in their existing relative order), returning
  /// an ordered list of (dayStart, entries) pairs.
  List<MapEntry<DateTime, List<EntryWithId>>> _groupEntriesByDate(
      List<EntryWithId> completedEntries) {
    final Map<DateTime, List<EntryWithId>> grouped = {};
    for (final entryWithId in completedEntries) {
      final checkIn = entryWithId.entry.checkIn;
      final dayStart = DateTime(checkIn.year, checkIn.month, checkIn.day);
      grouped.putIfAbsent(dayStart, () => []).add(entryWithId);
    }
    final sortedKeys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    return sortedKeys.map((day) => MapEntry(day, grouped[day]!)).toList();
  }

  /// "Today" / "Yesterday" for recent days, otherwise a full date.
  String _formatDateHeader(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (day == today) return 'Today';
    if (day == yesterday) return 'Yesterday';
    return DateFormat('EEEE, MMM d, yyyy').format(day);
  }

  /// Total work + break duration logged on a given day's entries, for the
  /// small summary shown next to each date header.
  String _dayTotalLabel(List<EntryWithId> dayEntries) {
    final total = dayEntries.fold<Duration>(
      Duration.zero,
      (sum, e) => sum + e.entry.duration,
    );
    return _formatHoursMinutes(total.inSeconds);
  }

  Widget _buildHistoryEntryCard(EntryWithId entryWithId) {
    final entry = entryWithId.entry;
    final isFlagged = _anomalies.any((a) => a.entryId == entryWithId.id);
    final accent = entry.isWorkSession ? AppColors.work : AppColors.breakColor;

    return Dismissible(
      key: ValueKey('entry-${entryWithId.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.danger,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDeleteEntry(),
      onDismissed: (_) async {
        await TimeDb.deleteEntry(entryWithId.id);
        await _loadEntries();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isFlagged ? AppColors.warning.withOpacity(0.5) : Colors.grey.shade200,
            width: isFlagged ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 56,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(2)),
              ),
            ),
            Expanded(
              child: ListTile(
                dense: false,
                leading: Icon(
                  entry.isWorkSession ? Icons.work_rounded : Icons.coffee_rounded,
                  color: accent,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${entry.sessionLabel} • ${entry.durationString}',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                    ),
                    if (isFlagged) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.warning_amber_rounded,
                          size: 15, color: AppColors.warning),
                    ],
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatTime(entry.checkIn) +
                          (entry.checkOut != null
                              ? ' – ${_formatTime(entry.checkOut!)}'
                              : ''),
                      style: TextStyle(fontSize: 12.5, color: Colors.grey[600]),
                    ),
                    if (entry.notes != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          entry.notes!,
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Colors.grey[500],
                            fontSize: 12.5,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
                trailing: IconButton(
                  icon: Icon(Icons.edit_outlined, color: Colors.grey[500], size: 20),
                  onPressed: () => _editEntry(entryWithId),
                  tooltip: 'Edit notes',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateHeader(DateTime day, List<EntryWithId> dayEntries) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _formatDateHeader(day).toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Colors.grey[500],
              letterSpacing: 0.6,
            ),
          ),
          Text(
            _dayTotalLabel(dayEntries),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  /// The history list, grouped by date with a header per day, and its
  /// overall header. Swipe left to delete an entry. Used as the right-hand
  /// panel on desktop, and as the other toggle-able panel on mobile.
  Widget _buildHistoryPanel(List<EntryWithId> completedEntries) {
    final groups = _groupEntriesByDate(completedEntries);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              const Text(
                'History',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              if (completedEntries.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${completedEntries.length}',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey[600]),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: completedEntries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceMuted,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.inbox_outlined, size: 30, color: Colors.grey[400]),
                      ),
                      const SizedBox(height: 12),
                      Text('No history yet',
                          style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('Completed sessions will show up here',
                          style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: groups.length,
                  itemBuilder: (context, groupIndex) {
                    final day = groups[groupIndex].key;
                    final dayEntries = groups[groupIndex].value;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildDateHeader(day, dayEntries),
                        ...dayEntries.map(_buildHistoryEntryCard),
                      ],
                    );
                  },
                ),
        ),
      ],
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
          // Mobile-only toggle between the session view and the history
          // view — desktop always shows both side by side, so this button
          // is unnecessary (and hidden) there.
          if (!_isDesktop)
            IconButton(
              icon: Icon(_showHistoryOnMobile
                  ? Icons.timer_outlined
                  : Icons.history_rounded),
              tooltip: _showHistoryOnMobile
                  ? 'Show current session'
                  : 'Show history',
              onPressed: () {
                setState(() => _showHistoryOnMobile = !_showHistoryOnMobile);
              },
            ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: _addManualEntry,
            tooltip: 'Add manual entry',
          ),
          // Secondary, less-frequent actions live under an overflow menu so
          // the AppBar doesn't turn into a row of five competing icons.
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            onSelected: (value) async {
              switch (value) {
                case 'report':
                  await _showMonthlyReport();
                  break;
                  case 'analysis':
  await showGraphicalAnalysisDialog(
    context,
    entries: _entries,
    targetHours: _targetHours,
  );
  break;
                case 'refresh':
                  await _loadEntries();
                  break;
                case 'clear':
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                      title: const Text('Clear All Data'),
                      content: const Text(
                          'Are you sure you want to delete all entries? This cannot be undone.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete All'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await TimeDb.clearAll();
                    await _loadEntries();
                  }
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'report',
                child: ListTile(
                  leading: Icon(Icons.calendar_month_outlined),
                  title: Text('Monthly report'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
  value: 'analysis',
  child: ListTile(
    leading: Icon(Icons.bar_chart_rounded),
    title: Text('Graphical analysis'),
    contentPadding: EdgeInsets.zero,
  ),
),
              const PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'clear',
                child: const ListTile(
                  leading: Icon(Icons.delete_forever_outlined, color: AppColors.danger),
                  title: Text('Clear all data', style: TextStyle(color: AppColors.danger)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isDesktop
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _buildSessionPanel(),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 4,
                      child: _buildHistoryPanel(completedEntries),
                    ),
                  ],
                )
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _showHistoryOnMobile
                      ? KeyedSubtree(
                          key: const ValueKey('history'),
                          child: _buildHistoryPanel(completedEntries),
                        )
                      : KeyedSubtree(
                          key: const ValueKey('session'),
                          child: _buildSessionPanel(),
                        ),
                ),
    );
  }
}