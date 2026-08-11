import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../models/auth_profile.dart';
import 'encrypted_file_vault_store.dart';
import 'encrypted_idb_vault_store.dart';
import 'keychain_vault_store.dart';
import 'vault_store.dart';

/// The vault: profile metadata plus the secret each profile points at.
///
/// Two stores sit behind it — a **persistent** one (OS keychain on desktop and
/// mobile, AES-GCM-over-IndexedDB on web) and a **session** one (RAM). A
/// profile's `sessionOnly` flag decides which holds its secret; the profile
/// index itself always lives in the persistent store, since it carries no
/// secrets.
///
/// The read API is deliberately narrow: [secretFor] is the *only* way a key
/// comes back out, so every read is one greppable call site.
class KeyVault {
  final VaultStore persistent;
  final SessionVaultStore session;

  /// Which desktop backing to use, from `--dart-define=DN_VAULT=...`:
  /// `file` (default) or `keychain`.
  static const String _backing =
      String.fromEnvironment('DN_VAULT', defaultValue: 'file');

  /// Whether the persistent backing is the OS keychain.
  static bool get usesKeychain => !kIsWeb && _backing == 'keychain';

  KeyVault({VaultStore? persistent, SessionVaultStore? session})
      : persistent = persistent ?? _defaultStore(),
        session = session ?? SessionVaultStore();

  /// Pick the persistent backing.
  ///
  /// Web has no keychain, so it gets the encrypted IndexedDB store. Desktop
  /// **defaults to the encrypted file** rather than the OS keychain, because the
  /// keychain is unusable from a build with no signing identity — the
  /// data-protection keychain rejects every write with `-34018`, and the
  /// file-based one re-prompts for the login password on every access because an
  /// ad-hoc signature cannot be recorded in an item's ACL. Neither degrades
  /// gracefully; both make the feature unusable.
  ///
  /// Once the app is signed with a development certificate, the keychain is the
  /// stronger choice — the OS holds the key rather than a file this process can
  /// read. Opt back in with `--dart-define=DN_VAULT=keychain`. See
  /// [EncryptedFileVaultStore] for what the file backing does and does not
  /// protect.
  static VaultStore _defaultStore() {
    if (kIsWeb) return EncryptedIdbVaultStore();
    return _backing == 'keychain'
        ? KeychainVaultStore()
        : EncryptedFileVaultStore();
  }

  List<AuthProfile>? _cache;

  // ── Profiles (non-secret) ────────────────────────────────────────────────

  /// Saved profiles, ordered by display name. Cached after the first read; every
  /// mutation refreshes the cache.
  Future<List<AuthProfile>> profiles() async {
    final cached = _cache;
    if (cached != null) return cached;

    final raw = await persistent.read(VaultStore.profilesKey);
    if (raw == null || raw.isEmpty) return _cache = const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return _cache = const [];
      final parsed = [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) AuthProfile.fromJson(entry),
      ]..sort((a, b) => a.displayName.compareTo(b.displayName));
      return _cache = parsed;
    } catch (_) {
      // A corrupt index must not take the app down; treat it as empty and let
      // the next save rewrite it.
      return _cache = const [];
    }
  }

  Future<AuthProfile?> profileById(String id) async {
    for (final p in await profiles()) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Create or update [profile], routing [apiKey] to the store its `sessionOnly`
  /// flag selects. Passing a null [apiKey] leaves the existing secret untouched
  /// — so editing a display name never requires re-entering the key.
  ///
  /// Flipping `sessionOnly` migrates the secret: the copy in the store it is
  /// leaving is deleted, so a profile switched to session-only stops having a
  /// persisted key rather than merely ignoring one.
  Future<void> saveProfile(AuthProfile profile, {String? apiKey}) async {
    final previous = await profileById(profile.id);
    final from = _storeFor(previous?.sessionOnly ?? profile.sessionOnly);
    final to = _storeFor(profile.sessionOnly);

    if (apiKey != null && apiKey.isNotEmpty) {
      await to.write(profile.credentialRef, apiKey);
      if (!identical(from, to)) await from.delete(profile.credentialRef);
    } else if (!identical(from, to)) {
      final carried = await from.read(profile.credentialRef);
      if (carried != null) {
        await to.write(profile.credentialRef, carried);
        await from.delete(profile.credentialRef);
      }
    }

    final next = [
      for (final p in await profiles())
        if (p.id != profile.id) p,
      profile,
    ]..sort((a, b) => a.displayName.compareTo(b.displayName));
    await _writeIndex(next);
  }

  /// Remove a profile and both possible copies of its secret.
  Future<void> deleteProfile(String id) async {
    final profile = await profileById(id);
    if (profile == null) return;
    await persistent.delete(profile.credentialRef);
    await session.delete(profile.credentialRef);
    await _writeIndex([
      for (final p in await profiles())
        if (p.id != id) p,
    ]);
  }

  // ── Secrets ──────────────────────────────────────────────────────────────

  /// The plaintext key for [profile], or null when the vault has none — a
  /// session-only profile after a restart, or a profile saved with no key.
  ///
  /// **The one egress point for secret material.** Callers pass the result
  /// straight into a request header and hold no copy; never log it, never put it
  /// in an [AaPayload], never persist it in node params.
  Future<String?> secretFor(AuthProfile profile) =>
      _storeFor(profile.sessionOnly).read(profile.credentialRef);

  /// Whether a key is on file, without reading it — what the UI needs to show
  /// "key saved" and what validation checks before a connection test.
  Future<bool> hasSecret(AuthProfile profile) async =>
      (await secretFor(profile)) != null;

  VaultStore _storeFor(bool sessionOnly) => sessionOnly ? session : persistent;

  Future<void> _writeIndex(List<AuthProfile> profiles) async {
    _cache = profiles;
    await persistent.write(
      VaultStore.profilesKey,
      jsonEncode([for (final p in profiles) p.toJson()]),
    );
  }
}
