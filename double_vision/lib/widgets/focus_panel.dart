import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Interactive modes the image viewport is built to host. Only [none] is wired
/// today — the overlay layer below the image is structured so text prompt,
/// box-select and point-click modes can be added without disturbing the panel
/// layout or the node graph.
enum ImageOverlayMode { none, textPrompt, boxSelect, pointClick }

/// Resolve a target string to an image provider. Web addresses load over the
/// network; everything else is treated as a local filesystem path (a bare path
/// or a `file://` URI).
///
/// Local loading uses `dart:io` and is therefore desktop/mobile only.
ImageProvider? resolveImageProvider(String targetUrl) {
  final trimmed = targetUrl.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return NetworkImage(trimmed);
  }
  if (uri != null && uri.scheme == 'file') {
    return FileImage(File(uri.toFilePath()));
  }
  return FileImage(File(trimmed));
}

/// The right-margin slideout Focus Panel: heavy content (images, large prose)
/// renders here so nodes on the canvas stay compact routing boxes.
///
/// Shares a horizontal layout shell with the canvas. A slim rail on the leading
/// edge stays visible at all times so the panel can be toggled open or closed;
/// the panel body animates between ~45% of the window and 0px.
class FocusPanel extends StatelessWidget {
  /// Whether the panel body is expanded.
  final bool isOpen;

  /// Toggles [isOpen] from the leading-edge rail.
  final VoidCallback onToggle;

  /// Heading for the focused node's assets.
  final String title;

  /// Optional subtitle (filename, source label).
  final String? subtitle;

  /// A local path or web address to load, when the focused node has one.
  final String? targetUrl;

  /// In-memory image, for nodes that already hold decoded bytes.
  final Uint8List? imageBytes;

  /// Which interactive overlay the viewport should host.
  final ImageOverlayMode overlayMode;

  /// Fraction of the window width the open panel occupies.
  final double openFraction;

  const FocusPanel({
    super.key,
    required this.isOpen,
    required this.onToggle,
    this.title = 'Image Assets',
    this.subtitle,
    this.targetUrl,
    this.imageBytes,
    this.overlayMode = ImageOverlayMode.none,
    this.openFraction = 0.45,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final openWidth = MediaQuery.sizeOf(context).width * openFraction;

    return Row(
      children: [
        _Rail(isOpen: isOpen, onToggle: onToggle),
        // Clip + OverflowBox keeps the body laid out at its full width while
        // the container animates to 0, so nothing reflows during the slide.
        ClipRect(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            width: isOpen ? openWidth : 0,
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              border: Border(left: BorderSide(color: scheme.outlineVariant)),
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: openWidth,
              maxWidth: openWidth,
              child: _body(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(child: _viewport(context)),
      ],
    );
  }

  /// The image viewport. Built as a [Stack] so interactive overlays can be
  /// layered over the image later without changing this structure.
  Widget _viewport(BuildContext context) {
    final theme = Theme.of(context);
    final provider =
        targetUrl == null ? null : resolveImageProvider(targetUrl!);

    Widget image;
    if (provider != null) {
      image = Image(
        image: provider,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _placeholder(
          theme,
          'That image could not be loaded. Check the path or address.',
        ),
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : const Center(child: CircularProgressIndicator()),
      );
    } else if (imageBytes != null) {
      image = Image.memory(imageBytes!,
          fit: BoxFit.contain, gaplessPlayback: true);
    } else {
      return _placeholder(theme, 'No image loaded');
    }

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: image),
          // Overlay layer: the interaction surface for future text prompt,
          // box-select and point-click modes. Inert while mode is `none`.
          if (overlayMode != ImageOverlayMode.none)
            const Positioned.fill(child: SizedBox.shrink()),
        ],
      ),
    );
  }

  Widget _placeholder(ThemeData theme, String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
}

/// Always-visible vertical rail on the panel's leading edge.
class _Rail extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onToggle;

  const _Rail({required this.isOpen, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 28,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        children: [
          Tooltip(
            message: isOpen ? 'Hide image assets' : 'Show image assets',
            child: IconButton(
              onPressed: onToggle,
              iconSize: 18,
              padding: const EdgeInsets.symmetric(vertical: 10),
              constraints: const BoxConstraints(),
              icon: Icon(isOpen ? Icons.chevron_right : Icons.chevron_left),
            ),
          ),
          const SizedBox(height: 4),
          // Vertical tab label along the rail.
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Center(
                child: Text(
                  'Image Assets',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
