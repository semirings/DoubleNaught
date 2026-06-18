import 'package:flutter/material.dart';

/// Design tokens shared by every workspace node, centralised so the whole
/// canvas inherits one set of container rules — the "Base Node Blueprint"
/// (see `doc/Journal.md`). Tune these in one place rather than per node.

/// Fixed node-card width. Nodes are fixed-width so the canvas can lay them out
/// predictably; bodies adapt within this bound.
const double kNodeWidth = 240;

/// Global padding inside every node card.
const EdgeInsets kNodePadding = EdgeInsets.all(12);

/// Corner radius of the node card and its cobalt outline.
const double kNodeRadius = 8;

/// Upper bound on text scaling inside a node. Cards are a fixed [kNodeWidth]
/// wide, so an unbounded OS font-scale setting would push key/value labels
/// (e.g. `rawFileStream`) and status logs past the edge and clip them. Clamping
/// to this ceiling keeps labels legible on variable data without overflowing.
const double kNodeMaxTextScale = 1.2;

/// Edge-Anchor geometry (see DESIGN.md). The y-coordinate, measured from a
/// node's top, of the first port's center; successive ports step down by
/// [kPortSpacing]. Both [BaseNodeFrame]/`DoubleNaughtNodeWrapper` (which place
/// the dots) and the canvas edge painter (which anchors noodles) use these, so
/// a port dot and its connection line always coincide.
const double kPortLaneTop = 40;
const double kPortSpacing = 24;

/// Half the connector dot diameter — the offset that straddles a dot's center
/// over the node's boundary edge.
const double kPortDotRadius = 7;

/// The shared chrome for every workspace node — the concrete realisation of the
/// Base Node Blueprint:
///
///  * a dark-themed [Card] container ([ColorScheme.surfaceContainer]),
///  * a thin cobalt-blue (primary) 1px outline with rounded corners,
///  * standard global [kNodePadding],
///  * a reserved top header area showing a camelCase [title] beside [icon], and
///  * a strict text-scaling boundary ([kNodeMaxTextScale]) that stops labels and
///    status logs from clipping on large font settings or variable data.
///
/// Stateless nodes get this automatically by extending [BaseNode]. Stateful
/// nodes (which can't share a StatelessWidget superclass) compose it directly,
/// passing their body as [child] — so the container rules live in exactly one
/// place either way.
class BaseNodeFrame extends StatelessWidget {
  /// camelCase header title shown in the reserved top area.
  final String title;

  /// Glyph shown beside the [title].
  final IconData icon;

  /// Node-specific content rendered beneath the header.
  final Widget child;

  /// Card width; defaults to the canvas-wide [kNodeWidth].
  final double width;

  const BaseNodeFrame({
    super.key,
    required this.title,
    required this.child,
    this.icon = Icons.widgets_outlined,
    this.width = kNodeWidth,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Clamp text scaling for the whole subtree so no descendant label can be
    // blown past the fixed card width by the user's font-size setting.
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.0,
      maxScaleFactor: kNodeMaxTextScale,
      child: SizedBox(
        width: width,
        child: Card(
          // Outline-first per the design system: no shadow — depth comes from
          // the cobalt border against the dark surface.
          elevation: 0,
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
                // Reserved header area: camelCase title beside its glyph. The
                // title is clipped to a single line so a long type never grows
                // the header height.
                Row(
                  children: [
                    Icon(icon, size: 18, color: scheme.primary),
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
                ),
                const Divider(height: 16),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Abstract base class for a workspace node widget.
///
/// Concrete *stateless* nodes extend this and implement [title] / [icon] /
/// [buildBody]; the shared container chrome (padding, cobalt outline, header,
/// text-scale clamp) is supplied by [BaseNodeFrame] and never re-implemented per
/// node. Stateful nodes can't share a StatelessWidget superclass, so they wrap
/// their body in [BaseNodeFrame] directly instead.
abstract class BaseNode extends StatelessWidget {
  const BaseNode({super.key});

  /// camelCase header title shown in the reserved top area.
  String get title;

  /// Glyph shown beside the [title]. Defaults to a generic node icon.
  IconData get icon => Icons.widgets_outlined;

  /// The node-specific body rendered beneath the header.
  Widget buildBody(BuildContext context);

  @override
  Widget build(BuildContext context) => BaseNodeFrame(
        title: title,
        icon: icon,
        child: buildBody(context),
      );
}
