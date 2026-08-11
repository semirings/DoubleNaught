import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../models/auth_profile.dart';
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

  KeyVault({VaultStore? persistent, SessionVaultStore? session})
      : persistent = persistent ??
            (kIsWeb ? EncryptedIdbVaultStore() : KeychainVaultStore()),
        session = session ?? SessionVaultStore();

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
