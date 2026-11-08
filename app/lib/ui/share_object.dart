import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../card/card_spec.dart';
import '../card/sport_card.dart';
import 'research_report.dart';
import 'widgets.dart';

Future<void> shareObject(BuildContext context, {String? shareId, Map<String, dynamic>? source}) async {
  try {
    final id = shareId ?? (await api.post('/shares', source))['shareId'] as String;
    final responses = await Future.wait([api.get('/friends'), api.get('/threads')]);
    if (!context.mounted) return;
    await showSheet<void>(
      context,
      (ctx) => _ShareSheet(
        id: id,
        friends: (responses[0]['friends'] as List).cast<Map<String, dynamic>>(),
        threads: (responses[1]['threads'] as List).cast<Map<String, dynamic>>(),
      ),
    );
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message, ok: false);
  }
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.id, required this.friends, required this.threads});
  final String id;
  final List<Map<String, dynamic>> friends, threads;
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _comment = TextEditingController();
  String? _target;
  bool _busy = false;
  final _command = const Uuid().v4();
  String? _thread;
  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || _target == null) return;
    setState(() => _busy = true);
    try {
      _thread ??= _target!.startsWith('friend:')
          ? (await api.post('/threads/dm', {'userId': _target!.substring(7)}))['threadId'] as String
          : _target;
      await api.post('/threads/$_thread/messages', {'clientMsgId': _command, 'body': _comment.text.trim(), 'shareId': widget.id});
      if (mounted) {
        Navigator.pop(context);
        toast(context, 'Shared to the conversation.');
      }
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Send to your people', style: T.h2),
      const SizedBox(height: 8),
      TextField(
        controller: _comment,
        maxLength: 300,
        decoration: const InputDecoration(hintText: 'Would you take this line?'),
      ),
      if (widget.friends.isEmpty && widget.threads.isEmpty) ...[
        const Text('Invite a friend or join a league to start a conversation.', style: T.dim),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            context.go('/social');
          },
          child: const Text('Find your people'),
        ),
      ],
      for (final u in widget.friends) _row('friend:${u['userId']}', u['displayName'] as String, 'Friend'),
      for (final t in widget.threads.where((t) => t['kind'] == 'league')) _row(t['threadId'] as String, t['title'] as String, 'League'),
      const SizedBox(height: 12),
      PrimaryButton('Send', busy: _busy, onPressed: _target == null ? null : _send),
    ],
  );
  Widget _row(String id, String name, String detail) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: InitialsBadge(initialsOf(name)),
    title: Text(name),
    subtitle: Text(detail, style: T.small),
    trailing: Icon(_target == id ? Icons.check_circle : Icons.radio_button_unchecked, color: _target == id ? C.green : C.dim),
    onTap: _busy || _thread != null ? null : () => setState(() => _target = id),
  );
}

class SharedObject extends StatelessWidget {
  const SharedObject(this.item, {super.key});
  final Map<String, dynamic> item;
  @override
  Widget build(BuildContext context) {
    if (item['kind'] == 'unavailable') return const Text('This item is private.', style: T.small);
    final p = (item['payload'] as Map).cast<String, dynamic>();
    final spec = p['card'] == null ? null : CardSpec.fromJson((p['card'] as Map).cast<String, dynamic>());
    return InkWell(
      onTap: () {
        if (item['kind'] == 'head_to_head') {
          context.go('/duel/${p['token']}');
          return;
        }
        showSheet<void>(
          context,
          (_) => item['kind'] == 'research'
              ? ResearchReport(p, snapshot: true)
              : Column(
                  children: [
                    if (spec != null) SportCard(spec: spec, width: 280, finish: p['finish'] as String? ?? 'base'),
                    const SizedBox(height: 12),
                    Text(p['title']?.toString() ?? 'Shared card', style: T.h2),
                    for (final l in (p['legs'] as List? ?? []))
                      Text('${l['side']} ${l['line']} ${l['statLabel']} · ${l['result'] ?? 'Final'}', style: T.body),
                  ],
                ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          color: Color(0xFF203B32),
          border: Border(left: BorderSide(color: C.green, width: 2)),
        ),
        child: Row(
          children: [
            if (spec != null) ...[JerseyIcon(spec: spec, size: 40), const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(spec?.fullName ?? 'Shared pick', style: T.h3),
                  Text(
                    item['kind'] == 'research'
                        ? '${p['statLabel']} · ${p['metric']['games']} games'
                        : p['title']?.toString() ?? 'Earned card',
                    style: T.small,
                  ),
                  const SizedBox(height: 5),
                  if (item['kind'] == 'research') ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 32,
                      width: 140,
                      child: CustomPaint(painter: _MiniChart((p['games'] as List).map((g) => (g['value'] as num).toDouble()).toList())),
                    ),
                  ],
                  const SizedBox(height: 5),
                  const Text('Open detail ↗', style: TextStyle(color: C.green, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniChart extends CustomPainter {
  _MiniChart(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    final maxV = values.fold<double>(1, math.max);
    for (var i = 0; i < values.length; i++) {
      final w = size.width / values.length;
      final h = math.max(1.0, values[i] / maxV * size.height);
      canvas.drawRect(Rect.fromLTWH(i * w, size.height - h, w * .6, h), Paint()..color = const Color(0xFFACC0B7));
    }
  }

  @override
  bool shouldRepaint(_MiniChart old) => old.values != values;
}
