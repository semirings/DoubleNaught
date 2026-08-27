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

/// Fixed card-border-state colors — identical across every node, per
/// `UX_UI/GLOBAL_UX_CONTRACT.md` §1 ("There is no per-node variation on
/// border color or meaning"). Not theme-derived: the design system fixes
/// these literally, matching `UX_UI/_template.py`'s
/// OUTLINE_NORMAL_COL/OUTLINE_EXECUTING_COL/STATUS_ERROR_COL.
const Color kBorderNormalColor = Color.fromRGBO(148, 148, 158, 1);
const Color kBorderExecutingColor = Colors.white;
const Color kBorderErrorColor = Color.fromRGBO(235, 71, 71, 1);

/// Fixed status-row colors — identical across every node, per
/// `UX_UI/GLOBAL_UX_CONTRACT.md` §5. Matches `UX_UI/_template.py`'s
/// STATUS_IDLE_COL/STATUS_RUNNING_COL/STATUS_SUCCESS_COL/STATUS_ERROR_COL.
const Color kStatusIdleColor = Color.fromRGBO(133, 133, 143, 1);
const Color kStatusRunningColor = Color.fromRGBO(204, 148, 255, 1);
const Color kStatusSuccessColor = Color.fromRGBO(89, 217, 122, 1);
const Color kStatusErrorColor = Color.fromRGBO(235, 71, 71, 1);

/// Fixed colors for the three roles in an AA rendered as a grid — row header
/// (leftmost column), column header (top row), and value cell — used by
/// `AaDataFrame`. Not node-card tokens like the ones above, but kept here
/// too since this is the app's one place for shared, non-theme-derived
/// color constants rather than hardcoding them inline.
const Color kAaRowHeaderColor = Color.fromRGBO(255, 141, 187, 1);
const Color kAaColumnHeaderColor = Color.fromRGBO(94, 224, 232, 1);
const Color kAaValueColor = Color.fromRGBO(232, 213, 105, 1);

