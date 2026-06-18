---
name: DoubleNaught
colors:
  surface: '#0b1326'
  surface-dim: '#0b1326'
  surface-bright: '#31394d'
  surface-container-lowest: '#060e20'
  surface-container-low: '#131b2e'
  surface-container: '#171f33'
  surface-container-high: '#222a3d'
  surface-container-highest: '#2d3449'
  on-surface: '#dae2fd'
  on-surface-variant: '#bdc8d1'
  inverse-surface: '#dae2fd'
  inverse-on-surface: '#283044'
  outline: '#87929a'
  outline-variant: '#3e484f'
  surface-tint: '#7bd0ff'
  primary: '#8ed5ff'
  on-primary: '#00354a'
  primary-container: '#38bdf8'
  on-primary-container: '#004965'
  inverse-primary: '#00668a'
  secondary: '#6bd8cb'
  on-secondary: '#003732'
  secondary-container: '#29a195'
  on-secondary-container: '#00302b'
  tertiary: '#c7c8ff'
  on-tertiary: '#1000a9'
  tertiary-container: '#a7a9ff'
  on-tertiary-container: '#2b29bb'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#c4e7ff'
  primary-fixed-dim: '#7bd0ff'
  on-primary-fixed: '#001e2c'
  on-primary-fixed-variant: '#004c69'
  secondary-fixed: '#89f5e7'
  secondary-fixed-dim: '#6bd8cb'
  on-secondary-fixed: '#00201d'
  on-secondary-fixed-variant: '#005049'
  tertiary-fixed: '#e1e0ff'
  tertiary-fixed-dim: '#c0c1ff'
  on-tertiary-fixed: '#07006c'
  on-tertiary-fixed-variant: '#2f2ebe'
  background: '#0b1326'
  on-background: '#dae2fd'
  surface-variant: '#2d3449'
typography:
  display:
    fontFamily: Geist
    fontSize: 48px
    fontWeight: '600'
    lineHeight: '1.1'
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Geist
    fontSize: 32px
    fontWeight: '600'
    lineHeight: '1.2'
  headline-md:
    fontFamily: Geist
    fontSize: 24px
    fontWeight: '500'
    lineHeight: '1.3'
  body-lg:
    fontFamily: Geist
    fontSize: 16px
    fontWeight: '400'
    lineHeight: '1.5'
  body-md:
    fontFamily: Geist
    fontSize: 14px
    fontWeight: '400'
    lineHeight: '1.5'
  body-sm:
    fontFamily: Geist
    fontSize: 12px
    fontWeight: '400'
    lineHeight: '1.4'
  label-md:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '500'
    lineHeight: '1.2'
    letterSpacing: 0.02em
  label-sm:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '400'
    lineHeight: '1.2'
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  gutter: 12px
  margin: 20px
---

<!-- ────────────────────────────────────────────────────────────────────────
     ARCHITECTURE RULES — hand-authored, NOT Stitch-synced.
     Everything below the "Visual Design System" divider is regenerated from
     the Stitch project on re-sync; this section is not. Preserve it across
     syncs (or extract it to a dedicated ARCHITECTURE.md).
     ──────────────────────────────────────────────────────────────────────── -->

# Architecture Rules

These are the core, binding rules for how workflow widgets are built. They take
precedence over any incidental pattern found in existing code.

## Node composition (supersedes OOP inheritance)

We have **shifted from strict OOP inheritance to a compositional widget
pattern.** The former approach — concrete nodes extending an abstract `BaseNode`
class — is **deprecated**.

- **Every workflow widget MUST be built by composing the universal
  `DoubleNaughtNodeWrapper` shell component.** Nodes no longer subclass a base
  class; they wrap themselves in this one shell.
- `DoubleNaughtNodeWrapper` is the single owner of all node container chrome
  defined by the Base Node Blueprint: dark surface, thin cobalt-blue outline,
  rounded corners, global padding, the reserved camelCase header, and the
  text-scaling boundary.
