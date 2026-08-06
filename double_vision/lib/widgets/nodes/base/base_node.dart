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

/// Fixed height of a port's hit slot. The dot is vertically centered inside it,
/// and the wrapper centers the slot on the port's anchor line ([kPortLaneTop] +
/// idx*[kPortSpacing]); so the dot's center — and thus the connected noodle —
/// lands exactly on that line, regardless of how tall the port label's text is.
const double kPortRowHeight = 20;

/// Height of the node's title bar. It doubles as the primary drag handle, so
/// the canvas overlays a drag/select target of exactly this height over each
/// node's top. Kept below [kPortLaneTop] so the first port sits in the body,
/// clear of the title bar.
const double kTitleBarHeight = 34;

