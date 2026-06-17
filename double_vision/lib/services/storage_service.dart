import 'dart:convert';
import 'dart:io';

/// Local JSON-file persistence for the DoubleNaught front-end.
///
/// This is a development stub: each record is a JSON file under `../storage/`
/// (relative to the process working directory, i.e. the repo's `storage/`
/// folder sitting alongside `double_vision/`). It exists so features can read
/// and write state before a real backend is available.
///
/// TODO: swap for backend API. Replace the dart:io file reads/writes with HTTP
/// calls to the DoubleNaught service layer (double_down / double_mind, etc.).
/// The method signatures are intended to survive that swap — only the bodies
/// should change. Note dart:io makes this stub unavailable on Flutter web.
class StorageService {
  /// Directory where JSON records live. Defaults to `../storage/` relative to
  /// the current working directory.
  final Directory baseDir;

  StorageService({String path = '../storage'})
      : baseDir = Directory(path);

  /// Resolve a record key to its backing file (`<baseDir>/<key>.json`).
  File _fileFor(String key) => File('${baseDir.path}/$key.json');

  /// Ensure the storage directory exists before a write.
  Future<void> _ensureDir() async {
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
  }

  /// Read and decode the JSON record stored under [key], or `null` if absent.
  ///
  /// TODO: swap for backend API — becomes `GET /records/{key}`.
  Future<Map<String, dynamic>?> read(String key) async {
    final file = _fileFor(key);
    if (!await file.exists()) return null;
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) return null;
    return jsonDecode(contents) as Map<String, dynamic>;
  }

  /// Encode and write [value] as the JSON record under [key].
  ///
  /// TODO: swap for backend API — becomes `PUT /records/{key}`.
  Future<void> write(String key, Map<String, dynamic> value) async {
    await _ensureDir();
    final file = _fileFor(key);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(value));
  }

  /// Delete the record stored under [key]; returns true if a file was removed.
  ///
  /// TODO: swap for backend API — becomes `DELETE /records/{key}`.
  Future<bool> delete(String key) async {
    final file = _fileFor(key);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }

  /// List the keys of all stored records (filenames without the `.json` suffix).
  ///
  /// TODO: swap for backend API — becomes `GET /records`.
  Future<List<String>> keys() async {
    if (!await baseDir.exists()) return const [];
    final keys = <String>[];
    await for (final entity in baseDir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final name = entity.uri.pathSegments.last;
        keys.add(name.substring(0, name.length - '.json'.length));
      }
    }
    return keys;
  }
}
