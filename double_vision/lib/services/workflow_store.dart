import 'dart:convert';
import 'dart:io';

import '../models/aa_payload.dart';
import '../models/workflow.dart';
import 'aa_file.dart';

/// Lightweight listing entry for a saved workflow (for the Workflows dropdown).
class WorkflowMeta {
  /// Filename stem — the stable identifier used to load/overwrite/delete.
  final String slug;

  /// Human-entered display name.
  final String name;

  final int nodeCount;
  final int edgeCount;

  const WorkflowMeta({
    required this.slug,
    required this.name,
    this.nodeCount = 0,
    this.edgeCount = 0,
  });
}

/// Local persistence for **saved workflow graphs** — complete node+edge
/// configurations the user names and reloads onto the canvas. Distinct from
/// [InventoryStore], which persists the Inventory node's *source-work* catalog;
/// these are two different registries and live in two different files.
///
/// Each workflow is one JSON file at `storage/workflows/<slug>.json`, stored as
/// an **rcvs.json-conformant associative array** — the same `{rows, cols, vals}`
/// contract as the inventory/model catalogs — so every persisted structure in
/// DoubleNaught is one AA schema. The graph maps onto AA rows:
///  * `workflow` — meta row, cols `id` / `name` / `version`;
///  * `node:<id>` — one per node, cols `type` / `x` / `y`;
///  * `edge:<i>` — one per edge, cols `fromNode` / `fromIdx` / `toNode` / `toIdx`.
///
/// Reads also accept the legacy `{id,name,version,nodes,edges}` graph JSON, so
/// pre-existing files load and are rewritten as AA on the next save.
///
/// TODO: swap for backend API — becomes a workflows CRUD endpoint. Method
/// signatures are meant to survive that swap; only the bodies change. dart:io
/// makes this unavailable on Flutter web.
class WorkflowStore {
  static const _storageDir = String.fromEnvironment(
    'DN_STORAGE_DIR',
    defaultValue: '/Users/gcr/populi.Wk/DoubleNaught/storage',
  );

  static const _metaRow = 'workflow';
  static const _nodePrefix = 'node:';
  static const _edgePrefix = 'edge:';
  static const _paramPrefix = 'param:';

  /// Deliberate override (tests); when null the store uses [_storageDir].
  final String? overrideDir;

  WorkflowStore({this.overrideDir});

  String get dirPath => '${overrideDir ?? _storageDir}/workflows';

  File _fileFor(String slug) => File('$dirPath/$slug.json');

  /// Derive a filesystem-safe stem from a display name: lowercase, runs of
  /// non-alphanumerics collapsed to single hyphens, no leading/trailing hyphen.
  static String slugify(String name) {
    final b = StringBuffer();
    var pendingDash = false;
    for (final ch in name.trim().toLowerCase().codeUnits) {
      final isAlnum = (ch >= 0x30 && ch <= 0x39) || (ch >= 0x61 && ch <= 0x7a);
      if (isAlnum) {
        if (pendingDash && b.isNotEmpty) b.write('-');
        pendingDash = false;
        b.writeCharCode(ch);
      } else {
        pendingDash = true;
      }
    }
    final s = b.toString();
    return s.isEmpty ? 'workflow' : s;
  }

  Future<Directory> _ensureDir() async {
    final d = Directory(dirPath);
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Whether a workflow with [slug] already exists (uniqueness check).
  Future<bool> exists(String slug) => _fileFor(slug).exists();

  /// All saved workflows, sorted by display name (case-insensitive).
  Future<List<WorkflowMeta>> list() async {
    final d = Directory(dirPath);
    if (!await d.exists()) return const [];
    final metas = <WorkflowMeta>[];
    await for (final e in d.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final file = e.uri.pathSegments.last;
        final stem = file.endsWith('.json')
            ? file.substring(0, file.length - '.json'.length)
            : file;
        final decoded = jsonDecode(await e.readAsString());
        metas.add(_metaFromDecoded(decoded, stem));
      } catch (_) {
        // Skip a corrupt/partial file rather than fail the whole listing.
      }
    }
    metas.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return metas;
  }

  /// Load a workflow graph by [slug], or null if absent/empty.
  Future<Workflow?> read(String slug) async {
    final f = _fileFor(slug);
    if (!await f.exists()) return null;
    final txt = await f.readAsString();
    if (txt.trim().isEmpty) return null;
    final decoded = jsonDecode(txt);
    // AA form (rcvs {rows,cols,vals}).
    if (decoded is Map<String, dynamic> && decoded['cols'] is List) {
      return _workflowFromAa(AaFile.decode(decoded));
    }
    // Legacy graph form {version,nodes,edges}.
    if (decoded is Map<String, dynamic>) {
      return Workflow.fromJson(decoded);
    }
    return null;
  }

