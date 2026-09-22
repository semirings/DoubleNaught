import 'package:aa_preview_table/aa_preview_table.dart';
import 'package:double_vision/models/auth_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuthProfile.fromAa', () {
    test('round-trips through toAa', () {
      const profile = AuthProfile(
        id: 'p1',
        displayName: 'Work Gemini',
        provider: AuthProvider.googleGemini,
        baseUrl: 'https://generativelanguage.googleapis.com',
        credentialRef: 'credential:p1',
        maxContextTokens: 1048576,
      );

      final restored = AuthProfile.fromAa(profile.toAa());

      expect(restored, isNotNull);
      expect(restored!.id, 'p1');
      expect(restored.displayName, 'Work Gemini');
      expect(restored.provider, AuthProvider.googleGemini);
      expect(restored.baseUrl, 'https://generativelanguage.googleapis.com');
      expect(restored.credentialRef, 'credential:p1');
      expect(restored.maxContextTokens, 1048576);
    });

    test('an empty AA (nothing connected) is null', () {
      expect(AuthProfile.fromAa(const AaPayload()), isNull);
    });
  });
}
