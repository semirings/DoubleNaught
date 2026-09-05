import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:vyuh_core/plugin/plugin_descriptor.dart';
import 'package:vyuh_core/vyuh_core.dart' as vc;
import 'package:vyuh_extension_content/vyuh_extension_content.dart';
import 'package:vyuh_feature_system/vyuh_feature_system.dart' as system;
import 'package:vyuh_plugin_content_provider_sanity/vyuh_plugin_content_provider_sanity.dart';

import 'config/root_feature.dart';
import 'config/sanity_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Local .env file not found or empty. Falling back to system environment variables.");
  }

  vc.runApp(
    // Land on the workflow editor; the Vyuh-status home stays at '/'.
    initialLocation: '/nodes',
    plugins: _getPlugins(),
    features: () => [
      // Core Vyuh feature required by every app: renders content items and
      // routes, handles actions, conditions and layouts.
      system.feature,

      // DoubleNaught features. Content nodes are added here as designs land.
      rootFeature,
    ],
    // Force a dark theme by wrapping Vyuh's router in our own MaterialApp.
    platformWidgetBuilder: vc.PlatformWidgetBuilder.system.copyWith(
      appBuilder: (_, platform) => MaterialApp.router(
        title: 'DoubleNaught',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFA17FFF),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        routerConfig: platform.router.instance,
      ),
    ),
  );
}

PluginDescriptor _getPlugins() {
  // WidgetsFlutterBinding.ensureInitialized() has been moved to main()
  // before dotenv.load() for order safety.


  // Keep imperatively navigated URLs reflected in the address bar on web.
  vc.DefaultNavigationPlugin.enableURLReflectsImperativeAPIs();
  vc.DefaultNavigationPlugin.usePathStrategy();

  return PluginDescriptor(
    content: DefaultContentPlugin(
      useLiveRoute: true,
      allowRouteRefresh: true,
      // The Sanity provider is always wired in; until a project id is supplied
      // via --dart-define it simply has nothing to fetch and the app falls back
      // to the local routes registered by [rootFeature].
      provider: SanityContentProvider.withConfig(
        config: DoubleVisionSanity.config,
        cacheDuration: const Duration(seconds: 5),
      ),
    ),
    env: vc.DefaultEnvPlugin(),
  );
}
