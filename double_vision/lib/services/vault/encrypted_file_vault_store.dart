import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'secret_envelope.dart';
import 'vault_store.dart';

/// Desktop vault backing that does **not** involve the OS keychain: AES-256-GCM
/// sealed values in a JSON file under the app-support directory, with the data
/// key in a sibling file.
///
/// ## Why this exists
///
/// The macOS keychain is unusable from a build with no signing identity, in both
/// of its flavors:
///
/// * The **data-protection** keychain needs a `keychain-access-groups`
///   entitlement, which needs a development certificate — and adding the
///   entitlement without one fails the build outright.
/// * The **file-based** login keychain records the accessing app's *code
///   signature* in each item's ACL. An ad-hoc-signed binary has no stable
///   identity to record, so "Always Allow" has nothing to persist and macOS
///   re-prompts on every access — an unbreakable password loop, not a slow path.
///
/// So a vault that only knows how to use the keychain simply does not work on an
/// unsigned desktop build. This backing keeps the feature usable there.
///
/// ## What it protects, and what it does not
///
/// Same honest ceiling as the web backing, for the same reason — the key has to
/// live somewhere this process can read unaided:
///
/// * **Protects** the bytes at rest and detects tampering: a file copied out of a
///   backup, a synced Application Support folder, or a casual look at the JSON
///   yields ciphertext, and GCM's MAC makes an edited record fail to open rather
///   than decrypt to garbage.
/// * **Does not protect** against code running as this user, which can read the
///   key file too. That is strictly weaker than the OS keychain, which is why
///   [KeychainVaultStore] stays the choice wherever the app is properly signed.
///
/// Users who need more should mark the profile **Session Storage Only** (RAM,
/// nothing persisted) or set up code signing and switch back to the keychain.
class EncryptedFileVaultStore implements VaultStore {
  static const String _dirName = 'dn_key_vault';
  static const String _secretsFile = 'secrets.json';
  static const String _keyFile = 'data_key';

  final SecretEnvelope _envelope = SecretEnvelope();

  /// Overridden in tests with a temp directory; production resolves app-support.
  final Future<Directory> Function() _directory;

  EncryptedFileVaultStore({Future<Directory> Function()? directory})
      : _directory = directory ?? _appSupportDir;

  static Future<Directory> _appSupportDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/$_dirName');
  }

  Directory? _dir;
  Map<String, Object?>? _records;

  Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final dir = await _directory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  /// The key for this installation — generated on first use, reused after, so
  /// values written in an earlier run still open.
  ///
  /// Written with owner-only permissions where the platform supports it. That is
  /// a speed bump against another *user* on the machine, not against this user's
  /// own processes; see the class doc.
  Future<String> _keyBase64() async {
    final dir = await _ensureDir();
    final file = File('${dir.path}/$_keyFile');
    if (file.existsSync()) {
      final existing = file.readAsStringSync().trim();
      if (existing.isNotEmpty) return existing;
    }
    final generated = await _envelope.newKeyBase64();
    file.writeAsStringSync(generated, flush: true);
    _restrictPermissions(file);
    return generated;
  }

  static void _restrictPermissions(File file) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('/bin/chmod', ['600', file.path]);
    } catch (_) {
      // Best effort — the envelope, not the file mode, is what protects the
      // contents.
    }
  }

  Future<Map<String, Object?>> _load() async {
    final cached = _records;
    if (cached != null) return cached;

    final dir = await _ensureDir();
    final file = File('${dir.path}/$_secretsFile');
    if (!file.existsSync()) return _records = {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return _records = decoded is Map<String, Object?> ? decoded : {};
    } catch (_) {
      // A truncated or hand-edited file must not take the app down; treat it as
      // empty and let the next write replace it.
      return _records = {};
    }
  }

  Future<void> _flush(Map<String, Object?> records) async {
    final dir = await _ensureDir();
    final file = File('${dir.path}/$_secretsFile');
    file.writeAsStringSync(jsonEncode(records), flush: true);
    _restrictPermissions(file);
    _records = records;
  }

  @override
  Future<String?> read(String key) async {
    final records = await _load();
    final record = records[key];
    if (record is! Map) return null;
    return _envelope.open(record, _envelope.keyFromBase64(await _keyBase64()));
  }

  @override
  Future<void> write(String key, String value) async {
    final records = Map<String, Object?>.of(await _load());
    records[key] = await _envelope.seal(
      value,
      _envelope.keyFromBase64(await _keyBase64()),
    );
    await _flush(records);
  }

  @override
  Future<void> delete(String key) async {
    final records = Map<String, Object?>.of(await _load());
    if (records.remove(key) == null) return;
    await _flush(records);
  }

  /// Where the vault lives on disk — surfaced so the UI can tell the user which
  /// backing is in use rather than leaving them to guess.
  Future<String> location() async => (await _ensureDir()).path;
}
