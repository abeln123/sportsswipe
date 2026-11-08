import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

class SocialScreen extends StatefulWidget {
  const SocialScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
  late int _tab = widget.initialTab;

  static const _titles = [
    ('Social', 'Friends, conversations and shared games'),
    ('Messages', 'Friends and your leagues'),
    ('Leagues', 'Weekly matches with friends'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
      PageTitle(_titles[_tab].$1, _titles[_tab].$2),
      UnderTabs(labels: const ['Friends', 'Messages', 'Leagues'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
      const SizedBox(height: 8),
      switch (_tab) {
        0 => const _FriendsTab(),
        1 => _MessagesTab(onLeagues: () => setState(() => _tab = 2)),
        _ => const _LeaguesTab(),
      },
    ]);
  }
}

class _FriendsTab extends StatefulWidget {
  const _FriendsTab();

  @override
  State<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<_FriendsTab> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _results;
  late Future<List<Map<String, dynamic>>> _data = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final r = await Future.wait([api.get('/friends'), api.get('/friend-requests')]);
    return r;
  }

  void _reload() => setState(() => _data = _load());

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) return;
    final r = await api.get('/users/search?q=${Uri.encodeQueryComponent(q)}');
    setState(() => _results = (r['users'] as List).cast<Map<String, dynamic>>());
  }

  Future<void> _act(Future<Object?> Function() f, String done) async {
    try {
      await f();
      if (!mounted) return;
      toast(context, done);
      _reload();
      if (_results != null) _search();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  Future<void> _openDm(Map<String, dynamic> u) async {
    try {
      final r = await api.post('/threads/dm', {'userId': u['userId']});
      if (mounted) context.go('/social/thread/${r['threadId']}?title=${Uri.encodeQueryComponent(u['displayName'] as String)}');
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  Widget _person(Map<String, dynamic> u, {List<Widget> actions = const [], Widget? trailing}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            InitialsBadge(initialsOf(u['displayName'] as String)),
            const SizedBox(width: 14),
            Expanded(
              child: InkWell(
                onTap: () => context.go('/social/user/${u['userId']}'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(u['displayName'] as String, style: T.h3),
                  const SizedBox(height: 2),
                  Text(u['handleTag'] as String, style: T.small),
                ]),
              ),
            ),
            ?trailing,
          ]),
          if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 50), child: Row(children: actions)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 14),
      const Text('Find players', style: T.small),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _q,
            decoration: const InputDecoration(hintText: 'Name or HANDLE#1234'),
            onSubmitted: (_) => _search(),
          ),
        ),
        TextButton(onPressed: _search, child: const Text('Search', style: TextStyle(color: C.green))),
      ]),
      if (_results != null) ...[
        const SizedBox(height: 8),
        if (_results!.isEmpty) const Text('No players found.', style: T.dim),
        for (final u in _results!)
          _person(u, trailing: switch (u['relation']) {
            'friend' => const Text('Friend', style: T.small),
            'requested' => const Text('Requested', style: T.small),
            'incoming' => TextButton(
                onPressed: () => _act(() => api.post('/friend-requests', {'userId': u['userId']}), 'You are now friends.'),
                child: const Text('Accept', style: TextStyle(color: C.green)),
              ),
            _ => TextButton(
                onPressed: () => _act(() => api.post('/friend-requests', {'userId': u['userId']}), 'Request sent.'),
                child: const Text('Add friend', style: TextStyle(color: C.green)),
              ),
          }),
      ],
      const Hr(),
      FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return ErrorText(snap.error!, onRetry: _reload);
          if (!snap.hasData) return const Loading();
          final friends = (snap.data![0]['friends'] as List).cast<Map<String, dynamic>>();
          final incoming = (snap.data![1]['incoming'] as List).cast<Map<String, dynamic>>();
          final outgoing = (snap.data![1]['outgoing'] as List).cast<Map<String, dynamic>>();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Your friends · ${friends.length}', style: T.h3),
            const SizedBox(height: 8),
            if (friends.isEmpty) const Text('No friends added yet. Accept a request or search above.', style: T.dim),
            for (final u in friends)
              _person(u, trailing: TextButton(onPressed: () => _openDm(u), child: const Text('Message', style: TextStyle(color: C.green)))),
            if (incoming.isNotEmpty) ...[
              const Hr(),
              Text('Requests · ${incoming.length}', style: T.h3),
              for (final r in incoming)
                _person(r, trailing: const Text('Request', style: T.small), actions: [
                  TextButton(
                    onPressed: () => _act(() => api.post('/friend-requests/${r['requestId']}/accept'), 'You are now friends.'),
                    child: const Text('Accept', style: TextStyle(color: C.text, fontWeight: FontWeight.w700)),
                  ),
                  TextButton(
                    onPressed: () => _act(() => api.post('/friend-requests/${r['requestId']}/decline'), 'Request declined.'),
                    child: const Text('Decline', style: TextStyle(color: C.dim)),
                  ),
                ]),
            ],
            if (outgoing.isNotEmpty) ...[
              const Hr(),
              Text('Sent · ${outgoing.length}', style: T.h3),
              for (final r in outgoing) _person(r, trailing: const Text('Pending', style: T.small)),
            ],
          ]);
        },
      ),
    ]);
  }
}

