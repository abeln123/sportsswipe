import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../card/card_spec.dart';
import '../card/sport_card.dart';
import '../core/format.dart' as f;
import '../core/theme.dart';
import 'research_chart.dart';

/// The same research object in the analyst and in a conversation.
class ResearchReport extends StatefulWidget {
  const ResearchReport(this.report, {super.key, this.snapshot = false});
  final Map<String, dynamic> report;
  final bool snapshot;
  @override
  State<ResearchReport> createState() => _ResearchReportState();
}

class _ResearchReportState extends State<ResearchReport> {
  int? _selected;
  bool _log = false, _method = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.report;
    final spec = a['card'] == null
        ? null
        : CardSpec.fromJson((a['card'] as Map).cast<String, dynamic>());
    if (a['kind'] == 'analysis') return _AnalysisReport(a);
    if (a['kind'] != 'form') {
      return Text(
        a['answer']?.toString() ?? 'No results available.',
        style: T.body,
      );
    }
    final m = (a['metric'] as Map).cast<String, dynamic>();
    final games = (a['games'] as List).cast<Map<String, dynamic>>();
    if (games.isEmpty) {
      return Text(
        a['answer']?.toString() ?? 'No matching completed games.',
        style: T.body,
      );
    }
    final values = games.map((g) => (g['value'] as num).toDouble()).toList();
    final average = (m['average'] as num).toDouble();
    final market = (a['playable'] as Map?)?['market'] as Map?;
    final lock = DateTime.tryParse(market?['lockAt']?.toString() ?? '');
    final requestedLine = (m['requestedLine'] as num?)?.toDouble();
    final currentLine =
        widget.snapshot || (lock != null && lock.isAfter(DateTime.now()))
        ? (m['line'] as num?)?.toDouble()
        : null;
    final line = requestedLine ?? currentLine;
    final above = requestedLine == null
        ? m['aboveLine']
        : m['aboveRequestedLine'];
    final unit = a['statLabel'].toString().toLowerCase().split(' ').last;
    final singular = unit.endsWith('s')
        ? unit.substring(0, unit.length - 1)
        : unit;
    final focusLine = a['focus'] == 'line' && line != null;
    final peak = values.isEmpty ? 0.0 : values.reduce(math.max);
    final peakIndex = values.indexOf(peak);
    final rest = [...values];
    if (rest.isNotEmpty) rest.removeAt(peakIndex);
    final insight = rest.isNotEmpty && peak > average * 1.4
        ? 'The ${f.line(peak)}-$singular game against ${games[peakIndex]['opponent']} lifted the average. The other ${rest.length} games ranged from ${f.line(rest.reduce(math.min))} to ${f.line(rest.reduce(math.max))}.'
        : '${games.length} completed games, ranging from ${f.line(m['rangeMin'] as num)} to ${f.line(m['rangeMax'] as num)}.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (spec != null) ...[
              JerseyIcon(spec: spec, size: 48),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(spec?.fullName ?? 'Recent form', style: T.h2),
                  Text(
                    '${a['statLabel']} · Last ${games.length} games',
                    style: T.small,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          focusLine
              ? '$above of ${games.length} games'
              : '${f.line(average)} $unit per game',
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            height: 1.1,
            color: C.text,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          focusLine
              ? 'Finished above ${f.line(line)} ${a['statLabel'].toString().toLowerCase()}.'
              : insight,
          style: T.dim,
        ),
        const SizedBox(height: 20),
        if (line != null)
          Text(
            '${widget.snapshot
                ? 'Line when shared'
                : requestedLine != null && requestedLine != currentLine
                ? 'Requested line'
                : "Today’s line"} · ${f.line(line)}',
            style: T.small.copyWith(
              color: C.green,
              fontWeight: FontWeight.w700,
            ),
          ),
        const SizedBox(height: 10),
        ResearchBarChart(
          bars: [
            for (final (i, g) in games.indexed)
              {
                'label': g['opponent'],
                'value': g['value'],
                'detail': i == games.length - 1
                    ? 'Latest'
                    : (focusLine && values[i] > line
                          ? 'Above'
                          : f.shortDate(DateTime.parse(g['date'] as String))),
              },
          ],
          threshold: line,
          selected: _selected,
          latest: games.length - 1,
          onSelected: (i) => setState(() => _selected = i),
        ),
        if (_selected != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            decoration: const BoxDecoration(
              color: C.surface,
              border: Border(left: BorderSide(color: C.green, width: 2)),
            ),
            child: Text(
              _detail(games[_selected!], line, a['statLabel'] as String),
              style: T.small.copyWith(color: C.text),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'ESPN box scores · Latest game ${f.shortDate(DateTime.parse(games.last['date'] as String))}',
                style: T.small.copyWith(fontSize: 10.5),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _log = !_log),
              child: Text(_log ? 'Hide log' : 'Game log'),
            ),
          ],
        ),
        if (_log)
          for (final g in games)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _detail(g, line, a['statLabel'] as String),
                style: T.small,
              ),
            ),
        TextButton(
          onPressed: () => setState(() => _method = !_method),
          child: Text(
            _method ? '− Data & method' : '+ Data & method',
            style: T.small,
          ),
        ),
        if (_method) ...[
          Text(a['definition'] as String, style: T.small),
          for (final s in (a['sources'] as List).cast<Map<String, dynamic>>())
            TextButton(
              onPressed: () => launchUrl(Uri.parse(s['url'] as String)),
              child: Text(s['label'] as String),
            ),
        ],
      ],
    );
  }

  String _detail(Map<String, dynamic> g, double? line, String stat) {
    final v = (g['value'] as num).toDouble();
    final delta = line == null
        ? ''
        : v == line
        ? ' · At the line'
        : ' · ${f.line((v - line).abs())} ${v > line ? 'above' : 'below'} ${widget.snapshot ? 'shared' : "today’s"} line';
    return '${f.shortDate(DateTime.parse(g['date'] as String))} vs ${g['opponent']} · ${f.line(v)} ${stat.toLowerCase()}$delta';
  }
}

