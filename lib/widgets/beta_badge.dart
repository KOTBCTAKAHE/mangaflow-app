import 'package:flutter/material.dart';

/// Small «бета» tag for features that still learn: panel reading, image and plot search.
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        'БЕТА',
        style: TextStyle(
          color: scheme.onTertiaryContainer,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          height: 1.3,
        ),
      ),
    );
  }
}

/// A title with the «бета» tag after it.
class BetaTitle extends StatelessWidget {
  const BetaTitle(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(text, style: style, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        const BetaBadge(),
      ]);
}
