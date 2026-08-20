import 'package:flutter/material.dart';

/// Shared rules and UI for any field labeled "URL" — see
/// `UX_UI/GLOBAL_UX_CONTRACT.md` §6. Used by both Load File and Save File
/// (and any future URL-bearing node).
///
/// A plain namespace of static members, not a mixin: there is no per-node
/// instance state to compose here (Dart's static members aren't inherited
/// through `with` anyway), only validation and a widget builder every
/// URL-labeled field shares. The file-dialog button itself stays
/// node-specific — Load File opens a file-or-directory picker, Save File a
/// save-location picker — only the text field, its validation, and its
/// error display live here.
class IOSupport {
  const IOSupport._();

  /// The only schemes a URL field accepts. No `git`, `ftp`, `ssh`, or
  /// invented scheme, and no bare/schemeless path: the file-dialog button
  /// beside this field always produces a proper `file://` URL when picking
  /// a location, so a bare path can only ever be one the user typed
  /// directly — which is exactly the malformed-input case this field's
  /// error state exists for.
  static const Set<String> allowedUrlSchemes = {'file', 'http', 'https'};

  /// Whether [url] is non-empty, parses as a URI, AND has one of
  /// [allowedUrlSchemes]. `Uri.tryParse` alone is not sufficient — it
  /// accepts almost any non-empty string (including a bare relative path
  /// with no scheme at all), so the scheme is checked explicitly on top of
  /// it. This is the client-side format check that gates **Execute**
  /// (`UX_UI/GLOBAL_UX_CONTRACT.md` §2); the backend, which actually reads
  /// or writes the file, remains the final authority on whether the URL
  /// resolves to something real.
  static bool isValidUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    return allowedUrlSchemes.contains(uri.scheme);
  }

  /// Only shown once there is non-empty text that fails [isValidUrl] — an
  /// untouched, empty field is simply disabled, not flagged as an error.
  static bool showsInvalid(String url) =>
      url.trim().isNotEmpty && !isValidUrl(url);

  /// [path] as a `file://` URI — unchanged if it already is one. Every
  /// node's file-dialog result goes through this before landing in the URL
  /// field, so the field only ever holds a real URL, never a bare OS path.
  static String pathToFileUri(String path) =>
      path.startsWith('file://') ? path : Uri.file(path).toString();

  /// The standard URL field: a labeled [TextField] with [controller], plus
  /// [trailing] (the node-specific file-dialog icon button) beside it, and
  /// the shared invalid-URL error text once applicable.
  static Widget field({
    required TextEditingController controller,
    required bool enabled,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            decoration: InputDecoration(
              labelText: 'URL',
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              errorText: showsInvalid(controller.text) ? 'Invalid URL' : null,
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 4),
          trailing,
        ],
      ],
    );
  }
}
