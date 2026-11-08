import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../card/card_spec.dart';
import '../card/sport_card.dart';
import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/theme.dart';
import '../state/pick_queue.dart';
import '../state/research.dart';
import '../state/session.dart';
import '../ui/research_report.dart';
import '../ui/share_object.dart';
import '../ui/swipe.dart';
import '../ui/widgets.dart';

class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});
  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  final _q = TextEditingController(), _scroll = ScrollController();
  late Future<Map<String, dynamic>> _suggestions = api.get(
    '/analyst/suggestions',
  );
  final _turns = <Map<String, dynamic>>[];
  bool _busy = false, _restored = false;
  String get _key => 'ss.ai.${ref.read(sessionProvider).value?.id}';
  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final key = _key;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    try {
      final raw = prefs.getString(key);
      if (raw != null) {
        _turns.addAll(
          (jsonDecode(raw) as List).map(
            (e) => (e as Map).cast<String, dynamic>(),
          ),
        );
      }
    } catch (_) {}
    setState(() => _restored = true);
    _consume(ref.read(researchRequestProvider));
  }

  void _consume(Map<String, dynamic>? r) {
    if (r == null || !_restored || _busy) return;
    ref.read(researchRequestProvider.notifier).clear();
    _ask(r['question'] as String, form: r['form'] as Map<String, dynamic>);
  }

  Future<void> _persist() async {
    final key = _key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(
        _turns.length > 10 ? _turns.sublist(_turns.length - 10) : _turns,
      ),
    );
  }

  Future<void> _ask(String question, {Map<String, dynamic>? form}) async {
    if (question.trim().isEmpty || _busy || !_restored) return;
    _q.clear();
    final turn = <String, dynamic>{'q': question};
    setState(() {
      _busy = true;
      _turns.add(turn);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (MediaQuery.of(context).disableAnimations) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      } else {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
    });
    try {
      turn['a'] = form != null
          ? await api.post('/analyst/form', form)
          : await api.post('/analyst/ask', {
              'question': question,
              'context': _turns
                  .where((t) => t != turn && t['a'] != null)
                  .toList()
                  .reversed
                  .take(3)
                  .toList()
                  .reversed
                  .map(
                    (t) => {
                      'question': t['q'],
                      'plan': (t['a'] as Map)['researchPlan'],
                    },
                  )
                  .toList(),
            });
    } on ApiException catch (e) {
      turn['a'] = {'kind': 'error', 'answer': e.message};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _persist();
    _consume(ref.read(researchRequestProvider));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(researchRequestProvider, (_, r) => _consume(r));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: C.bg,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: UnderTabs(
              labels: const ['Analyst'],
              index: 0,
              onChanged: (_) {},
              trailing: PopupMenuButton<String>(
                tooltip: 'Conversation menu',
                enabled: !_busy,
                padding: EdgeInsets.zero,
                onSelected: (_) {
                  setState(_turns.clear);
                  _persist();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'clear',
                    child: Text('Clear conversation'),
                  ),
                ],
                icon: const Icon(Icons.more_horiz, color: C.dim, size: 20),
              ),
            ),
          ),
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(child: PineBackdrop()),
              ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  if (_turns.isEmpty) ...[
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: C.green,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'SPORTS RESEARCH',
                          style: T.label.copyWith(color: C.green),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Ask about a player,\na team, or a pattern.',
                      style: T.h1,
                    ),
                    const SizedBox(height: 22),
                    const Text('FROM THE SLATE', style: T.label),
                    const SizedBox(height: 10),
                    FutureBuilder(
                      future: _suggestions,
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return ErrorText(
                            snap.error!,
                            onRetry: () => setState(() {
                              _suggestions = api.get('/analyst/suggestions');
                            }),
                          );
                        }
                        if (!snap.hasData) {
                          return const SizedBox(height: 280, child: Loading());
                        }
                        final questions = (snap.data!['suggestions'] as List)
                            .cast<Map<String, dynamic>>();
                        if (questions.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'No open player lines right now. Ask about recent games below.',
                              style: T.dim,
                            ),
                          );
                        }
                        return Column(
                          children: [
                            for (final x in questions)
                              InkWell(
                                onTap: () => _ask(
                                  x['label'] as String,
                                  form: {
                                    'playerId': x['playerId'],
                                    'statKey': x['statKey'],
                                    'n': 5,
                                  },
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 18,
                                  ),
                                  decoration: const BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(color: C.line),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      if (x['card'] != null) ...[
                                        JerseyIcon(
                                          spec: CardSpec.fromJson(
                                            (x['card'] as Map)
                                                .cast<String, dynamic>(),
                                          ),
                                          size: 42,
                                        ),
                                        const SizedBox(width: 14),
                                      ],
                                      Expanded(
                                        child: Text(
                                          x['label'] as String,
                                          style: T.body.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      const Icon(
                                        Icons.north_east,
                                        size: 18,
                                        color: C.green,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                  for (final (i, t) in _turns.indexed) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 14, bottom: 22),
                      child: Text(
                        t['q'] as String,
                        style: T.h2.copyWith(fontSize: 21, height: 1.35),
                      ),
                    ),
                    if (t['a'] != null)
                      _Answer(
                        (t['a'] as Map).cast<String, dynamic>(),
                        key: ValueKey(i),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: C.green,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Checking the database and game history…',
                                style: T.small,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 28),
                    const Divider(color: C.line),
                  ],
                ],
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: C.bg,
            border: Border(top: BorderSide(color: C.line)),
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
            decoration: BoxDecoration(
              color: const Color(0xFF0E241E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: C.line),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    maxLength: 500,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(
                      hintText: 'Ask about a player, team, or pattern…',
                      counterText: '',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    onSubmitted: _ask,
                  ),
                ),
                IconButton(
                  onPressed: _busy ? null : () => _ask(_q.text),
                  tooltip: 'Ask analyst',
                  style: IconButton.styleFrom(
                    backgroundColor: _busy ? C.disabled : C.green,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    minimumSize: const Size(36, 36),
                  ),
                  icon: Icon(
                    Icons.arrow_upward,
                    size: 18,
                    color: _busy ? C.dim : const Color(0xFF0D2416),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Answer extends ConsumerStatefulWidget {
  const _Answer(this.a, {super.key});
  final Map<String, dynamic> a;
  @override
  ConsumerState<_Answer> createState() => _AnswerState();
}

class _AnswerState extends ConsumerState<_Answer> {
  bool _expanded = false, _checking = false;
  String? _command, _side, _status;
  PlayableCard? _fresh;
  StreamSubscription<QueueEvent>? _events;
  @override
  void initState() {
    super.initState();
    _events = ref.read(pickQueueProvider.notifier).events.listen((e) {
      if (!mounted || e.intent.commandId != _command) return;
      setState(() {
        _status = e.rejected ? e.message : 'Submitted';
        _expanded = false;
        if (e.rejected) _command = null;
      });
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  PlayableCard? get _card =>
      _fresh ??
      (widget.a['playable'] == null
          ? null
          : PlayableCard.fromJson(
              (widget.a['playable'] as Map).cast<String, dynamic>(),
            ));
  Future<void> _refresh({String? side}) async {
    if (_checking || _command != null) return;
    final old = _card;
    if (old == null) return;
    setState(() => _checking = true);
    try {
      final r = await api.post('/analyst/form', {
        'playerId': old.card.playerId,
        'statKey': old.market.statKey,
        'n': 5,
      });
      if (!mounted) return;
      if (r['playable'] == null) {
        setState(() {
          _status = 'Line closed';
          _expanded = false;
        });
        return;
      }
      final fresh = PlayableCard.fromJson(
        (r['playable'] as Map).cast<String, dynamic>(),
      );
      setState(() => _fresh = fresh);
      if (r['alreadyPickedEntryId'] != null) {
        setState(() {
          _status = 'Already submitted';
          _expanded = false;
        });
        return;
      }
      if (side != null) {
        if (fresh.market.marketId != old.market.marketId ||
            fresh.market.lineVersion != old.market.lineVersion) {
          setState(
            () => _status = 'Line updated. Review the card before choosing.',
          );
          return;
        }
        _side = side;
        _command = ref
            .read(pickQueueProvider.notifier)
            .add(
              path: '/picks',
              payload: {
                'marketId': fresh.market.marketId,
                'lineVersion': fresh.market.lineVersion,
                'side': side,
                'stake': 0,
              },
              stake: 0,
              label:
                  '${fresh.card.fullName} · ${f.cap(side)} ${f.line(fresh.market.line)}',
            );
        setState(() => _status = 'Submitting…');
        ref.read(pickQueueProvider.notifier).flush();
      } else {
        setState(() {
          _expanded = !_expanded;
          _status = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResearchReport(widget.a),
        if (widget.a['shareId'] != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  shareObject(context, shareId: widget.a['shareId'] as String),
              icon: const Icon(Icons.ios_share, size: 16),
              label: const Text('Share this research'),
            ),
          ),
        if (p != null) ...[
          const SizedBox(height: 12),
          InkWell(
            onTap: _checking || _command != null ? null : () => _refresh(),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: const BoxDecoration(
                color: C.surface,
                border: Border(left: BorderSide(color: C.green, width: 2)),
              ),
              child: Row(
                children: [
                  JerseyIcon(spec: p.card, size: 46),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _status == 'Submitted'
                              ? '${p.card.lastName} · ${f.cap(_side!)} ${f.line(p.market.line)}'
                              : p.market.matchup,
                          style: T.h3,
                        ),
                        Text(
                          _status ??
                              '${f.line(p.market.line)} ${p.market.statLabel.toLowerCase()}',
                          style: T.small,
                        ),
                      ],
                    ),
                  ),
                  if (_status != 'Submitted')
                    Text(
                      _checking
                          ? 'Checking…'
                          : _expanded
                          ? 'Close'
                          : 'Open card',
                      style: const TextStyle(fontSize: 12, color: C.green),
                    ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: MediaQuery.of(context).disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 260),
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Column(
                      children: [
                        Swipeable(
                          enabled: !_checking && _command == null,
                          verticalDrag: false,
                          onSwipe: (side) => _refresh(side: side),
                          child: SportCard(
                            spec: p.card,
                            market: p.market,
                            width: 300,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextButton(
                              onPressed: _checking || _command != null
                                  ? null
                                  : () => _refresh(side: 'under'),
                              child: Text('← Under ${f.line(p.market.line)}'),
                            ),
                            TextButton(
                              onPressed: _checking || _command != null
                                  ? null
                                  : () => _refresh(side: 'over'),
                              child: Text('Over ${f.line(p.market.line)} →'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ],
    );
  }
}
