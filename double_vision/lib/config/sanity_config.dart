import 'package:sanity_client/sanity_client.dart';

/// Sanity / CMS configuration for the DoubleNaught front-end.
///
/// Values are supplied at build/run time via `--dart-define` so that no
/// project id or token is committed to source control, e.g.:
///
/// ```
/// flutter run \
///   --dart-define=SANITY_PROJECT_ID=xxxx \
///   --dart-define=SANITY_DATASET=production \
///   --dart-define=SANITY_TOKEN=skxxxx
/// ```
class DoubleVisionSanity {
  static const projectId = String.fromEnvironment('SANITY_PROJECT_ID');
  static const dataset =
      String.fromEnvironment('SANITY_DATASET', defaultValue: 'production');
  static const token = String.fromEnvironment('SANITY_TOKEN');

  /// True once a Sanity project id has been provided. Until then the app runs
  /// against local routes only (see [rootFeature]).
  static bool get isConfigured => projectId.isNotEmpty;

  /// Builds a [SanityConfig]. When a token is supplied we read drafts directly
  /// from the API (live editing); without one we fall back to published content
  /// over the CDN, which needs no token. This keeps the app bootable before any
  /// credentials are wired in.
  static SanityConfig get config {
    final hasToken = token.trim().isNotEmpty;
    return SanityConfig(
      projectId: projectId.isEmpty ? 'unconfigured' : projectId,
      dataset: dataset,
      perspective: hasToken ? Perspective.drafts : Perspective.published,
      useCdn: !hasToken,
      token: hasToken ? token : null,
    );
  }
}
