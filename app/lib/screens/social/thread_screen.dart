import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../ui/widgets.dart';
import '../../ui/share_object.dart';

/// Messages poll by sequence number every few seconds. Sends carry a client
/// message id so a retried send never duplicates.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({super.key, required this.threadId, required this.title});
  final String threadId;
  final String title;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final _messages = <Map<String, dynamic>>[];
  final _outbox = <Map<String, dynamic>>[];
  final _text = TextEditingController();
  final _scroll = ScrollController();
  Timer? _timer;
  int _after = 0;
  String? _error;
  bool _polling = false, _loaded = false;
  int? _firstUnread;
  final _unreadKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final first = !_loaded;
      final follow = first || !_scroll.hasClients || _scroll.position.maxScrollExtent - _scroll.offset < 80;
      final r = await api.raw('GET', '/threads/${widget.threadId}/messages${first ? '' : '?afterSeq=$_after'}');
      if (!mounted) return;
      if (!r.ok) {
        if (r.status != 0) setState(() => _error = r.map['message']?.toString() ?? 'Conversation unavailable.');
        return;
      }
      final msgs = (r.map['messages'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _loaded = true;
        _error = null;
        if (first) _firstUnread = (r.map['firstUnreadSeq'] as num?)?.toInt();
        _messages.addAll(msgs);
        if (msgs.isNotEmpty) _after = (msgs.last['seq'] as num).toInt();
        final ids = msgs.map((m) => m['clientMsgId']).toSet();
        _outbox.removeWhere((o) => ids.contains(o['clientMsgId']));
      });
      if (msgs.isNotEmpty && follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          if (first && _unreadKey.currentContext != null) {
            Scrollable.ensureVisible(_unreadKey.currentContext!, alignment: 0.1);
          } else {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _send([Map<String, dynamic>? retry]) async {
    final msg = retry ?? {'clientMsgId': const Uuid().v4(), 'body': _text.text.trim()};
    if ((msg['body'] as String).isEmpty) return;
    if (retry == null) {
      _text.clear();
      setState(() => _outbox.add({...msg, 'failed': false}));
    } else {
      setState(() => retry['failed'] = false);
    }
    final r = await api.raw('POST', '/threads/${widget.threadId}/messages', body: {'clientMsgId': msg['clientMsgId'], 'body': msg['body']});
    if (!mounted) return;
    if (!r.ok) {
      setState(() => _outbox.firstWhere((o) => o['clientMsgId'] == msg['clientMsgId'])['failed'] = true);
      if (r.status != 0) toast(context, r.map['message']?.toString() ?? 'Message not sent.', ok: false);
      return;
    }
    _poll();
  }

  Widget _bubble(String body, bool mine, String meta, {bool failed = false, VoidCallback? onRetry, Map<String, dynamic>? shared}) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 290),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? const Color(0xFF1E3A2E) : C.surface,
        border: Border.all(color: failed ? C.danger : C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (body.isNotEmpty) Text(body, style: T.body),
          if (shared != null) SharedObject(shared),
          const SizedBox(height: 4),
          InkWell(
            onTap: onRetry,
            child: Text(failed ? 'Not sent · tap to retry' : meta, style: T.small.copyWith(fontSize: 11)),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              InkWell(
                onTap: () => context.canPop() ? context.pop() : context.go('/social?tab=1'),
                child: const Text('← Back', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(widget.title, style: T.h3, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: T.dim, textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_messages.isEmpty && _outbox.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Say hello.', style: T.dim),
                      ),
                    for (final (i, m) in _messages.indexed) ...[
                      if (_firstUnread != null &&
                          (m['seq'] as num) >= _firstUnread! &&
                          (i == 0 || (_messages[i - 1]['seq'] as num) < _firstUnread!))
                        Padding(
                          key: _unreadKey,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: const Text('NEW MESSAGES', style: T.label),
                        ),
                      _bubble(
                        m['body'] as String,
                        m['mine'] == true,
                        '${m['mine'] == true ? 'You' : m['senderName']} · ${f.time(DateTime.parse(m['createdAt'] as String))}',
                        shared: (m['shared'] as Map?)?.cast<String, dynamic>(),
                      ),
                    ],
                    for (final o in _outbox)
                      _bubble(
                        o['body'] as String,
                        true,
                        'Sending…',
                        failed: o['failed'] == true,
                        onRetry: o['failed'] == true ? () => _send(o) : null,
                      ),
                  ],
                ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: C.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              Container(
                color: C.green,
                child: IconButton(
                  onPressed: _send,
                  icon: const Icon(Icons.arrow_upward, color: C.bg),
                  tooltip: 'Send',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
