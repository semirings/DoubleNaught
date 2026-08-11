import 'package:idb_shim/idb_browser.dart';

/// The browser's real IndexedDB. `idbFactoryBrowser` falls back to an in-memory
/// factory when the platform has no IndexedDB, so a private-mode browser
/// degrades to session-only storage rather than throwing.
IdbFactory get platformIdbFactory => idbFactoryBrowser;
