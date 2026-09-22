import 'package:aa_preview_table/aa_preview_table.dart';

/// A credential provider the vault can hold a profile for.
///
/// [baseUrl] is the vendor default, pre-filled when a profile is created; the
/// user may override it (self-hosted gateways, proxies, an alternate Ollama
/// port). [defaultMaxContextTokens] is a starting value for the profile field,
/// not a hard limit — downstream nodes read the profile's own value.
enum AuthProvider {
  googleGemini(
    label: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com',
    defaultMaxContextTokens: 1048576,
  ),
  anthropic(
    label: 'Anthropic',
    baseUrl: 'https://api.anthropic.com',
    defaultMaxContextTokens: 1000000,
  ),
  openAiCompatible(
    label: 'OpenAI/Compatible',
    baseUrl: 'https://api.openai.com',
    defaultMaxContextTokens: 128000,
  ),
  ollamaLocal(
    label: 'Ollama Local',
    baseUrl: 'http://localhost:11434',
    defaultMaxContextTokens: 32768,
  );

  const AuthProvider({
    required this.label,
    required this.baseUrl,
    required this.defaultMaxContextTokens,
  });

  /// Human-readable name shown in the provider dropdown.
  final String label;

  /// Vendor default endpoint, pre-filled on profile creation.
  final String baseUrl;

  /// Starting value for a new profile's `maxContextTokens`.
  final int defaultMaxContextTokens;

  static AuthProvider byName(String? name) => AuthProvider.values.firstWhere(
        (p) => p.name == name,
        orElse: () => AuthProvider.openAiCompatible,
      );
}

/// A credential profile's **non-secret** half — see `DESIGN.md` → "Secure
/// Settings node".
///
/// This is the only part that is ever serialized into a workflow, emitted on
/// `authOutput`, or returned by a list call. The API key lives in the vault
/// under [credentialRef] and is never a field on this class: there is no
/// property here that could carry it, so no serializer, `toString`, or log
/// statement can leak one.
class AuthProfile {
  /// Stable UUID-ish identifier; also the AA row key.
  final String id;

  final String displayName;
  final AuthProvider provider;
  final String baseUrl;

  /// Vault lookup key for this profile's secret — an opaque handle, never the
  /// secret itself.
  final String credentialRef;

  final int maxContextTokens;

  /// When true the secret lives in RAM only and dies with the process.
  final bool sessionOnly;

  const AuthProfile({
    required this.id,
    required this.displayName,
    required this.provider,
    required this.baseUrl,
    required this.credentialRef,
    required this.maxContextTokens,
    this.sessionOnly = false,
  });

  /// The canonical credential-ref format: derived from [id] so a profile's
  /// secret is addressable without consulting anything else.
  static String refFor(String id) => 'credential:$id';

  AuthProfile copyWith({
    String? displayName,
    AuthProvider? provider,
    String? baseUrl,
    int? maxContextTokens,
    bool? sessionOnly,
  }) =>
      AuthProfile(
        id: id,
        displayName: displayName ?? this.displayName,
        provider: provider ?? this.provider,
        baseUrl: baseUrl ?? this.baseUrl,
        credentialRef: credentialRef,
        maxContextTokens: maxContextTokens ?? this.maxContextTokens,
        sessionOnly: sessionOnly ?? this.sessionOnly,
      );

  factory AuthProfile.fromJson(Map<String, dynamic> json) => AuthProfile(
        id: json['id'] as String,
        displayName: json['displayName'] as String? ?? '',
        provider: AuthProvider.byName(json['provider'] as String?),
        baseUrl: json['baseUrl'] as String? ?? '',
        credentialRef:
            json['credentialRef'] as String? ?? refFor(json['id'] as String),
        maxContextTokens: (json['maxContextTokens'] as num?)?.toInt() ?? 0,
        sessionOnly: json['sessionOnly'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'provider': provider.name,
        'baseUrl': baseUrl,
        'credentialRef': credentialRef,
        'maxContextTokens': maxContextTokens,
        'sessionOnly': sessionOnly,
      };

  /// Reconstructs a profile from an `authOutput`-shaped [aa] (see [toAa]).
  ///
  /// Returns null when [aa] doesn't look like a profile at all (no rows —
  /// nothing connected yet, or the wire went cold). A malformed-but-present
  /// payload still parses as best it can, mirroring [fromJson]'s tolerance,
  /// since the only real producer of this shape is [SecureSettingsNode]
  /// itself and a partial parse is more useful than a hard failure here.
  static AuthProfile? fromAa(AaPayload aa) {
    if (aa.rows.isEmpty) return null;
    final id = aa.rows.first;
    return AuthProfile(
      id: id,
      displayName: aa.value('displayName') ?? '',
      provider: AuthProvider.byName(aa.value('provider')),
      baseUrl: aa.value('baseUrl') ?? '',
      credentialRef: aa.value('credentialRef') ?? refFor(id),
      maxContextTokens: aa.intValue('maxContextTokens') ?? 0,
    );
  }

  /// This profile as the `authOutput` payload: one row (the profile id) by five
  /// metadata columns. `credentialRef` travels as a *handle* — a downstream node
  /// redeems it against the vault, so the key itself never enters the graph.
  AaPayload toAa() => AaPayload(
        rows: List.filled(5, id),
        cols: const [
          'displayName',
          'provider',
          'baseUrl',
          'credentialRef',
          'maxContextTokens',
        ],
        vals: [
          displayName,
          provider.name,
          baseUrl,
          credentialRef,
          maxContextTokens,
        ],
      );
}
