import 'dart:convert';

import 'package:http/http.dart' as http;
import '../backend_config.dart';

/// Why a workflow delete did not happen.
///
/// The distinction matters to the caller: a *conflict* is a deliberate refusal to
/// be reported to the user, while [unreachable] means the backend never answered
/// and the local store is still the source of truth.
enum WorkflowDeleteFailure {
  /// 404 — the backend has no such workflow. From the caller's point of view the
  /// workflow is already gone, so this is usually not worth an error.
  notFound,

  /// 409 — the execution engine reports tasks in flight for this workflow.
  conflict,

  /// The request never completed: backend down, wrong port, timeout.
  unreachable,

  /// Any other non-200.
  serverError,
}

/// A delete that did not succeed, with enough detail to decide what to do next.
class WorkflowDeleteException implements Exception {
  final WorkflowDeleteFailure reason;

  /// The backend's `detail`, or the transport error, already trimmed for display.
  final String message;

  /// HTTP status, when there was a response.
  final int? statusCode;

  const WorkflowDeleteException(this.reason, this.message, {this.statusCode});

  /// Whether the caller may fall back to deleting from local storage.
  ///
  /// Only when the backend never answered. A 409 is a *refusal* — falling back
  /// would delete a workflow the server just said is running, which is exactly
  /// the outcome the status code exists to prevent.
  bool get allowsLocalFallback => reason == WorkflowDeleteFailure.unreachable;

  @override
  String toString() => message;
}

/// API client for workflow CRUD (`/workflows`).
///
/// Saved workflows are files under `storage/workflows/`, which the backend and the
/// Flutter [WorkflowStore] both address on the same machine — the backend's
/// `workflow_id` is the store's `slug`.
class WorkflowApi {
  final String baseUrl;

  /// Injected in tests. When null, each call uses (and closes) its own client.
  final http.Client? client;

  const WorkflowApi({
    this.baseUrl = BackendConfig.baseUrl,
    this.client,
  });

  /// Delete the saved workflow [workflowId].
  ///
  /// Returns true when the backend deleted it. Throws
  /// [WorkflowDeleteException] otherwise — including for 404 and 409, so the
  /// caller can tell "already gone" from "refused because it is running" rather
  /// than reading a bare false.
  Future<bool> deleteWorkflow(String workflowId) async {
    final own = client == null ? http.Client() : null;
    final transport = client ?? own!;
    http.Response response;
    try {
      response = await transport.delete(
        Uri.parse('$baseUrl/workflows/${Uri.encodeComponent(workflowId)}'),
        headers: {'Accept': 'application/json'},
      );
    } catch (e) {
      // Type name only, never the raw exception: it can carry the host and port.
      throw WorkflowDeleteException(
        WorkflowDeleteFailure.unreachable,
        'Backend unreachable (${e.runtimeType})',
      );
    } finally {
      own?.close();
    }

    if (response.statusCode == 200) return true;

    throw WorkflowDeleteException(
      switch (response.statusCode) {
        404 => WorkflowDeleteFailure.notFound,
        409 => WorkflowDeleteFailure.conflict,
        _ => WorkflowDeleteFailure.serverError,
      },
      _detailOf(response),
      statusCode: response.statusCode,
    );
  }

  /// FastAPI's `detail`, falling back to the status line.
  static String _detailOf(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) return '${body['detail']}';
    } catch (_) {
      // Not JSON — fall through.
    }
    return 'HTTP ${response.statusCode}';
  }
}
