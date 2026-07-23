import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/aa_payload.dart';
import 'aa_dataframe.dart';

/// Resolve a target string to an image provider. Web addresses load over the
/// network; everything else is treated as a local filesystem path (a bare path
/// or a `file://` URI). Local loading uses `dart:io` (desktop/mobile only).
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

/// What a Focus Panel tab shows.
enum FocusContentKind { image, text, aa }

/// A piece of heavy content routed to the Focus Panel by a node.
class FocusContent {
  final FocusContentKind kind;
  final String? text;
  final Uint8List? imageBytes;
  final String? imageUrl;
  final AaPayload? aa;

  /// One-line detail (size, dimensions, row×col count, source).
  final String? subtitle;

  const FocusContent._({
    required this.kind,
    this.text,
    this.imageBytes,
    this.imageUrl,
    this.aa,
    this.subtitle,
  });

  const FocusContent.image({Uint8List? bytes, String? url, String? subtitle})
      : this._(
            kind: FocusContentKind.image,
            imageBytes: bytes,
            imageUrl: url,
            subtitle: subtitle);

  const FocusContent.text(String value, {String? subtitle})
      : this._(kind: FocusContentKind.text, text: value, subtitle: subtitle);

  const FocusContent.aa(AaPayload value, {String? subtitle})
      : this._(kind: FocusContentKind.aa, aa: value, subtitle: subtitle);
}

/// One tab in the Focus Panel, owned by the node with [nodeId].
class FocusTab {
  final int nodeId;
  final String title;
  final FocusContent content;

  const FocusTab({
    required this.nodeId,
    required this.title,
    required this.content,
  });
}

/// The right-margin slideout Focus Panel: heavy content (images, prose, AA
/// dataframes) renders here in tabs, so canvas nodes stay compact routing boxes.
///
/// A slim rail on the leading edge stays visible to toggle open/closed; the body
/// animates between ~45% of the window and 0px, and hosts one tab per node that
/// has pushed content.
class FocusPanel extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onToggle;

  /// Content tabs, one per contributing node.
  final List<FocusTab> tabs;

  /// Index into [tabs] of the visible tab.
  final int selectedIndex;
  final ValueChanged<int> onSelectTab;

  /// Fraction of the window width the open panel occupies.
  final double openFraction;

  const FocusPanel({
    super.key,
    required this.isOpen,
    required this.onToggle,
    this.tabs = const [],
    this.selectedIndex = 0,
    required this.onSelectTab,
    this.openFraction = 0.45,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final openWidth = MediaQuery.sizeOf(context).width * openFraction;

    return Row(
      children: [
        _Rail(isOpen: isOpen, onToggle: onToggle),
        // Clip + OverflowBox keeps the body laid out at full width while the
        // container animates to 0, so nothing reflows during the slide.
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

    if (tabs.isEmpty) {
      return Center(
        child: Text('Nothing to display yet',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
      );
    }

    final index = selectedIndex.clamp(0, tabs.length - 1);
    final tab = tabs[index];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(
          tabs: tabs,
          selectedIndex: index,
          onSelect: onSelectTab,
        ),
        if (tab.content.subtitle != null && tab.content.subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(tab.content.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        Expanded(child: _content(context, tab.content)),
      ],
    );
  }

  Widget _content(BuildContext context, FocusContent content) {
    final theme = Theme.of(context);
    switch (content.kind) {
      case FocusContentKind.aa:
        return Padding(
          padding: const EdgeInsets.all(8),
          child: AaDataFrame(aa: content.aa!),
        );
      case FocusContentKind.text:
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              content.text ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        );
      case FocusContentKind.image:
        final provider = content.imageUrl != null
            ? resolveImageProvider(content.imageUrl!)
            : null;
        Widget image;
        if (provider != null) {
          image = Image(
            image: provider,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _placeholder(
                theme, 'That image could not be loaded.'),
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator()),
          );
        } else if (content.imageBytes != null) {
          image = Image.memory(content.imageBytes!,
              fit: BoxFit.contain, gaplessPlayback: true);
        } else {
          return _placeholder(theme, 'No image loaded');
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Center(child: image),
        );
    }
  }

  Widget _placeholder(ThemeData theme, String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
}

/// Horizontal tab strip across the top of the panel body.
class _TabStrip extends StatelessWidget {
  final List<FocusTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _TabStrip({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              InkWell(
                onTap: () => onSelect(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == selectedIndex
                            ? scheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    tabs[i].title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          i == selectedIndex ? FontWeight.w600 : FontWeight.w400,
                      color: i == selectedIndex
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
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
            message: isOpen ? 'Hide display panel' : 'Show display panel',
            child: IconButton(
              onPressed: onToggle,
              iconSize: 18,
              padding: const EdgeInsets.symmetric(vertical: 10),
              constraints: const BoxConstraints(),
              icon: Icon(isOpen ? Icons.chevron_right : Icons.chevron_left),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Center(
                child: Text(
                  'Display',
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
