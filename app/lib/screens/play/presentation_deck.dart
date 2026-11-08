import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

class PresentationDeck extends StatefulWidget {
  const PresentationDeck({super.key, required this.cards, required this.onExit});
  final List<PlayableCard> cards;
  final VoidCallback onExit;
  @override
  State<PresentationDeck> createState() => _PresentationDeckState();
}

class _PresentationDeckState extends State<PresentationDeck> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    final c = widget.cards[_index];
    final diamond = c.mastery.count >= 400;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('ADMIN · PRESENTATION PACK', style: T.label),
        const SizedBox(height: 8),
        const Text('Five cards. Ready for the judges.', style: T.h2),
        const SizedBox(height: 8),
        const Text('Fictional presentation cards. The Diamond is a demo grant, not a claim of 400 real predictions.', style: T.small),
        const SizedBox(height: 16),
        Center(
          child: SportCard(
            spec: c.card,
            market: c.market,
            width: 300,
            finish: diamond ? 'diamond' : 'base',
            topRight: '${_index + 1} / 5',
            footer: CardFooter(
              spec: c.card,
              scale: 300 / 340,
              finish: diamond ? 'diamond' : 'base',
              left: diamond ? 'DIAMOND' : 'BASE',
              right: diamond ? '400/400 · Unlocked' : 'Earn Bronze: 1/20',
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: _index == 0 ? null : () => setState(() => _index--), child: const Text('← Previous')),
            TextButton(onPressed: _index == widget.cards.length - 1 ? null : () => setState(() => _index++), child: const Text('Next →')),
          ],
        ),
        PrimaryButton('Open my Collection', onPressed: () => context.go('/profile?tab=1')),
        TextButton(onPressed: widget.onExit, child: const Text('Back to packs')),
      ],
    );
  }
}
