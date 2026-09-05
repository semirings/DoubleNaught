import 'package:idb_shim/idb_client_memory.dart';
import 'package:idb_shim/idb_shim.dart';

/// Non-web builds have no IndexedDB. They never reach the encrypted store —
/// [KeyVault] selects the keychain backing off-web — so this exists only to keep
/// the file tree compiling (and unit-testable) on the VM.
IdbFactory get platformIdbFactory => idbFactoryMemory;
