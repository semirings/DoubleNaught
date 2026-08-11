import 'dart:convert';
import 'dart:io';

import 'package:double_vision/models/auth_profile.dart';
import 'package:double_vision/services/vault/encrypted_file_vault_store.dart';
import 'package:double_vision/services/vault/key_vault.dart';
import 'package:double_vision/services/vault/secret_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  EncryptedFileVaultStore store() =>
      EncryptedFileVaultStore(directory: () async => temp);

  setUp(() => temp = Directory.systemTemp.createTempSync('dn_vault_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  File secretsFile() => File('${temp.path}/secrets.json');

  group('EncryptedFileVaultStore', () {
    test('round-trips a value', () async {
      final s = store();
      await s.write('credential:p1', 'sk-file-secret');
      expect(await s.read('credential:p1'), 'sk-file-secret');
      expect(await s.read('nope'), isNull);
    });

    test('what lands on disk is ciphertext, not the secret', () async {
      await store().write('credential:p1', 'sk-super-secret');

      final raw = secretsFile().readAsStringSync();
      expect(raw.contains('sk-super-secret'), isFalse);

      final record = (jsonDecode(raw) as Map)['credential:p1'] as Map;
      expect(record.keys, containsAll(['cipherText', 'nonce', 'mac']));
    });

    test('a second instance reads what the first wrote', () async {
      // The cross-restart case: the key file has to be reused, not regenerated.
      await store().write('credential:p1', 'sk-persisted');
      expect(await store().read('credential:p1'), 'sk-persisted');
    });

    test('each write uses a fresh nonce', () async {
      final s = store();
      await s.write('k', 'same-value');
      final first = _nonceOf(secretsFile(), 'k');
      await s.write('k', 'same-value');
      expect(_nonceOf(secretsFile(), 'k'), isNot(first));
    });

    test('a tampered record fails closed', () async {
      await store().write('credential:p1', 'sk-original');

      final json = jsonDecode(secretsFile().readAsStringSync()) as Map;
      final record = json['credential:p1'] as Map;
      record['cipherText'] = base64Encode(
        base64Decode(record['cipherText'] as String)..[0] ^= 0xFF,
      );
      secretsFile().writeAsStringSync(jsonEncode(json));

      // A fresh instance, i.e. the next run: the live one caches its records, so
      // an edit made behind its back is only seen after a reload.
      expect(await store().read('credential:p1'), isNull);
    });

    test('a wrong key cannot open existing records', () async {
      await store().write('credential:p1', 'sk-original');
      // Simulate the key file being replaced (a restored backup, say).
      File('${temp.path}/data_key')
          .writeAsStringSync(await SecretEnvelope().newKeyBase64());
      expect(await store().read('credential:p1'), isNull);
    });

    test('delete removes just that entry', () async {
      final s = store();
      await s.write('a', '1');
      await s.write('b', '2');

      await s.delete('a');
      expect(await s.read('a'), isNull);
      expect(await s.read('b'), '2');
      // Deleting something absent is a no-op, not an error.
      await s.delete('missing');
    });

    test('a corrupt secrets file degrades to empty instead of throwing',
        () async {
      final s = store();
      await s.write('a', '1');
      secretsFile().writeAsStringSync('{ truncated');

      expect(await EncryptedFileVaultStore(directory: () async => temp)
          .read('a'), isNull);
      // And a subsequent write repairs the file.
      await EncryptedFileVaultStore(directory: () async => temp)
          .write('b', '2');
      expect(await EncryptedFileVaultStore(directory: () async => temp)
          .read('b'), '2');
    });

    test('the key file is not world-readable', () async {
      await store().write('a', '1');
      final mode = File('${temp.path}/data_key').statSync().mode;
      // Owner-only: no group or other bits.
      expect(mode & 0x3F, 0, reason: 'expected 600, got ${mode.toRadixString(8)}');
    });
  });

  group('KeyVault over the file backing', () {
    test('a full profile save round-trips, key kept out of the index', () async {
      final vault = KeyVault(persistent: store());
      final profile = AuthProfile(
        id: 'p1',
        displayName: 'Gemini',
        provider: AuthProvider.googleGemini,
        baseUrl: AuthProvider.googleGemini.baseUrl,
        credentialRef: AuthProfile.refFor('p1'),
        maxContextTokens: 1000,
      );

      await vault.saveProfile(profile, apiKey: 'sk-vaulted');

      expect(await vault.secretFor(profile), 'sk-vaulted');
      expect((await vault.profiles()).single.displayName, 'Gemini');
      // Neither the plaintext key nor the profile JSON leaks into the file.
      expect(secretsFile().readAsStringSync().contains('sk-vaulted'), isFalse);
      expect(secretsFile().readAsStringSync().contains('Gemini'), isFalse);
    });

    test('desktop defaults to the file backing, not the keychain', () {
      // The keychain is unusable without a signing identity, so it is opt-in.
      expect(KeyVault.usesKeychain, isFalse);
    });
  });
}

String _nonceOf(File file, String key) =>
    ((jsonDecode(file.readAsStringSync()) as Map)[key] as Map)['nonce']
        as String;