  /// Persist [workflow] under [slug] with the display [name] (create/overwrite)
  /// as an rcvs.json-conformant AA.
  Future<void> write(String slug, String name, Workflow workflow) async {
    await _ensureDir();
    final aa = _toAa(slug, name, workflow);
    await _fileFor(
      slug,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(aa.toJson()));
  }

  /// Delete the workflow under [slug]; true if a file was removed.
  Future<bool> delete(String slug) async {
    final f = _fileFor(slug);
    if (!await f.exists()) return false;
    await f.delete();
    return true;
  }

  // --- AA <-> Workflow codec -------------------------------------------------

  /// Encode a workflow (plus its [slug]/[name] identity) as a single AA.
  AaPayload _toAa(String slug, String name, Workflow wf) {
    final rows = <String>[];
    final cols = <String>[];
    final vals = <Object>[];
    void add(String row, String col, Object val) {
      rows.add(row);
      cols.add(col);
      vals.add(val);
    }

    add(_metaRow, 'id', slug);
    add(_metaRow, 'name', name);
    add(_metaRow, 'version', wf.version);
    for (final n in wf.nodes) {
      final r = '$_nodePrefix${n.id}';
      add(r, 'type', n.type);
      add(r, 'x', n.x);
      add(r, 'y', n.y);
      // Per-node saved settings ride as `param:<key>` columns on the node row.
      for (final e in n.params.entries) {
        add(r, '$_paramPrefix${e.key}', e.value);
      }
    }
    for (var i = 0; i < wf.edges.length; i++) {
      final e = wf.edges[i];
      final r = '$_edgePrefix$i';
      add(r, 'fromNode', e.from.nodeId);
      add(r, 'fromIdx', e.from.idx);
      add(r, 'toNode', e.to.nodeId);
      add(r, 'toIdx', e.to.idx);
    }
    return AaPayload(rows: rows, cols: cols, vals: vals);
  }

  Workflow _workflowFromAa(AaPayload aa) {
    final byRow = AaFile.groupByRow(aa);
    final meta = byRow[_metaRow] ?? const {};
    final nodes = <WorkflowNode>[];
    final edges = <WorkflowEdge>[];
    for (final entry in byRow.entries) {
      final row = entry.key;
      final m = entry.value;
      if (row.startsWith(_nodePrefix)) {
        final id = int.tryParse(row.substring(_nodePrefix.length));
        if (id == null) continue;
        final params = <String, String>{
          for (final e in m.entries)
            if (e.key.startsWith(_paramPrefix))
              e.key.substring(_paramPrefix.length): e.value,
        };
        nodes.add(
          WorkflowNode(
            id: id,
            type: m['type'] ?? '',
            x: double.tryParse(m['x'] ?? '') ?? 0,
            y: double.tryParse(m['y'] ?? '') ?? 0,
            params: params,
          ),
        );
      } else if (row.startsWith(_edgePrefix)) {
        final fromNode = int.tryParse(m['fromNode'] ?? '');
        final toNode = int.tryParse(m['toNode'] ?? '');
        if (fromNode == null || toNode == null) continue;
        edges.add(
          WorkflowEdge(
            from: PortRef(
              nodeId: fromNode,
              idx: int.tryParse(m['fromIdx'] ?? '') ?? 0,
            ),
            to: PortRef(
              nodeId: toNode,
              idx: int.tryParse(m['toIdx'] ?? '') ?? 0,
            ),
          ),
        );
      }
    }
    return Workflow(
      version: meta['version'] ?? '0.1.0',
      nodes: nodes,
      edges: edges,
    );
  }

  /// Build listing metadata from a decoded file, accepting both the AA form and
  /// the legacy graph form.
  WorkflowMeta _metaFromDecoded(Object? decoded, String stem) {
    if (decoded is Map<String, dynamic> && decoded['cols'] is List) {
      final byRow = AaFile.groupByRow(AaFile.decode(decoded));
      final meta = byRow[_metaRow] ?? const {};
      var nodeCount = 0;
      var edgeCount = 0;
      for (final row in byRow.keys) {
        if (row.startsWith(_nodePrefix)) {
          nodeCount++;
        } else if (row.startsWith(_edgePrefix)) {
          edgeCount++;
        }
      }
      return WorkflowMeta(
        slug: meta['id'] ?? stem,
        name: meta['name'] ?? stem,
        nodeCount: nodeCount,
        edgeCount: edgeCount,
      );
    }
    final map = decoded is Map<String, dynamic> ? decoded : const {};
    return WorkflowMeta(
      slug: (map['id'] as String?) ?? stem,
      name: (map['name'] as String?) ?? stem,
      nodeCount: (map['nodes'] as List?)?.length ?? 0,
      edgeCount: (map['edges'] as List?)?.length ?? 0,
    );
  }
}
