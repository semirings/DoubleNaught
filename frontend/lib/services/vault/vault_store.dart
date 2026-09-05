/// Opaque key→value storage with platform-appropriate protection at rest.
///
/// Implementations are the vault's storage half (see `DESIGN.md` → "Secure
/// Settings node" → Storage layer):
///
/// * [KeychainVaultStore] — OS keychain / Secret Service, on desktop and mobile.
/// * `EncryptedIdbVaultStore` — AES-GCM into IndexedDB, on web.
/// * [SessionVaultStore] — RAM only, for "Session Storage Only" profiles.
///
/// The profile *index* rides in the same store under [profilesKey]. Profiles
/// carry no secrets, so this costs nothing and buys one storage path per
/// platform instead of two.
abstract class VaultStore {
  /// Reserved key holding the JSON profile index.
  static const String profilesKey = '__dn_profiles__';

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  // Deliberately no `keys()`/enumerate: macOS's file-based keychain rejects a
  // readAll with -50 errSecParam, so it cannot be honored on every backing — and
  // nothing needs it, since the profile index under [profilesKey] already lists
  // everything the vault holds. Keeping it in the contract would have meant one
  // backing that throws.
}

/// Volatile store for profiles marked **Session Storage Only** — the secret
/// exists in this process's heap and nowhere else, so closing the app is the
/// erasure step. Chosen deliberately over a keychain entry the user would have
/// to remember to revoke.
class SessionVaultStore implements VaultStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  /// Not part of [VaultStore] — kept here because a RAM map can honor it.
  Future<Set<String>> keys() async => _values.keys.toSet();

  /// Drop every in-RAM secret — e.g. an explicit "lock the vault" action.
  void clear() => _values.clear();
}
