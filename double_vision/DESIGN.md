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

<!-- Synced from Stitch project "DoubleNaught Workflow Manager" (projects/4113127279095342047) on 2026-06-17. Source of truth: Stitch design system. Re-sync via the Stitch MCP rather than editing tokens here by hand. -->
