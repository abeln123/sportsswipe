import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session.dart';
import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/format.dart' as f;
import 'league_screen.dart';
import 'head_to_head_screen.dart';

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
  int _revision = 0;

  @override
  void didUpdateWidget(SocialScreen old) {
    super.didUpdateWidget(old);
    if (old.initialTab != widget.initialTab) _tab = widget.initialTab;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _revision++);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          const PageTitle('Social'),
          UnderTabs(labels: const ['Friends', 'Messages', 'Leagues'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
          const SizedBox(height: 8),
          switch (_tab) {
            0 => _FriendsTab(key: ValueKey('friends-$_revision')),
            1 => _MessagesTab(key: ValueKey('messages-$_revision'), onLeagues: () => setState(() => _tab = 2)),
            _ => _LeaguesTab(key: ValueKey('leagues-$_revision')),
          },
        ],
      ),
    );
  }
}

class _FriendsTab extends ConsumerStatefulWidget {
  const _FriendsTab({super.key});

  @override
  ConsumerState<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends ConsumerState<_FriendsTab> {
  final _q = TextEditingController();
  final _focus = FocusNode();
  late final Future<Map<String, dynamic>> _collection = api.get('/me/collection');
  bool _inviting = false, _searching = false;
  String? _searchError;
  int _searchVersion = 0;
  final _accepted = <String>{}, _acting = <String>{};
  @override
  void dispose() {
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    if (_inviting) return;
    setState(() => _inviting = true);
    try {
      await textInvite(context);
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Future<void> _accept(Map<String, dynamic> u) async {
    final id = u['userId'] as String;
    if (_acting.contains(id)) return;
    setState(() => _acting.add(id));
    try {
      await api.post('/friend-requests/${u['requestId']}/accept');
      if (mounted) setState(() => _accepted.add(id));
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    } finally {
      if (mounted) setState(() => _acting.remove(id));
    }
  }

  List<Map<String, dynamic>>? _results;
  late Future<List<Map<String, dynamic>>> _data = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final r = await Future.wait([api.get('/friends'), api.get('/friend-requests')]);
    return r;
  }

  void _reload() => setState(() {
    _data = _load();
  });

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) return;
    final version = ++_searchVersion;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final r = await api.get('/users/search?q=${Uri.encodeQueryComponent(q)}');
      if (mounted && version == _searchVersion) setState(() => _results = (r['users'] as List).cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      if (mounted && version == _searchVersion) setState(() => _searchError = e.message);
    } finally {
      if (mounted && version == _searchVersion) setState(() => _searching = false);
    }
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            InitialsBadge(initialsOf(u['displayName'] as String)),
            const SizedBox(width: 14),
            Expanded(
              child: InkWell(
                onTap: () => context.go('/social/user/${u['userId']}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u['displayName'] as String, style: T.h3),
                    const SizedBox(height: 2),
                    Text(u['handleTag'] as String, style: T.small),
                  ],
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 50),
            child: Row(children: actions),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder(
          future: _data,
          builder: (context, snap) {
            final friends = (snap.data?.first['friends'] as List?) ?? [];
            if (!snap.hasData) return const SizedBox.shrink();
            if (friends.isNotEmpty || _accepted.isNotEmpty) {
              return Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _inviting ? null : _invite,
                  icon: const Icon(Icons.ios_share, size: 16),
                  label: const Text('Invite'),
                ),
              );
            }
            final me = ref.watch(sessionProvider).value;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      FutureBuilder(
                        future: _collection,
                        builder: (context, art) {
                          final cards = (art.data?['cards'] as List?) ?? [];
                          return Transform.rotate(
                            angle: -.06,
                            child: cards.isEmpty
                                ? InitialsBadge(me?.initials ?? '?')
                                : JerseyIcon(spec: CardSpec.fromJson((cards.first['card'] as Map).cast<String, dynamic>()), size: 68),
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(me?.displayName ?? 'Your team starts here', style: T.h2),
                            Text(me?.handleTag ?? '', style: T.small),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text('Bring your game-day group.', style: T.h2),
                  const SizedBox(height: 16),
                  PrimaryButton('Invite a friend', busy: _inviting, onPressed: _invite),
                ],
              ),
            );
          },
        ),
        TextField(
          controller: _q,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Find by name or handle',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: IconButton(
              tooltip: 'Search players',
              onPressed: _searching ? null : _search,
              icon: const Icon(Icons.arrow_forward, size: 20),
            ),
          ),
          onSubmitted: (_) => _search(),
        ),
        if (_searching) const LinearProgressIndicator(minHeight: 1, color: C.green),
        if (_searchError != null) Text(_searchError!, style: T.small),
        if (_results != null) ...[
          const SizedBox(height: 8),
          if (_results!.isEmpty) const Text('No players found.', style: T.dim),
          for (final u in _results!)
            _person(
              u,
              trailing: switch (u['relation']) {
                'friend' => const Text('Friend', style: T.small),
                'requested' => const Text('Requested', style: T.small),
                'incoming' => TextButton(
                  onPressed: () => _act(() => api.post('/friend-requests', {'userId': u['userId']}), 'You are now friends.'),
                  child: const Text('Accept', style: TextStyle(color: C.green)),
                ),
                _ => TextButton(
                  onPressed: () => _act(() => api.post('/friend-requests', {'userId': u['userId']}), 'Request sent.'),
                  child: const Text('Add', style: TextStyle(color: C.green)),
                ),
              },
            ),
        ],
        const Hr(),
        FutureBuilder(
          future: _data,
          builder: (context, snap) {
            if (snap.hasError) return ErrorText(snap.error!, onRetry: _reload);
            if (!snap.hasData) return const SizedBox(height: 280, child: Loading());
            final friends = (snap.data![0]['friends'] as List).cast<Map<String, dynamic>>();
            final incoming = (snap.data![1]['incoming'] as List).cast<Map<String, dynamic>>();
            final outgoing = (snap.data![1]['outgoing'] as List).cast<Map<String, dynamic>>();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (incoming.isNotEmpty) ...[
                  Text(_accepted.length == incoming.length ? 'New friends' : 'Incoming requests', style: T.h3),
                  for (final u in incoming)
                    _person(
                      u,
                      trailing: AnimatedSwitcher(
                        duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
                        child: _accepted.contains(u['userId'])
                            ? IconButton(
                                key: ValueKey('message-${u['userId']}'),
                                tooltip: 'Message ${u['displayName']}',
                                onPressed: () => _openDm(u),
                                icon: const Icon(Icons.chat_bubble_outline, color: C.green),
                              )
                            : TextButton(
                                key: ValueKey('accept-${u['userId']}'),
                                onPressed: _acting.contains(u['userId']) ? null : () => _accept(u),
                                child: const Text('Accept'),
                              ),
                      ),
                      actions: _accepted.contains(u['userId'])
                          ? []
                          : [
                              TextButton(
                                onPressed: () => _act(() => api.post('/friend-requests/${u['requestId']}/decline'), 'Request declined.'),
                                child: const Text('Decline', style: T.small),
                              ),
                            ],
                    ),
                  const SizedBox(height: 20),
                ],
                if (friends.isNotEmpty) Text('Your friends · ${friends.length}', style: T.h3),
                const SizedBox(height: 8),

                for (final u in friends)
                  _person(
                    u,
                    trailing: IconButton(
                      tooltip: 'Message ${u['displayName']}',
                      onPressed: () => _openDm(u),
                      icon: const Icon(Icons.chat_bubble_outline, color: C.green),
                    ),
                  ),
                if (outgoing.isNotEmpty) ...[
                  const Hr(),
                  Text('Sent · ${outgoing.length}', style: T.h3),
                  for (final r in outgoing) _person(r, trailing: const Text('Pending', style: T.small)),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _MessagesTab extends StatefulWidget {
  const _MessagesTab({super.key, required this.onLeagues});
  final VoidCallback onLeagues;

  @override
  State<_MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<_MessagesTab> {
  late Future<Map<String, dynamic>> _data = api.get('/threads');
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && TickerMode.valuesOf(context).enabled) {
        setState(() {
          _data = api.get('/threads');
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!);
        if (!snap.hasData) return const SizedBox(height: 280, child: Loading());
        final threads = (snap.data!['threads'] as List).cast<Map<String, dynamic>>();
        final dms = threads.where((t) => t['kind'] == 'dm').toList();
        final leagues = threads.where((t) => t['kind'] == 'league').toList();
        Widget row(Map<String, dynamic> t) => InkWell(
          onTap: () => context.go('/social/thread/${t['threadId']}?title=${Uri.encodeQueryComponent(t['title'] as String)}'),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: C.line)),
            ),
            child: Row(
              children: [
                if (t['shared']?['payload']?['card'] != null)
                  JerseyIcon(spec: CardSpec.fromJson((t['shared']['payload']['card'] as Map).cast<String, dynamic>()), size: 44)
                else
                  InitialsBadge(initialsOf(t['title'] as String), color: t['kind'] == 'league' ? C.under : const Color(0xFF8CC8E8)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t['title'] as String, style: T.h3),
                      if (t['lastAt'] != null)
                        Text(f.dayTime(DateTime.parse(t['lastAt'] as String)), style: T.small.copyWith(fontSize: 10)),
                      const SizedBox(height: 2),
                      Text(t['lastMessage'] as String? ?? 'No messages yet', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
                    ],
                  ),
                ),
                if ((t['unread'] as num) > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: C.green, borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      '${t['unread']}',
                      style: const TextStyle(color: C.bg, fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HeadToHeadList(),
            const SizedBox(height: 12),
            if (dms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('No direct messages yet.', style: T.dim),
              ),
            for (final t in dms) row(t),
            const Hr(),
            const Text('League', style: T.h3),
            const SizedBox(height: 8),
            if (leagues.isEmpty) ArrowLink('Go to Leagues', onTap: widget.onLeagues),
            for (final t in leagues) row(t),
          ],
        );
      },
    );
  }
}

