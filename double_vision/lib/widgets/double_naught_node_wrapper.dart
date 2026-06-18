import 'package:flutter/material.dart';

import 'base_node.dart'
    show
        kNodeWidth,
        kNodePadding,
        kNodeRadius,
        kNodeMaxTextScale,
        kPortLaneTop,
        kPortSpacing,
        kPortDotRadius;

/// The universal node shell — the compositional successor to the (now
/// deprecated) `BaseNode` inheritance model. See the "Architecture Rules"
/// section of `DESIGN.md`: **every workflow widget is built by composing this
/// wrapper**, never by subclassing.
///
/// The wrapper owns *only* the container concerns — visual card layout, dark
/// theme + thin cobalt outline, the reserved camelCase header, global padding,
/// the text-scaling boundary, and the input/output port rail — and renders an
/// arbitrary [child] in its body slot. The body decides what the node *does*;
/// the wrapper decides how every node *looks and connects*.
///
/// Ports are supplied pre-built (e.g. `InputConnector` / `OutputConnector`) so
/// the shell stays agnostic about how edges are wired: [inputPorts] are laid
/// out on the left, [outputPorts] on the right, beneath the body.
class DoubleNaughtNodeWrapper extends StatelessWidget {
  /// camelCase header title shown in the reserved top area (e.g.
  /// `sam3ControlPanel`).
  final String title;

  /// Glyph shown beside the [title].
  final IconData icon;

  /// Node body content. The single composition slot.
  final Widget child;

  /// Left-edge input connectors. Empty for source-only nodes.
  final List<Widget> inputPorts;

  /// Right-edge output connectors. Empty for sink-only nodes.
  final List<Widget> outputPorts;

  /// Card width; defaults to the canvas-wide [kNodeWidth].
  final double width;

  const DoubleNaughtNodeWrapper({
    super.key,
    required this.title,
    required this.child,
    this.icon = Icons.widgets_outlined,
    this.inputPorts = const [],
    this.outputPorts = const [],
    this.width = kNodeWidth,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Clamp text scaling for the whole subtree so no descendant label can be
    // blown past the fixed card width by the OS font-size setting — the
    // data-contract clipping guard from the Base Node Blueprint.
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.0,
      maxScaleFactor: kNodeMaxTextScale,
      child: SizedBox(
        width: width,
        // Clip.none so the edge-anchored port dots may straddle the boundary.
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Card(
              // Outline-first per the design system: no shadow — depth comes
              // from the cobalt border against the dark surface.
              elevation: 0,
              // Zero margin so the card edge == SizedBox edge == port anchor.
              margin: EdgeInsets.zero,
              color: scheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kNodeRadius),
                side: BorderSide(color: scheme.primary, width: 1),
              ),
              child: Padding(
                padding: kNodePadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Header(title: title, icon: icon),
                    const Divider(height: 16),
                    child,
                  ],
                ),
              ),
            ),

            // Edge-Anchor: Inputs on the absolute LEFT edge, Outputs on the
            // absolute RIGHT edge, stepping down by kPortSpacing per index.
            // The same geometry drives the canvas edge painter so dots and
            // noodle endpoints coincide.
            for (var i = 0; i < inputPorts.length; i++)
              Positioned(
                left: -kPortDotRadius,
                top: kPortLaneTop + i * kPortSpacing - kPortDotRadius,
                child: inputPorts[i],
              ),
            for (var i = 0; i < outputPorts.length; i++)
              Positioned(
                right: -kPortDotRadius,
                top: kPortLaneTop + i * kPortSpacing - kPortDotRadius,
                child: outputPorts[i],
              ),
          ],
        ),
      ),
    );
  }
}

/// Reserved top header: camelCase title beside its glyph, clipped to one line
/// so a long title never grows the header height.
class _Header extends StatelessWidget {
  final String title;
  final IconData icon;

  const _Header({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
