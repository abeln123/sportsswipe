import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../card/card_spec.dart';
import '../card/sport_card.dart';
import '../core/format.dart' as f;
import '../core/theme.dart';

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
    final spec = a['card'] == null ? null : CardSpec.fromJson((a['card'] as Map).cast<String, dynamic>());
    if (a['kind'] != 'form') return Text(a['answer']?.toString() ?? 'No results available.', style: T.body);
    final m = (a['metric'] as Map).cast<String, dynamic>();
    final games = (a['games'] as List).cast<Map<String, dynamic>>();
    final values = games.map((g) => (g['value'] as num).toDouble()).toList();
    final average = (m['average'] as num).toDouble();
    final market = (a['playable'] as Map?)?['market'] as Map?;
    final lock = DateTime.tryParse(market?['lockAt']?.toString() ?? '');
    final requestedLine = (m['requestedLine'] as num?)?.toDouble();
    final currentLine = widget.snapshot || (lock != null && lock.isAfter(DateTime.now())) ? (m['line'] as num?)?.toDouble() : null;
    final line = requestedLine ?? currentLine;
    final above = requestedLine == null ? m['aboveLine'] : m['aboveRequestedLine'];
    final unit = a['statLabel'].toString().toLowerCase().split(' ').last;
    final singular = unit.endsWith('s') ? unit.substring(0, unit.length - 1) : unit;
    final focusLine = a['focus'] == 'line' && line != null;
    final peak = values.isEmpty ? 0.0 : values.reduce(math.max);
    final peakIndex = values.indexOf(peak);
    final rest = [...values];
    if (rest.isNotEmpty) rest.removeAt(peakIndex);
    final insight = rest.isNotEmpty && peak > average * 1.4
        ? 'The ${f.line(peak)}-$singular game against ${games[peakIndex]['opponent']} lifted the average. The other ${rest.length} games ranged from ${f.line(rest.reduce(math.min))} to ${f.line(rest.reduce(math.max))}.'
        : '${games.length} completed games, ranging from ${f.line(m['rangeMin'] as num)} to ${f.line(m['rangeMax'] as num)}.';
    final labelHeight = MediaQuery.textScalerOf(context).scale(32);
    final chartHeight = 132 + MediaQuery.textScalerOf(context).scale(54);
    final maxV = math.max(1.0, math.max(peak, line ?? 0)) * 1.15;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (spec != null) ...[JerseyIcon(spec: spec, size: 48), const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(spec?.fullName ?? 'Recent form', style: T.h2),
                  Text('${a['statLabel']} · Last ${games.length} games', style: T.small),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          focusLine ? '$above of ${games.length} games' : '${f.line(average)} $unit per game',
          style: const TextStyle(fontFamily: kCondensed, fontSize: 38, fontWeight: FontWeight.w800, height: 1.05, color: C.text),
        ),
        const SizedBox(height: 8),
        Text(focusLine ? 'Finished above ${f.line(line)} ${a['statLabel'].toString().toLowerCase()}.' : insight, style: T.dim),
        const SizedBox(height: 20),
        if (line != null)
          Text(
            '${widget.snapshot
                ? 'Line when shared'
                : requestedLine != null && requestedLine != currentLine
                ? 'Requested line'
                : "Today’s line"} · ${f.line(line)}',
            style: T.small,
          ),
        const SizedBox(height: 10),
        SizedBox(
          height: chartHeight,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: math.max(constraints.maxWidth, games.length * MediaQuery.textScalerOf(context).scale(50)),
                child: Stack(
                  children: [
                    if (line != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: labelHeight + 6 + 116 * line / maxV,
                        child: Container(height: 1, color: C.dim.withValues(alpha: .65)),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final (i, g) in games.indexed)
                          Expanded(
                            child: Semantics(
                              button: true,
                              selected: _selected == i,
                              label:
                                  '${g['opponent']}, ${f.shortDate(DateTime.parse(g['date'] as String))}, ${f.line(g['value'] as num)} ${a['statLabel']}${i == games.length - 1 ? ', latest' : ''}',
                              child: InkWell(
                                onTap: () => setState(() => _selected = i),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Text(f.line(g['value'] as num), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                    const SizedBox(height: 5),
                                    Container(
                                      width: 30,
                                      height: math.max(2, 116 * values[i] / maxV),
                                      decoration: BoxDecoration(
                                        color: focusLine && values[i] > line ? C.green : const Color(0xFFACC0B7),
                                        border: _selected == i ? Border.all(color: C.text, width: 2) : null,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    SizedBox(
                                      height: labelHeight,
                                      child: Column(
                                        children: [
                                          Text(g['opponent'] as String, style: T.small.copyWith(color: C.text)),
                                          Text(
                                            i == games.length - 1 ? 'Latest' : (focusLine && values[i] > line ? 'Above' : ''),
                                            style: const TextStyle(fontSize: 9, color: C.dim),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
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
            child: Text(_detail(games[_selected!], line, a['statLabel'] as String), style: T.small.copyWith(color: C.text)),
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
            TextButton(onPressed: () => setState(() => _log = !_log), child: Text(_log ? 'Hide log' : 'Game log')),
          ],
        ),
        if (_log)
          for (final g in games)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_detail(g, line, a['statLabel'] as String), style: T.small),
            ),
        TextButton(
          onPressed: () => setState(() => _method = !_method),
          child: Text(_method ? '− Data & method' : '+ Data & method', style: T.small),
        ),
        if (_method) ...[
          Text(a['definition'] as String, style: T.small),
          const SizedBox(height: 6),
          const Text('Past results describe this sample; they are not a probability for the next game.', style: T.small),
          for (final s in (a['sources'] as List).cast<Map<String, dynamic>>())
            TextButton(onPressed: () => launchUrl(Uri.parse(s['url'] as String)), child: Text(s['label'] as String)),
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