class _LeaguesTab extends StatefulWidget {
  const _LeaguesTab({super.key});

  @override
  State<_LeaguesTab> createState() => _LeaguesTabState();
}

class _LeaguesTabState extends State<_LeaguesTab> {
  late Future<Map<String, dynamic>> _data = api.get('/leagues');

  Future<void> _create() async {
    final name = TextEditingController();
    final ok = await showSheet<bool>(
      context,
      (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Create a league', style: T.h1),
          const SizedBox(height: 8),
          TextField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'League name'),
            maxLength: 40,
          ),
          const SizedBox(height: 16),
          PrimaryButton('Create league', onPressed: () => Navigator.pop(ctx, true)),
          Center(
            child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false)),
          ),
        ],
      ),
    );
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
    final ok = await showSheet<bool>(
      context,
      (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Join with a code', style: T.h1),
          TextField(
            controller: code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: '6-character code'),
          ),
          const SizedBox(height: 16),
          PrimaryButton('Join league', onPressed: () => Navigator.pop(ctx, true)),
          Center(
            child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false)),
          ),
        ],
      ),
    );
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
        if (snap.hasError) {
          return ErrorText(
            snap.error!,
            onRetry: () => setState(() {
              _data = api.get('/leagues');
            }),
          );
        }
        if (!snap.hasData) return const SizedBox(height: 280, child: Loading());
        final leagues = (snap.data!['leagues'] as List).cast<Map<String, dynamic>>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 22),
            PrimaryButton(leagues.isEmpty ? 'Create my league' : 'Create another league', onPressed: _create),
            Center(child: GhostButton('Join with a code', onPressed: _join)),
            const Hr(),
            if (leagues.isEmpty)
              const Text('No leagues yet.', style: T.dim),
            for (final l in leagues)
              InkWell(
                onTap: () => context.go('/social/league/${l['leagueId']}'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: C.line)),
                  ),
                  child: Row(
                    children: [
                      InitialsBadge(initialsOf(l['name'] as String), color: C.under),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l['name'] as String, style: T.h3),
                            if (l['rank'] != null)
                              Text(
                                'Your place · #${l['rank']}',
                                style: const TextStyle(color: C.green, fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                            Text('${l['memberCount']} members · ${l['weeklyPoints'] ?? 0} points this week', style: T.small),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: C.dim),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
