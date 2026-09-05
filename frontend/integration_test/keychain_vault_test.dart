import 'package:double_vision/models/auth_profile.dart';
import 'package:double_vision/services/vault/key_vault.dart';
import 'package:double_vision/services/vault/keychain_vault_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Runs against the **real OS keychain** in a real app binary:
///
/// ```sh
/// flutter test integration_test/keychain_vault_test.dart -d macos
/// ```
///
/// The unit suite covers vault logic with a fake store; only this can catch a
/// platform-side failure — the entitlement/keychain-selection class of bug that
/// makes every write throw `PlatformException` with `-34018`
/// errSecMissingEntitlement while the pure-Dart tests stay green.
///
/// Each test cleans up the entries it creates, so a run leaves no residue in the
/// developer's login keychain.
///
/// **Run this by hand, not in CI.** Debug builds are ad-hoc signed, so every
/// rebuild presents a new identity to the login keychain and macOS raises an
/// "allow access" prompt. With a human present that's one click; headless it
/// blocks until the operation times out.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const suffix = 'integration-test';

  group('KeychainVaultStore against the OS keychain', () {
    late KeychainVaultStore store;

    setUp(() => store = KeychainVaultStore());
    tearDown(() async {
      await store.delete('probe-$suffix');
      await store.delete('credential:$suffix');
    });

    testWidgets('write → read → delete round-trips', (_) async {
      await store.write('probe-$suffix', 'value-under-test');
      expect(await store.read('probe-$suffix'), 'value-under-test');

      await store.delete('probe-$suffix');
      expect(await store.read('probe-$suffix'), isNull);
    });

    testWidgets('overwriting replaces rather than appending', (_) async {
      await store.write('probe-$suffix', 'first');
      await store.write('probe-$suffix', 'second');
      expect(await store.read('probe-$suffix'), 'second');
    });

    testWidgets('a full profile save persists through the vault', (_) async {
      final vault = KeyVault(persistent: store);
      final profile = AuthProfile(
        id: suffix,
        displayName: 'Integration Probe',
        provider: AuthProvider.anthropic,
        baseUrl: AuthProvider.anthropic.baseUrl,
        credentialRef: AuthProfile.refFor(suffix),
        maxContextTokens: 1000,
      );

      // The call that failed with PlatformException before the
      // usesDataProtectionKeychain fix.
      await vault.saveProfile(profile, apiKey: 'sk-integration-probe');

      expect(await vault.secretFor(profile), 'sk-integration-probe');
      expect(
        (await vault.profiles()).map((p) => p.id),
        contains(suffix),
      );

      await vault.deleteProfile(suffix);
      expect(await vault.secretFor(profile), isNull);
    });
  });
}
