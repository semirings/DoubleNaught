import 'package:aa_preview_table/aa_preview_table.dart';

/// DN's own single-triple "node status" convention — kept out of the shared
/// `aa_preview_table` package because it hardcodes DN-specific row/col keys
/// (`'status'`/`'status'`), which a domain-agnostic shared type shouldn't
/// bake in. Built on the shared package's generic [AaPayload.single] and
/// matches the exact triple shape the retired `double_vision` `AaPayload`'s
/// own `status()` factory used to produce — including `agent_node.dart`'s
/// existing use of it as a one-off `'result'` payload, which is preserved
/// unchanged here rather than "fixed".
///
/// This is a top-level function rather than a factory constructor: Dart has
/// no mechanism to add a constructor to an already-defined class from
/// outside its own library, so callers use `aaStatusPayload(state)` rather
/// than the retired `AaPayload.status(state)` call syntax.
AaPayload aaStatusPayload(String state) =>
    AaPayload.single('status', 'status', state);
