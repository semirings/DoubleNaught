import 'dart:typed_data';

/// The actual asset fetched behind an inventory location, plus the metadata a
/// downstream node needs to interpret it.
///
/// Inventory emits this on its `content` port once a location becomes active,
/// so downstream nodes receive real bytes rather than only a catalog row.
class ContentPayload {
  /// The location the bytes came from (web address or local path).
  final String sourceUrl;

  /// Raw asset bytes. Text is UTF-8 encoded; images are the encoded file.
  final Uint8List bytes;

  /// MIME type when the source reported one (e.g. `text/html`, `image/png`).
  final String? contentType;

  /// Catalog label for the entry this content belongs to.
  final String workTitle;

  /// Author when the entry is part of the curated corpus; empty otherwise.
  final String author;

  const ContentPayload({
    required this.sourceUrl,
    required this.bytes,
    required this.workTitle,
    this.contentType,
    this.author = '',
  });

  int get byteCount => bytes.length;

  /// True when the payload looks like an image rather than text/markup.
  bool get isImage => (contentType ?? '').startsWith('image/');
}