class _AnalysisReport extends StatefulWidget {
  const _AnalysisReport(this.report);
  final Map<String, dynamic> report;
  @override
  State<_AnalysisReport> createState() => _AnalysisReportState();
}

class _AnalysisReportState extends State<_AnalysisReport> {
  int? _selected;
  bool _log = false, _method = false;
  int _visible = 20;
  @override
  Widget build(BuildContext context) {
    final a = widget.report;
    final chart = (a['chart'] as Map?)?.cast<String, dynamic>() ?? {};
    final bars = ((chart['bars'] as List?) ?? [])
        .map((b) => (b as Map).cast<String, dynamic>())
        .toList();
    final games = ((a['games'] as List?) ?? [])
        .map((g) => (g as Map).cast<String, dynamic>())
        .toList();
    final sources = ((a['sources'] as List?) ?? [])
        .map((s) => (s as Map).cast<String, dynamic>())
        .toList();
    final spec = a['card'] == null
        ? null
        : CardSpec.fromJson((a['card'] as Map).cast<String, dynamic>());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (spec != null) ...[
              JerseyIcon(spec: spec, size: 42),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a['subjectName']?.toString() ?? 'Research', style: T.h2),
                  const SizedBox(height: 4),
                  Text(
                    a['scope']?.toString() ?? '',
                    style: T.small.copyWith(height: 1.6),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          a['headline']?.toString() ?? '',
          style: const TextStyle(
            fontSize: 29,
            height: 1.2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(a['answer']?.toString() ?? '', style: T.body),
        if ((a['interpretation']?.toString() ?? '').isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            a['interpretation'] as String,
            style: T.dim.copyWith(height: 1.65),
          ),
        ],
        const SizedBox(height: 24),
        Text(
          chart['label']?.toString() ?? a['statLabel']?.toString() ?? '',
          style: T.small.copyWith(color: C.text, fontWeight: FontWeight.w600),
        ),
        if (chart['threshold'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Comparison threshold · ${f.line(chart['threshold'] as num)}',
              style: T.small.copyWith(color: C.green),
            ),
          ),
        const SizedBox(height: 4),
        ResearchBarChart(
          bars: bars,
          threshold: (chart['threshold'] as num?)?.toDouble(),
          operator: chart['operator'] as String? ?? 'gt',
          percent: chart['percent'] == true,
          emphasis: ((chart['emphasis'] as List?) ?? [])
              .map((v) => (v as num).toInt())
              .toList(),
          latest: (chart['latest'] as num?)?.toInt(),
          selected: _selected,
          onSelected: (i) => setState(() => _selected = i),
        ),
        if (chart['caption'] != null)
          Text(
            chart['caption'] as String,
            style: T.small.copyWith(fontSize: 10.5),
          ),
        if (_selected != null && _selected! < bars.length) ...[
          const SizedBox(height: 10),
          Text(
            '${bars[_selected!]['label']} · ${bars[_selected!]['detail'] ?? ''} · ${f.line(bars[_selected!]['value'] as num)}${chart['percent'] == true ? '%' : ' ${a['statLabel'].toString().toLowerCase()}'}',
            style: T.small.copyWith(color: C.text),
          ),
        ],
        const SizedBox(height: 20),
        const Divider(color: C.line),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Text(
              'Database + ESPN · ${games.length} verified games',
              style: T.small.copyWith(fontSize: 10.5),
            ),
            TextButton(
              onPressed: () => setState(() => _log = !_log),
              child: Text(_log ? 'Hide log' : 'Game log'),
            ),
          ],
        ),
        if (_log) ...[
          for (final g in games.reversed.take(_visible))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: C.line)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${g['home'] == true ? 'vs' : 'at'} ${g['opponent']}',
                          style: T.small.copyWith(
                            color: C.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${f.shortDate(DateTime.parse(g['date'] as String))} ${DateTime.parse(g['date'] as String).toLocal().year}',
                          style: T.small,
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          a['statLabel'] == 'Game results'
                              ? '${g['result']} · ${g['pointsFor']}–${g['pointsAgainst']}'
                              : '${f.line(g['value'] as num)} · ${g['result']}',
                          style: T.small.copyWith(color: C.text),
                        ),
                        if (g['restDays'] != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${g['restDays']} days between games',
                              style: T.small,
                              textAlign: TextAlign.right,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (_visible < games.length)
            TextButton(
              onPressed: () => setState(() => _visible += 20),
              child: const Text('Show 20 more games'),
            ),
        ],
        TextButton(
          onPressed: () => setState(() => _method = !_method),
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.zero,
          ),
          child: Text(
            _method ? '− Data & method' : '+ Data & method',
            style: T.small,
          ),
        ),
        if (_method) ...[
          Text(
            a['definition']?.toString() ?? '',
            style: T.small.copyWith(height: 1.7),
          ),
          for (final warning in ((a['warnings'] as List?) ?? []))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                warning.toString(),
                style: T.small.copyWith(height: 1.7),
              ),
            ),
          const SizedBox(height: 12),
          for (final source in sources.reversed.take(_visible))
            TextButton(
              onPressed: () {
                final uri = Uri.tryParse(source['url']?.toString() ?? '');
                if (uri != null && uri.scheme == 'https') launchUrl(uri);
              },
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.zero,
              ),
              child: Text(
                source['label']?.toString() ?? 'ESPN source',
                style: T.small.copyWith(color: C.green),
              ),
            ),
        ] else if (((a['warnings'] as List?) ?? []).isNotEmpty)
          Text(
            (a['warnings'] as List).first.toString(),
            style: T.small.copyWith(height: 1.65),
          ),
      ],
    );
  }
}
