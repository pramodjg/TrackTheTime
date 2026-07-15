import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:trackthetime/main.dart' show AppColors;
import 'package:trackthetime/timedb.dart';

/// Entry point — call this from the overflow menu. Shows a tabbed dialog:
/// "This Week" (grouped bar chart of work vs break per day) and "Trend"
/// (line chart of daily work hours across a chosen month, with the daily
/// target overlaid).
Future<void> showGraphicalAnalysisDialog(
  BuildContext context, {
  required List<EntryWithId> entries,
  required double targetHours,
}) {
  return showDialog(
    context: context,
    builder: (context) => _GraphicalAnalysisDialog(
      entries: entries,
      targetHours: targetHours,
    ),
  );
}

class _GraphicalAnalysisDialog extends StatelessWidget {
  final List<EntryWithId> entries;
  final double targetHours;

  const _GraphicalAnalysisDialog({
    required this.entries,
    required this.targetHours,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Graphical Analysis'),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          height: 440,
          child: Column(
            children: [
              const TabBar(
                labelColor: AppColors.work,
                unselectedLabelColor: Colors.grey,
                indicatorColor: AppColors.work,
                tabs: [
                  Tab(text: 'This Week'),
                  Tab(text: 'Trend'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  children: [
                    _WeeklyTab(entries: entries),
                    _TrendTab(targetHours: targetHours),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// "This Week" tab — grouped bar chart, work vs break, last 7 days.
// ---------------------------------------------------------------------------

class _DayTotals {
  final DateTime day;
  final int workSeconds;
  final int breakSeconds;
  _DayTotals(this.day, this.workSeconds, this.breakSeconds);
}

class _WeeklyTab extends StatelessWidget {
  final List<EntryWithId> entries;
  const _WeeklyTab({required this.entries});

  List<_DayTotals> _computeLast7Days() {
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    final days = List.generate(
      7,
      (i) => todayStart.subtract(Duration(days: 6 - i)),
    );

    return days.map((day) {
      int work = 0;
      int brk = 0;
      for (final e in entries) {
        final c = e.entry.checkIn;
        if (c.year == day.year && c.month == day.month && c.day == day.day) {
          if (e.entry.isWorkSession) {
            work += e.entry.duration.inSeconds;
          } else {
            brk += e.entry.duration.inSeconds;
          }
        }
      }
      return _DayTotals(day, work, brk);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final data = _computeLast7Days();
    final hasData = data.any((d) => d.workSeconds + d.breakSeconds > 0);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _legendDot(AppColors.work, 'Work'),
            const SizedBox(width: 16),
            _legendDot(AppColors.breakColor, 'Break'),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: hasData
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _WeeklyBarChartPainter(data: data),
                  ),
                )
              : Center(
                  child: Text(
                    'No entries in the last 7 days',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _WeeklyBarChartPainter extends CustomPainter {
  final List<_DayTotals> data;
  _WeeklyBarChartPainter({required this.data});

  @override
  void paint(Canvas canvas, Size size) {
    const leftAxisWidth = 34.0;
    const bottomAxisHeight = 22.0;
    final chartWidth = size.width - leftAxisWidth;
    final chartHeight = size.height - bottomAxisHeight;

    final maxSeconds = data
        .map((d) => math.max(d.workSeconds, d.breakSeconds))
        .fold<int>(3600, (a, b) => math.max(a, b));
    // Round the axis max up to a clean number of hours for readable grid
    // lines instead of an arbitrary max entry duration.
    final maxHours = (maxSeconds / 3600).ceil().clamp(1, 24);

    final gridPaint = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 1;
    final textStyle = TextStyle(color: Colors.grey[600], fontSize: 10);

    // Horizontal grid lines + y-axis hour labels
    const gridLines = 4;
    for (int i = 0; i <= gridLines; i++) {
      final y = chartHeight - (chartHeight / gridLines) * i;
      canvas.drawLine(
        Offset(leftAxisWidth, y),
        Offset(size.width, y),
        gridPaint,
      );
      final hourLabel = (maxHours / gridLines * i).round();
      final tp = TextPainter(
        text: TextSpan(text: '${hourLabel}h', style: textStyle),
     
      )..layout();
      tp.paint(canvas, Offset(leftAxisWidth - tp.width - 6, y - tp.height / 2));
    }

    // Bars
    final slotWidth = chartWidth / data.length;
    final barWidth = (slotWidth * 0.28).clamp(6.0, 22.0);
    final maxChartSeconds = maxHours * 3600;

    for (int i = 0; i < data.length; i++) {
      final d = data[i];
      final slotCenter = leftAxisWidth + slotWidth * i + slotWidth / 2;

      final workHeight = maxChartSeconds == 0
          ? 0.0
          : (d.workSeconds / maxChartSeconds) * chartHeight;
      final breakHeight = maxChartSeconds == 0
          ? 0.0
          : (d.breakSeconds / maxChartSeconds) * chartHeight;

      final workRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(
          slotCenter - barWidth - 3,
          chartHeight - workHeight,
          barWidth,
          workHeight,
        ),
        topLeft: const Radius.circular(3),
        topRight: const Radius.circular(3),
      );
      final breakRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(
          slotCenter + 3,
          chartHeight - breakHeight,
          barWidth,
          breakHeight,
        ),
        topLeft: const Radius.circular(3),
        topRight: const Radius.circular(3),
      );

      canvas.drawRRect(workRect, Paint()..color = AppColors.work);
      canvas.drawRRect(breakRect, Paint()..color = AppColors.breakColor);

      final dayLabel = DateFormat('E').format(d.day);
      final tp = TextPainter(
        text: TextSpan(text: dayLabel, style: textStyle),
      
      )..layout();
      tp.paint(
        canvas,
        Offset(slotCenter - tp.width / 2, chartHeight + 6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WeeklyBarChartPainter oldDelegate) =>
      oldDelegate.data != data;
}

// ---------------------------------------------------------------------------
// "Trend" tab — line chart of daily work hours across a chosen month.
// ---------------------------------------------------------------------------

class _TrendTab extends StatefulWidget {
  final double targetHours;
  const _TrendTab({required this.targetHours});

  @override
  State<_TrendTab> createState() => _TrendTabState();
}

class _TrendTabState extends State<_TrendTab> {
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, int>>(
      future: TimeDb.getMonthlyWorkSeconds(_selectedMonth.year, _selectedMonth.month),
      builder: (context, snapshot) {
        final dailyTotals = snapshot.data ?? {};
        final daysInMonth =
            DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0).day;

        final points = List.generate(daysInMonth, (i) {
          final day = i + 1;
          final key = DateTime(_selectedMonth.year, _selectedMonth.month, day)
              .toIso8601String()
              .substring(0, 10);
          return dailyTotals[key] ?? 0;
        });

        final hasData = points.any((s) => s > 0);

        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() {
                    _selectedMonth =
                        DateTime(_selectedMonth.year, _selectedMonth.month - 1);
                  }),
                ),
                Text(
                  DateFormat('MMMM yyyy').format(_selectedMonth),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _selectedMonth.year == DateTime.now().year &&
                          _selectedMonth.month == DateTime.now().month
                      ? null
                      : () => setState(() {
                            _selectedMonth = DateTime(
                                _selectedMonth.year, _selectedMonth.month + 1);
                          }),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: snapshot.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator())
                  : !hasData
                      ? Center(
                          child: Text(
                            'No entries this month',
                            style: TextStyle(color: Colors.grey[500]),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: _TrendLinePainter(
                              dailySeconds: points,
                              targetHours: widget.targetHours,
                            ),
                          ),
                        ),
            ),
          ],
        );
      },
    );
  }
}

class _TrendLinePainter extends CustomPainter {
  final List<int> dailySeconds; // index 0 == day 1
  final double targetHours;
  _TrendLinePainter({required this.dailySeconds, required this.targetHours});

  @override
  void paint(Canvas canvas, Size size) {
    const leftAxisWidth = 34.0;
    const bottomAxisHeight = 20.0;
    final chartWidth = size.width - leftAxisWidth;
    final chartHeight = size.height - bottomAxisHeight;

    final maxSeconds = dailySeconds.fold<int>(
      (targetHours * 3600).round(),
      (a, b) => math.max(a, b),
    );
    final maxHours = (maxSeconds / 3600).ceil().clamp(1, 24);
    final maxChartSeconds = maxHours * 3600;

    final gridPaint = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 1;
    final textStyle = TextStyle(color: Colors.grey[600], fontSize: 10);

    const gridLines = 4;
    for (int i = 0; i <= gridLines; i++) {
      final y = chartHeight - (chartHeight / gridLines) * i;
      canvas.drawLine(Offset(leftAxisWidth, y), Offset(size.width, y), gridPaint);
      final hourLabel = (maxHours / gridLines * i).round();
      final tp = TextPainter(
        text: TextSpan(text: '${hourLabel}h', style: textStyle),
        
      )..layout();
      tp.paint(canvas, Offset(leftAxisWidth - tp.width - 6, y - tp.height / 2));
    }

    double xFor(int index) =>
        leftAxisWidth + (chartWidth / (dailySeconds.length - 1)) * index;
    double yFor(int seconds) =>
        chartHeight - (seconds / maxChartSeconds) * chartHeight;

    // Dashed target line
    final targetY = yFor((targetHours * 3600).round());
    final dashPaint = Paint()
      ..color = AppColors.success
      ..strokeWidth = 1.5;
    const dashWidth = 5.0;
    const dashGap = 4.0;
    double startX = leftAxisWidth;
    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, targetY),
        Offset(math.min(startX + dashWidth, size.width), targetY),
        dashPaint,
      );
      startX += dashWidth + dashGap;
    }

    // Line + points, skipping zero-value days so the line doesn't dive to
    // the axis on days with no entries at all.
    final linePaint = Paint()
      ..color = AppColors.work
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()..color = AppColors.work;

    Path? path;
    for (int i = 0; i < dailySeconds.length; i++) {
      if (dailySeconds[i] <= 0) continue;
      final point = Offset(xFor(i), yFor(dailySeconds[i]));
      if (path == null) {
        path = Path()..moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawCircle(point, 2.5, dotPaint);
    }
    if (path != null) canvas.drawPath(path, linePaint);

    // X-axis labels — every 5th day to avoid crowding.
    for (int i = 0; i < dailySeconds.length; i += 5) {
      final tp = TextPainter(
        text: TextSpan(text: '${i + 1}', style: textStyle),
       
      )..layout();
      tp.paint(canvas, Offset(xFor(i) - tp.width / 2, chartHeight + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _TrendLinePainter oldDelegate) =>
      oldDelegate.dailySeconds != dailySeconds ||
      oldDelegate.targetHours != targetHours;
}