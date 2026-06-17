import 'package:go_router/go_router.dart';
import 'package:vyuh_core/vyuh_core.dart';

import '../pages/home_page.dart';
import '../pages/workflow_page.dart';

/// The application's root feature.
///
/// For now it registers a single local route (`/`) so the app is runnable
/// before any CMS-driven content exists. As designs are completed, content
/// nodes (content items, layouts, actions, conditions) will be registered
/// here via `extensions: () => [ContentExtensionDescriptor(...)]`.
final rootFeature = FeatureDescriptor(
  name: 'root',
  title: 'Root',
  description: 'DoubleNaught root feature — local routes and, soon, '
      'CMS-driven content nodes.',
  routes: () => [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/nodes',
      builder: (context, state) => const WorkflowPage(),
    ),
  ],
);
