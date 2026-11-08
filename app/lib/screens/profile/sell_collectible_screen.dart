import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/api.dart';
import '../../core/collectible_wallet.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

class SellCollectibleScreen extends StatefulWidget {
  const SellCollectibleScreen({super.key, required this.playerId, required this.presentation});
  final int playerId;
  final bool presentation;
  @override
  State<SellCollectibleScreen> createState() => _SellCollectibleState();
}

class _SellCollectibleState extends State<SellCollectibleScreen> {
  Map<String, dynamic>? _dashboard, _card, _edition, _sale;
  bool _busy = false, _loading = false;
  String? _error;
  String _phase = 'Ready to connect your devnet wallet.';
  String? _connected;
  final _price = TextEditingController(text: '0.1');
  Timer? _poll;
  final _steps = <String>[];
  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!_busy) _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _price.dispose();
    super.dispose();
  }

  void _step(String value) {
    if (!mounted) return;
    setState(() {
      _phase = value;
      if (!_steps.contains(value)) _steps.add(value);
    });
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final results = await Future.wait([api.get('/collectibles/dashboard'), api.get('/me/collection')]);
      if (!mounted) return;
      final d = results[0];
      final cards = (results[1]['cards'] as List).cast<Map<String, dynamic>>();
      final c = cards.where((c) => (c['card']['playerId'] as num).toInt() == widget.playerId).firstOrNull;
      final edition = (d['collectibles'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['player_id'].toString() == widget.playerId.toString() && e['is_earner'] == true)
          .firstOrNull;
      final sale = edition == null
          ? null
          : (d['sales'] as List)
                .cast<Map<String, dynamic>>()
                .where((s) => s['collectible_id'] == edition['id'] && s['is_seller'] == true)
                .firstOrNull;
      setState(() {
        _dashboard = d;
        _card = c;
        _edition = edition;
        _sale = sale;
        _error = null;
      });
      if (sale?['status'] == 'confirmed') {
        _step('Confirmed on Solana devnet. Ownership transferred. Your mastery remains 400/400.');
      } else if (sale?['status'] == 'submitted') {
        _step('Transaction submitted. Waiting for Solana confirmation…');
      } else if (sale?['status'] == 'expired') {
        _step('Transaction expired or failed. No successful sale was confirmed. Start a fresh sale.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _loading = false;
    }
  }

  Future<void> _connect() async {
    final address = await connectCollectibleWallet();
    _step('Wallet connected. Verify that this is your devnet wallet.');
    final challenge = await api.post('/collectibles/wallet/challenge', {'address': address});
    final signature = await signCollectibleMessage(challenge['message'] as String);
    await api.post('/collectibles/wallet/verify', {'signature': signature});
    _connected = address;
    _step('Wallet ownership verified.');
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_connected == null) await _connect();
      if (_sale?['status'] == 'submitted') {
        await api.post('/collectibles/retry', {'id': _sale!['id']});
        await _refresh();
        return;
      }
      if (_sale?['status'] == 'confirmed') return;
      if (_edition == null || _edition?['minted_at'] == null) {
        _step('Claiming your numbered devnet Diamond…');
        await api.post('/collectibles/claim', {'playerId': widget.playerId});
        await _refresh();
        _step('Diamond issued. Original earner and season recorded.');
      }
      final id = _edition?['id'];
      if (id == null) throw Exception('Claim is still confirming. Retry to resume the same edition.');
      if (widget.presentation) {
        _step('Presentation buyer is agreeing to 0.1 devnet SOL and signing the sale…');
        final prepared = await api.post('/collectibles/presentation/sell', {'id': id});
        await _refresh();
        if (prepared['status'] == 'confirmed') return;
        _step('Buyer signature received. Approve the card transfer in your wallet.');
        final tx = await api.post('/collectibles/transaction', {'id': prepared['id']});
        final signed = await signCollectibleTransaction(tx['transaction'] as String);
        await api.post('/collectibles/sign', {'id': prepared['id'], 'transaction': signed});
        _step('Both signatures verified. Payment and card transfer submitted together.');
      } else {
        if (_sale?['status'] == 'signing') {
          _step('Review and approve the buyer’s offer in your wallet.');
          final tx = await api.post('/collectibles/transaction', {'id': _sale!['id']});
          await api.post('/collectibles/sign', {
            'id': _sale!['id'],
            'transaction': await signCollectibleTransaction(tx['transaction'] as String),
          });
        } else {
          await api.post('/collectibles/list', {'id': id, 'price': _price.text});
          _step('Edition listed. Waiting for a buyer to agree and sign.');
        }
      }
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _card;
    final spec = c == null ? null : CardSpec.fromJson((c['card'] as Map).cast<String, dynamic>());
    final sold = _sale?['status'] == 'confirmed';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextButton(
          onPressed: () => context.go('/profile?tab=1'),
          child: const Align(alignment: Alignment.centerLeft, child: Text('← My collection')),
        ),
        Text(widget.presentation ? 'ADMIN · PRESENTATION SALE' : 'DIAMOND EDITION', style: T.label),
        const SizedBox(height: 8),
        Text(sold ? 'Sale complete.' : 'Sell your Diamond.', style: T.h1),
        const SizedBox(height: 8),
        Text(
          widget.presentation
              ? 'A dedicated demo buyer offers 0.1 devnet SOL. This is test currency. You still approve the transfer.'
              : 'List an edition for devnet SOL. A buyer must agree and sign before a sale can complete.',
          style: T.dim,
        ),
        const SizedBox(height: 18),
        if (spec != null)
          Center(
            child: SportCard(
              spec: spec,
              width: 260,
              finish: 'diamond',
              footer: CardFooter(spec: spec, finish: 'diamond', left: 'DIAMOND', right: '400/400 · Unlocked'),
            ),
          ),
        const SizedBox(height: 18),
        Text(_phase, style: T.h3),
        const SizedBox(height: 12),
        for (final step in _steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check, size: 17, color: C.green),
                const SizedBox(width: 10),
                Expanded(child: Text(step, style: T.small)),
              ],
            ),
          ),
        if (_edition != null) ...[
          Text('Edition #${_edition!['edition']} · ${_edition!['season']}', style: T.body),
          Text('Original earner: ${_edition!['earner_name']}', style: T.small),
          Text('Current owner: ${_edition!['owner_name'] ?? _edition!['owner'] ?? 'Mint pending'}', style: T.small),
        ],
        if (_sale != null)
          Text('Sale status: ${_sale!['status']} · ${num.parse(_sale!['lamports'].toString()) / 1e9} devnet SOL', style: T.body),
        if (_sale?['transaction_url'] != null)
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(_sale!['transaction_url'] as String)),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Verify transaction on Solana Explorer'),
          ),
        if (!widget.presentation && !sold)
          TextField(
            controller: _price,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Asking price in devnet SOL'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!, style: const TextStyle(color: C.danger)),
          ),
        const SizedBox(height: 16),
        if (!sold)
          PrimaryButton(
            _sale?['status'] == 'submitted'
                ? 'Check / retry same transaction'
                : _sale?['status'] == 'signing'
                ? 'Approve sale in wallet'
                : widget.presentation
                ? 'Sell to demo buyer · 0.1 devnet SOL'
                : 'Connect wallet & list edition',
            busy: _busy,
            onPressed: _run,
          ),
        TextButton(onPressed: _busy ? null : _refresh, child: const Text('Refresh confirmed ownership')),
        if (_dashboard == null && _error == null) const LinearProgressIndicator(),
      ],
    );
  }
}
