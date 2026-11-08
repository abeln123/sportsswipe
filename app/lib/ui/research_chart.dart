import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/format.dart' as f;
import '../core/theme.dart';

/// A single coordinate system for the grid, bars, zero and reference line.
@immutable
class ResearchChartScale {
  ResearchChartScale(
    List<double> values, {
    double? threshold,
    bool percent = false,
  }) {
    final low = math.min(
      0.0,
      [...values, ?threshold].fold<double>(0, math.min),
    );
    final high = math.max(
      1.0,
      [...values, ?threshold].fold<double>(0, math.max),
    );
    final raw = (high - low) / 3;
    final power = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final normalized = raw / power;
    final niceStep =
        (normalized <= 1
            ? 1
            : normalized <= 2
            ? 2
            : normalized <= 5
            ? 5
            : 10) *
        power;
    final integerData =
        values.every((v) => v == v.roundToDouble()) &&
        (threshold == null || threshold == threshold.roundToDouble());
    step = percent
        ? 25
        : integerData
        ? math.max(1, niceStep)
        : niceStep;
    minimum = (low / step).floor() * step;
    final upper = percent ? 100.0 : math.max(step, (high / step).ceil() * step);
    maximum = upper == minimum ? upper + step : upper;
  }
  late final double step;
  late final double minimum;
  late final double maximum;
  double y(double value, double height) =>
      height * (maximum - value) / (maximum - minimum);
  List<double> get ticks => [
    for (double v = minimum; v <= maximum + step * .01; v += step) v,
  ];
}

class ResearchBarChart extends StatelessWidget {
  const ResearchBarChart({
    super.key,
    required this.bars,
    this.threshold,
    this.operator = 'gt',
    this.percent = false,
    this.emphasis = const [],
    this.latest,
    this.selected,
    required this.onSelected,
  });
  final List<Map<String, dynamic>> bars;
  final double? threshold;
  final String operator;
  final bool percent;
  final List<int> emphasis;
  final int? latest, selected;
  final ValueChanged<int> onSelected;

  bool _hit(double value) => threshold == null
      ? false
      : switch (operator) {
          'gte' => value >= threshold!,
          'lt' => value < threshold!,
          'lte' => value <= threshold!,
          'eq' => value == threshold!,
          _ => value > threshold!,
        };

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) return const SizedBox.shrink();
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    final values = bars.map((b) => (b['value'] as num).toDouble()).toList();
    final scale = ResearchChartScale(
      values,
      threshold: threshold,
      percent: percent,
    );
    const plotHeight = 154.0;
    final top = 28 * textScale, labels = 56 * textScale;
    final height = top + plotHeight + labels;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = 34.0 * textScale;
        final width = math.max(
          constraints.maxWidth,
          gutter + 4 + bars.length * 44 * textScale,
        );
        final column = (width - gutter - 4) / bars.length;
        final barWidth = math.min(34.0, column * .53);
        final zero = top + scale.y(0, plotHeight);
        final plot = SizedBox(
          height: height,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    top: top,
                    width: width,
                    height: plotHeight,
                    child: ExcludeSemantics(
                      child: CustomPaint(
                        painter: _ChartGrid(
                          scale,
                          gutter,
                          threshold,
                          textScale,
                        ),
                      ),
                    ),
                  ),
                  for (final (i, bar) in bars.indexed) ...[
                    Positioned(
                      left: gutter + i * column,
                      top: 0,
                      width: column,
                      height: height,
                      child: Semantics(
                        button: true,
                        selected: selected == i,
                        label:
                            '${bar['label']}, ${bar['detail'] ?? ''}, ${f.line(values[i])}${percent ? ' percent' : ''}${i == latest ? ', latest' : ''}',
                        child: InkWell(
                          onTap: () => onSelected(i),
                          child: ExcludeSemantics(
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  key: ValueKey('research-bar-$i'),
                                  left: (column - barWidth) / 2,
                                  top: math.min(
                                    zero,
                                    top + scale.y(values[i], plotHeight),
                                  ),
                                  width: barWidth,
                                  height: math.max(
                                    1,
                                    (scale.y(values[i], plotHeight) -
                                            scale.y(0, plotHeight))
                                        .abs(),
                                  ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color:
                                          emphasis.contains(i) ||
                                              _hit(values[i])
                                          ? C.green
                                          : const Color(0xFFA9BDB3),
                                      border: selected == i
                                          ? Border.all(color: C.text, width: 2)
                                          : null,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top:
                                      (top +
                                              scale.y(values[i], plotHeight) +
                                              (values[i] < 0
                                                  ? 4
                                                  : -24 * textScale))
                                          .clamp(
                                            0,
                                            top + plotHeight - 18 * textScale,
                                          ),
                                  child: Text(
                                    '${f.line(values[i])}${percent ? '%' : ''}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: C.text,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: top + plotHeight + 10,
                                  height: labels - 10,
                                  child: Column(
                                    children: [
                                      Text(
                                        bar['label']?.toString() ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: C.text,
                                          height: 1.2,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        bar['detail']?.toString() ??
                                            (i == latest ? 'Latest' : ''),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 9,
                                          color: C.dim,
                                          height: 1.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            plot,
            if (width > constraints.maxWidth + 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Scroll chart for more games →',
                  style: T.small.copyWith(fontSize: 10),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ChartGrid extends CustomPainter {
  const _ChartGrid(this.scale, this.gutter, this.threshold, this.textScale);
  final ResearchChartScale scale;
  final double gutter, textScale;
  final double? threshold;
  @override
  void paint(Canvas canvas, Size size) {
    for (final tick in scale.ticks) {
      final y = scale.y(tick, size.height);
      canvas.drawLine(
        Offset(gutter, y),
        Offset(size.width, y),
        Paint()
          ..color = tick == 0 ? C.faint : C.line
          ..strokeWidth = tick == 0 ? 1 : .6,
      );
      final text = TextPainter(
        text: TextSpan(
          text: f.line(tick),
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 9 * textScale,
            color: C.dim,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: gutter - 5);
      text.paint(
        canvas,
        Offset(math.max(0, gutter - 7 - text.width), y - text.height / 2),
      );
    }
    if (threshold != null) {
      final y = scale.y(threshold!, size.height);
      for (double x = gutter; x < size.width; x += 8) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 4, size.width), y),
          Paint()
            ..color = C.green.withValues(alpha: .7)
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ChartGrid old) =>
      old.scale.minimum != scale.minimum ||
      old.scale.maximum != scale.maximum ||
      old.scale.step != scale.step ||
      old.threshold != threshold ||
      old.textScale != textScale;
}