- The wrapper **accepts modular child configurations** rather than fixed
  subclasses. A node supplies a composable child — e.g. the upcoming
  **`Sam3ControlPanel`** — which renders inside the shell body. Children are
  swappable and reusable across node types without any class hierarchy.

## Edge-Anchor port pattern

Ports are not decorations inside the body — they define the node's connection
boundary, so they must sit on its physical edges:

- **All ports are positioned on the absolute boundary edges of the
  `DoubleNaughtNodeWrapper`:** **Inputs on the left edge, Outputs on the right
  edge.** The wrapper places them with `Positioned` widgets in a `Stack` so the
  dot centers land exactly on the card's left/right boundary.
- **Noodle endpoints must coincide with the port dots.** The canvas edge
  painter and the wrapper share the same anchor geometry (`kPortLaneTop` +
  `idx * kPortSpacing` from the node's top), so a connection line terminates on
  the actual port rather than the node's center.
- **Port contract — SAM3 work node (`sam3Work`):** a **`preview`** Input port on
  the left and an **`imageArray`** Output port on the right (the segmentation
  array result stream), alongside its existing `segmentStream` output.

## What the wrapper enforces

Because all nodes pass through one shell, two cross-cutting rules are enforced in
exactly one place:

1. **Strict camelCase styling.** Header titles and port labels (e.g.
   `rawFileStream`, `inputStream`, `Sam3ControlPanel`) are rendered through the
   wrapper so the camelCase convention is applied uniformly and cannot drift per
   node.
2. **Data-contract clipping prevention.** The wrapper clamps text scaling and
   constrains label layout so key/value data-contract labels never clip or
   overflow on variable data.

## Backend data contract (camelCase keys)

The camelCase rule extends across the wire. **All JSON payloads returned by
DoubleNaught backend services MUST use camelCase keys** (e.g. `segmentMask`,
`inferenceMetrics`, `processingTimeMs`, `sessionId`), so a node's data contract
reads identically in Dart and on the server. The SAM3 service in `double_touch/`
is the reference implementation. (The upstream `mlx_sam3` reference backend uses
snake_case; that convention is **not** carried into DoubleNaught.)

## Data-contract boundary (unchanged)

- **Processing nodes are AA-in → AA-out** — they consume and emit D4M
  associative arrays.
- **Ingest nodes are the boundary** — no AA input; raw-out only. They bootstrap
  raw external bytes into the AA pipeline; a downstream parser is what first
  lifts raw data into an AA.
- **The File Source node is the canonical ingestion-layer boundary.** It reads
  from **local storage** (the native file picker) and streams the file's
  contents out as **raw string/byte data** — explicitly **not** a structured D4M
  associative array. It sits at the very edge of the graph: it has no input
  port, only a raw output stream that a downstream node parses into an AA.

<!-- ──────────────────────── Visual Design System (Stitch-synced) ──────────── -->

## Brand & Style

The design system is engineered for high-fidelity technical environments where precision and data density are paramount. The aesthetic is rooted in **Technical Minimalism**, prioritizing clarity and functional efficiency over decorative elements. 

The visual language evokes the feeling of a sophisticated command center: calm, organized, and authoritative. It targets power users who require a focused workspace that minimizes cognitive load while providing deep utility. The emotional response is one of reliability and "expert-grade" toolset performance, achieved through thin strokes, balanced proportions, and a restrained dark-mode palette.

## Colors

The palette for this design system is built on a foundation of deep, layered neutrals to provide a low-strain environment for extended use.

*   **Primary:** A crisp Technical Blue (#38BDF8) used sparingly for active states, focus rings, and critical indicators.
*   **Secondary:** A muted Teal (#0D9488) used for secondary actions and success states.
*   **Neutral (Core):** The background is a "Deep Charcoal" (#0F172A). Surface layers use increments of Slate to define hierarchy without relying on shadows.
*   **Accents:** A subtle Indigo (#6366F1) is available for tertiary data visualization or categorizations.

Avoid large blocks of saturated color. Color should be applied as a "precision tool"—highlighting a line of code, a status dot, or a thin border.

## Typography

Typography is used to reinforce the technical nature of the application. 

*   **Geist** is the primary typeface for all interface elements and body copy, chosen for its exceptional legibility and modern, "developer-tool" aesthetic.
*   **JetBrains Mono** is utilized for labels, metadata, status indicators, and actual technical data/code. This provides a clear visual distinction between "the app interface" and "the data being managed."

Scale is kept tight. For a desktop workspace, font sizes favor the 12px–14px range for high information density, ensuring that users can view large amounts of data without excessive scrolling.

## Layout & Spacing

The design system employs a **Fixed Grid** system for the primary layout shells (sidebar, main stage, inspector) and a **Fluid Flexbox** model for internal content components. 

*   **Spacing Rhythm:** A strict 4px baseline grid ensures alignment.
*   **Density:** Padding is intentionally tight (e.g., 8px for list items, 12px for card interiors) to maximize screen real estate.
*   **Grid Model:** A 12-column grid is used for the main workspace, with gutters of 12px to maintain the "compact" feel.
*   **Adaptability:** On desktop, the sidebar is collapsible to a narrow icon-only state. Content does not reflow wildly but instead utilizes horizontal scrolling or truncation with tooltips to maintain data integrity.

## Elevation & Depth

This system avoids traditional drop shadows to maintain a flat, technical appearance. Depth is conveyed through **Tonal Layering** and **Thin Outlines**:

1.  **Level 0 (Background):** The deepest Slate/Charcoal (#020617).
2.  **Level 1 (Surface):** Panels and sidebars use a slightly lighter Slate (#0F172A).
3.  **Level 2 (Active/Floating):** Modals or popovers use a border of 1px (#1E293B) and a subtle backdrop blur (8px) to separate from the background.

Instead of shadows, use "Ghost Borders"—1px strokes that are only 10-15% lighter than the surface they sit on. This creates a crisp, architectural structure without the "fuzziness" of elevation shadows.

## Shapes

The shape language is disciplined and geometric. 

*   **Corner Radius:** A universal 4px (`0.25rem`) radius is applied to buttons, inputs, and cards. This "Soft" setting provides enough modern polish to feel contemporary while remaining sharp enough to feel professional and technical.
*   **Consistency:** Avoid large pill shapes or full circles except for status pips (e.g., online/offline indicators). Every structural element should feel like a modular block in a larger machine.

## Components

Components in this design system follow an "Outline-First" philosophy.

*   **Buttons:** Default state is a 1px border with no fill. On hover, the border brightens. Only the "Primary Action" button should ever have a subtle solid fill (use 10% opacity of the primary color).
*   **Inputs:** Minimalist outlines with "JetBrains Mono" text. The focus state should be a sharp 1px primary color border with no outer glow.
*   **Chips/Tags:** Small, rectangular with 2px rounding. Use monospaced labels. Backgrounds should be a dark tint of the tag's semantic color (e.g., 5% red for an 'error' tag).
*   **Lists:** High-density rows (32px height). Use subtle dividers (#1E293B) and a "solid Slate" highlight for the selected state.
*   **Cards:** Defined by 1px borders rather than shadows. Headers are separated from content by a thin horizontal rule.
*   **Scrollbars:** Ultra-thin (4px), dark grey, appearing only on hover to reduce visual noise.

<!-- The "Visual Design System" sections above (Brand & Style → Components) plus the YAML frontmatter are synced from Stitch project "DoubleNaught Workflow Manager" (projects/4113127279095342047) on 2026-06-17. Source of truth for visual tokens: the Stitch design system; re-sync via the Stitch MCP rather than editing tokens by hand. WARNING: a full re-sync regenerates this file and will overwrite the hand-authored "Architecture Rules" section at the top — preserve it (or move it to ARCHITECTURE.md) before re-syncing. -->

