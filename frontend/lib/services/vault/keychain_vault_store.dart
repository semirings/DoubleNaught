import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'vault_store.dart';

/// Desktop and mobile vault backing: **OS-level secure storage** — macOS
/// Keychain, Linux Secret Service (libsecret), Windows DPAPI/credential store,
/// iOS Keychain, Android EncryptedSharedPreferences.
///
/// The OS owns the key material and the at-rest encryption; nothing in this
/// process holds a decryption key, so a read of the app's own files yields
/// nothing. Entries are namespaced so a `keys()` sweep can't see — or delete —
/// another app's secrets sharing the same keychain service.
class KeychainVaultStore implements VaultStore {
  /// Prefix on every entry this store owns.
  static const String namespace = 'dn.vault.';

  final FlutterSecureStorage _storage;

  KeychainVaultStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Bind items to this device and require the device to be unlocked:
              // a synced or backed-up keychain would carry API keys off-machine.
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
              mOptions: MacOsOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
                // macOS's *data-protection* keychain (the plugin's default)
                // requires a `keychain-access-groups` entitlement, and that
                // entitlement in turn requires signing with a development
                // certificate — which makes `flutter run`'s ad-hoc-signed debug
                // build fail to build at all ("has entitlements that require
                // signing with a development certificate"). Without the
                // entitlement every write fails with -34018
                // errSecMissingEntitlement instead.
                //
                // The file-based keychain has neither requirement and is what a
                // desktop Mac app normally uses: items land in the login
                // keychain, encrypted by the OS, with no signing identity
                // needed. Verified end-to-end by
                // `integration_test/keychain_vault_test.dart`.
                usesDataProtectionKeychain: false,
              ),
              // v11's default is already AES-GCM data encryption with
              // RSA-OAEP KeyStore key wrapping — the old
              // `encryptedSharedPreferences` flag no longer exists.
              aOptions: AndroidOptions(),
            );

  String _k(String key) => '$namespace$key';

  @override
  Future<String?> read(String key) => _storage.read(key: _k(key));

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: _k(key), value: value);

  /// Deleting is idempotent.
  ///
  /// The file-based keychain fails a delete of an entry it does not hold —
  /// observed as `-34018` rather than a not-found code — and the vault deletes
  /// from *both* stores when it retires or migrates a profile, so one of those
  /// calls routinely targets a key that was never there. Absence is the intended
  /// end state, so it is success, not an error.
  @override
  Future<void> delete(String key) async {
    if (await read(key) == null) return;
    try {
      await _storage.delete(key: _k(key));
    } on PlatformException {
      // Lost a race with another delete — still absent, still fine.
    }
  }
}
