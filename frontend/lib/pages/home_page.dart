import 'package:flutter/material.dart';

import '../config/sanity_config.dart';

/// Placeholder landing page served from a local route.
///
/// This exists so the app is runnable before any CMS content nodes are
/// authored. Once designs are complete, content will be driven by Vyuh
/// content items rendered from Sanity, and this route can be removed or
/// replaced by a CMS-backed route.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = DoubleVisionSanity.isConfigured;

    return Scaffold(
      appBar: AppBar(title: const Text('DoubleNaught — double_vision')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.visibility_outlined,
                  size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Vyuh framework wired in.',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                configured
                    ? 'Sanity configured (${DoubleVisionSanity.projectId}/'
                        '${DoubleVisionSanity.dataset}). '
                        'Awaiting content nodes.'
                    : 'No Sanity project configured. Pass '
                        '--dart-define=SANITY_PROJECT_ID=… to drive content '
                        'from the CMS. Awaiting designs.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
