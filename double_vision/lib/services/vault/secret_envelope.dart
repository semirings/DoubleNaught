import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM sealing, independent of where the bytes end up.
///
/// Shared by the two encrypt-it-ourselves backings — `EncryptedIdbVaultStore`
/// (IndexedDB, web) and `EncryptedFileVaultStore` (a file, desktop) — so the
/// crypto exists once and both are covered by the same reasoning and the same
/// tests. A store supplies persistence; this supplies the envelope.
class SecretEnvelope {
  final AesGcm _algorithm;

  SecretEnvelope() : _algorithm = AesGcm.with256bits();

  /// A fresh 256-bit key, base64 for storage.
  Future<String> newKeyBase64() async {
    final key = await _algorithm.newSecretKey();
    return base64Encode(await key.extractBytes());
  }

  SecretKey keyFromBase64(String encoded) => SecretKey(base64Decode(encoded));

  /// Seal [value] into a `{cipherText, nonce, mac}` record.
  ///
  /// A fresh nonce per call — GCM's security collapses if a nonce ever repeats
  /// under one key, so this is never derived from the value or a counter.
  Future<Map<String, String>> seal(String value, SecretKey key) async {
    final box = await _algorithm.encrypt(
      utf8.encode(value),
      secretKey: key,
      nonce: _algorithm.newNonce(),
    );
    return {
      'cipherText': base64Encode(box.cipherText),
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  /// Open a record produced by [seal], or null when it fails to authenticate.
  ///
  /// A failed MAC means the record was altered or the key changed. Returning null
  /// rather than throwing keeps one damaged entry from bricking the whole vault —
  /// the caller simply sees a missing secret. A malformed record (missing or
  /// non-base64 fields) is treated the same way.
  Future<String?> open(Map<Object?, Object?> record, SecretKey key) async {
    final cipherText = record['cipherText'];
    final nonce = record['nonce'];
    final mac = record['mac'];
    if (cipherText is! String || nonce is! String || mac is! String) {
      return null;
    }

    try {
      final clear = await _algorithm.decrypt(
        SecretBox(
          base64Decode(cipherText),
          nonce: base64Decode(nonce),
          mac: Mac(base64Decode(mac)),
        ),
        secretKey: key,
      );
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
