import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:idb_shim/idb_shim.dart';

import 'idb_platform_stub.dart'
    if (dart.library.js_interop) 'idb_platform_web.dart';
import 'secret_envelope.dart';
import 'vault_store.dart';

/// Web/WASM vault backing: every value is sealed with **AES-256-GCM** before it
/// reaches IndexedDB, so the secrets object store holds only ciphertext, a
/// per-write nonce, and a MAC.
///
/// ## What this does and does not protect
///
/// The browser gives no OS keychain, so the data key has to live somewhere the
/// page can reach — here, its own IndexedDB store. That means:
///
/// * **Protects against** anything that reads the secrets store without also
///   reading the key store, and anything reading persisted bytes off disk or a
///   profile backup: DevTools browsing, an exported IndexedDB dump, another
///   origin, a backup sweep. Tampering is detected — GCM's MAC makes a modified
///   record fail to open rather than decrypt to garbage.
/// * **Does not protect against** script running on this origin. Anything that
///   can execute here can read the key store too. On the web the honest ceiling
///   is obfuscation-plus-integrity, not confidentiality against local code — a
///   user who needs that should mark the profile **Session Storage Only** (RAM,
///   nothing persisted) or run the desktop build, where the OS holds the key.
///
/// A passphrase-derived key (PBKDF2/Argon2) would close that gap, at the cost of
/// a prompt on every app start. The spec asks for AES-GCM at rest, so that is
/// what this implements; the passphrase variant is a deliberate non-goal, not an
/// oversight.
class EncryptedIdbVaultStore implements VaultStore {
  static const String _dbName = 'dn_key_vault';
  static const String _secretsStore = 'secrets';
  static const String _keyStore = 'keys';
  static const String _dataKeyId = 'data_key_v1';
  static const int _dbVersion = 1;

  final IdbFactory _factory;
  final SecretEnvelope _envelope = SecretEnvelope();

  Database? _db;
  String? _dataKeyBase64;

  /// [factory] defaults to the platform's IndexedDB; tests pass
  /// `idbFactoryMemory`, which exercises this class's real encryption path
  /// against a real (in-memory) IndexedDB implementation.
  EncryptedIdbVaultStore({IdbFactory? factory})
      : _factory = factory ?? platformIdbFactory;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    return _db = await _factory.open(
      _dbName,
      version: _dbVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(_secretsStore)) {
          db.createObjectStore(_secretsStore);
        }
        if (!db.objectStoreNames.contains(_keyStore)) {
          db.createObjectStore(_keyStore);
        }
      },
    );
  }

  /// The AES key for this browser profile — generated on first use and reused
  /// after that, so values written in an earlier session still open.
  Future<String> _keyBase64() async {
    final cached = _dataKeyBase64;
    if (cached != null) return cached;

    final db = await _open();
    final read = db.transaction(_keyStore, idbModeReadOnly);
    final stored = await read.objectStore(_keyStore).getObject(_dataKeyId);
    await read.completed;
    if (stored is String) return _dataKeyBase64 = stored;

    final generated = await _envelope.newKeyBase64();
    final write = db.transaction(_keyStore, idbModeReadWrite);
    await write.objectStore(_keyStore).put(generated, _dataKeyId);
    await write.completed;
    return _dataKeyBase64 = generated;
  }

  @override
  Future<String?> read(String key) async {
    final db = await _open();
    final txn = db.transaction(_secretsStore, idbModeReadOnly);
    final record = await txn.objectStore(_secretsStore).getObject(key);
    await txn.completed;
    if (record is! Map) return null;
    return _envelope.open(
      record,
      _envelope.keyFromBase64(await _keyBase64()),
    );
  }

  @override
  Future<void> write(String key, String value) async {
    final db = await _open();
    final sealed = await _envelope.seal(
      value,
      _envelope.keyFromBase64(await _keyBase64()),
    );
    final txn = db.transaction(_secretsStore, idbModeReadWrite);
    await txn.objectStore(_secretsStore).put(sealed, key);
    await txn.completed;
  }

  @override
  Future<void> delete(String key) async {
    final db = await _open();
    final txn = db.transaction(_secretsStore, idbModeReadWrite);
    await txn.objectStore(_secretsStore).delete(key);
    await txn.completed;
  }

  /// Not part of [VaultStore] — kept here because IndexedDB can honor it, and
  /// the store's own tests assert on it.
  Future<Set<String>> keys() async {
    final db = await _open();
    final txn = db.transaction(_secretsStore, idbModeReadOnly);
    final all = await txn.objectStore(_secretsStore).getAllKeys();
    await txn.completed;
    return all.map((k) => '$k').toSet();
  }

  Future<void> close() async {
    _db?.close();
    _db = null;
    _dataKeyBase64 = null;
  }

  /// The sealed record exactly as stored — for tests asserting that what lands
  /// at rest is ciphertext, and that each write carries a fresh nonce.
  ///
  /// Goes through this store's own connection on purpose: a second handle to the
  /// same database shares the underlying instance, so closing it invalidates
  /// this one.
  @visibleForTesting
  Future<Map<Object?, Object?>?> debugRawRecord(String key) async {
    final db = await _open();
    final txn = db.transaction(_secretsStore, idbModeReadOnly);
    final record = await txn.objectStore(_secretsStore).getObject(key);
    await txn.completed;
    return record is Map ? record : null;
  }

  /// Overwrite a record's stored bytes without re-sealing them — lets a test
  /// corrupt ciphertext and prove the MAC check fails closed.
  @visibleForTesting
  Future<void> debugPutRaw(String key, Map<Object?, Object?> record) async {
    final db = await _open();
    final txn = db.transaction(_secretsStore, idbModeReadWrite);
    await txn.objectStore(_secretsStore).put(record, key);
    await txn.completed;
  }
}