class _MessagesTab extends StatelessWidget {
  const _MessagesTab({required this.onLeagues});
  final VoidCallback onLeagues;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: api.get('/threads'),
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!);
        if (!snap.hasData) return const Loading();
        final threads = (snap.data!['threads'] as List).cast<Map<String, dynamic>>();
        final dms = threads.where((t) => t['kind'] == 'dm').toList();
        final leagues = threads.where((t) => t['kind'] == 'league').toList();
        Widget row(Map<String, dynamic> t) => InkWell(
              onTap: () => context.go('/social/thread/${t['threadId']}?title=${Uri.encodeQueryComponent(t['title'] as String)}'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  InitialsBadge(initialsOf(t['title'] as String), color: t['kind'] == 'league' ? C.under : const Color(0xFF8CC8E8)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t['title'] as String, style: T.h3),
                      const SizedBox(height: 2),
                      Text(t['lastMessage'] as String? ?? 'No messages yet', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
                    ]),
                  ),
                  if ((t['unread'] as num) > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      color: C.green,
                      child: Text('${t['unread']}', style: const TextStyle(color: C.bg, fontWeight: FontWeight.w800, fontSize: 12)),
                    ),
                ]),
              ),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 12),
          if (dms.isEmpty) const Text('Add a friend to start a conversation.', style: T.dim),
          for (final t in dms) row(t),
          const Hr(),
          const Text('League', style: T.h3),
          const SizedBox(height: 8),
          if (leagues.isEmpty) ...[
            const Text('Join or create a league to open its conversation.', style: T.dim),
            ArrowLink('Go to Leagues', onTap: onLeagues),
          ],
          for (final t in leagues) row(t),
        ]);
      },
    );
  }
}

class _LeaguesTab extends StatefulWidget {
  const _LeaguesTab();

  @override
  State<_LeaguesTab> createState() => _LeaguesTabState();
}

class _LeaguesTabState extends State<_LeaguesTab> {
  late Future<Map<String, dynamic>> _data = api.get('/leagues');

  Future<void> _create() async {
    final name = TextEditingController();
    final ok = await showSheet<bool>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Create a league', style: T.h1),
          const SizedBox(height: 8),
          const Text('Invite friends by text. Standings use this week\'s contest points.', style: T.dim),
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'League name'), maxLength: 40),
          const SizedBox(height: 16),
          PrimaryButton('Create league', onPressed: () => Navigator.pop(ctx, true)),
          Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
        ]));
    if (ok != true) return;
    try {
      final r = await api.post('/leagues', {'name': name.text});
      if (mounted) context.go('/social/league/${r['leagueId']}');
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  Future<void> _join() async {
    final code = TextEditingController();
    final ok = await showSheet<bool>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Join with a code', style: T.h1),
          TextField(
            controller: code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: '6-character code'),
          ),
          const SizedBox(height: 16),
          PrimaryButton('Join league', onPressed: () => Navigator.pop(ctx, true)),
          Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
        ]));
    if (ok != true) return;
    try {
      final r = await api.post('/leagues/join', {'code': code.text});
      if (mounted) context.go('/social/league/${r['leagueId']}');
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!, onRetry: () => setState(() => _data = api.get('/leagues')));
        if (!snap.hasData) return const Loading();
        final leagues = (snap.data!['leagues'] as List).cast<Map<String, dynamic>>();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 22),
          PrimaryButton(leagues.isEmpty ? 'Create my league' : 'Create another league', onPressed: _create),
          Center(child: GhostButton('Join with a code', onPressed: _join)),
          const Hr(),
          if (leagues.isEmpty) const Text('You are not in a league yet.', style: T.dim),
          for (final l in leagues)
            InkWell(
              onTap: () => context.go('/social/league/${l['leagueId']}'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  InitialsBadge(initialsOf(l['name'] as String), color: C.under),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l['name'] as String, style: T.h3),
                      Text('${l['memberCount']} members · ${l['role'] == 'owner' ? 'Owner' : 'Member'}', style: T.small),
                    ]),
                  ),
                  const Icon(Icons.chevron_right, color: C.dim),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
