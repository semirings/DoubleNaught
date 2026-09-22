import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:aa_preview_table/aa_preview_table.dart';
import '../backend_config.dart';

/// Thin client for the InventoryNode routes on the DoubleTouch backend
/// (`backend/`), targeting the camelCase contract:
///
///  * `GET    /inventory`               — → the full inventory (as an AA)
///  * `POST   /inventory`               — `{url, author, workTitle, workSelector?,
///    description?}` → updated inventory
///  * `PUT    /inventory/{id}`          — same body → updated inventory
///  * `DELETE /inventory/{id}`          — → updated inventory
///  * `POST   /inventory/{id}/select`   — → the selected entry as an AA payload
///
/// The CRUD calls return the whole inventory (parsed into [InventoryEntry]s);
/// `select` returns the single-entry [AaPayload] for URLNode.
class InventoryApi {
  final String baseUrl;

  const InventoryApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  Future<List<InventoryEntry>> list() async =>
      _entries(await _send('GET', '/inventory'));

  Future<List<InventoryEntry>> create(InventoryFields fields) async =>
      _entries(await _send('POST', '/inventory', fields.toJson()));

  Future<List<InventoryEntry>> update(String entryId, InventoryFields fields) async =>
      _entries(await _send('PUT', '/inventory/$entryId', fields.toJson()));

  Future<List<InventoryEntry>> delete(String entryId) async =>
      _entries(await _send('DELETE', '/inventory/$entryId'));

  /// Emit the chosen entry as an AA payload for the downstream URLNode.
  Future<AaPayload> select(String entryId) async {
    final body = await _send('POST', '/inventory/$entryId/select');
    return AaPayload.fromJson(body['aa'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse('$baseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    final response = switch (method) {
      'GET' => await http.get(uri),
      'POST' => await http.post(uri, headers: _jsonHeaders, body: encoded),
      'PUT' => await http.put(uri, headers: _jsonHeaders, body: encoded),
      'DELETE' => await http.delete(uri, headers: _jsonHeaders, body: encoded),
      _ => throw ArgumentError('unsupported method $method'),
    };
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw InventoryApiException(path, response.statusCode, response.body);
  }

  /// Reconstruct entries from the inventory AA, preserving row order.
  List<InventoryEntry> _entries(Map<String, dynamic> body) {
    final aa = body['aa'] as Map<String, dynamic>;
    final rows = (aa['rows'] as List? ?? const []);
    final cols = (aa['cols'] as List? ?? const []);
    final vals = (aa['vals'] as List? ?? const []);
    final order = <String>[];
    final byRow = <String, Map<String, String>>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i].toString();
      byRow.putIfAbsent(row, () {
        order.add(row);
        return <String, String>{};
      })[cols[i].toString()] = vals[i].toString();
    }
    return [
      for (final row in order)
        InventoryEntry(
          entryId: row,
          url: byRow[row]?['url'] ?? '',
          author: byRow[row]?['author'] ?? '',
          workTitle: byRow[row]?['work_title'] ?? '',
          workSelector: byRow[row]?['work_selector'] ?? '',
          description: byRow[row]?['description'] ?? '',
        ),
    ];
  }
}

/// One inventory entry (a row of the inventory AA).
class InventoryEntry {
  final String entryId;
  final String url;
  final String author;
  final String workTitle;
  final String workSelector;
  final String description;

  const InventoryEntry({
    required this.entryId,
    required this.url,
    required this.author,
    required this.workTitle,
    required this.workSelector,
    required this.description,
  });
}

/// The editable fields for create / update (no entry id).
class InventoryFields {
  final String url;
  final String author;
  final String workTitle;
  final String workSelector;
  final String description;

  /// Only [url] is required. A bare location captured from a URL Source node
  /// has no curated author, and the backend derives [workTitle] when omitted.
  const InventoryFields({
    required this.url,
    this.author = '',
    this.workTitle = '',
    this.workSelector = '',
    this.description = '',
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'author': author,
        'workTitle': workTitle,
        'workSelector': workSelector,
        'description': description,
      };
}

/// Raised when an inventory route returns a non-200 response.
class InventoryApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  InventoryApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'InventoryApiException($path → $statusCode): $body';
}
