import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../models/auth_profile.dart';
import '../services/vault/key_vault.dart';
import '../services/vault/provider_ping.dart';

/// The Secure Settings node's configuration drawer, mounted in the right-hand
/// inspection canvas (see `DESIGN.md` → "Secure Settings node").
///
/// Edits a working copy and commits only on **Save Profile**, so an abandoned
/// edit leaves the vault untouched. The API key field is write-only in spirit:
/// an existing key is never read back into it — the field shows whether one is
/// on file and typing replaces it. That way a saved key has no path back onto
/// the screen, and "leave blank to keep" is a real guarantee rather than a hint.
class KeyVaultDrawer extends StatefulWidget {
  final KeyVault vault;

  /// Profile being edited; null creates a new one.
  final AuthProfile? profile;

  /// Called after a successful save with the committed profile — the node uses
  /// this to refresh its dropdown and broadcast `authOutput`.
  final void Function(AuthProfile saved)? onSaved;

  final void Function(String id)? onDeleted;

  final ProviderPing ping;

  const KeyVaultDrawer({
    super.key,
    required this.vault,
    this.profile,
    this.onSaved,
    this.onDeleted,
    this.ping = const ProviderPing(),
  });

  @override
  State<KeyVaultDrawer> createState() => _KeyVaultDrawerState();
}

class _KeyVaultDrawerState extends State<KeyVaultDrawer> {
  late TextEditingController _name;
  late TextEditingController _baseUrl;
  late TextEditingController _apiKey;
  late TextEditingController _maxTokens;

  late AuthProvider _provider;
  late bool _sessionOnly;

  bool _obscure = true;
  bool _busy = false;
  bool _hasStoredKey = false;
  PingResult? _ping;
  String? _error;

  bool get _isNew => widget.profile == null;

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  @override
  void didUpdateWidget(KeyVaultDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The panel is reused when the node switches profiles — rebuild the working
    // copy rather than leaving the previous profile's values on screen.
    if (oldWidget.profile?.id != widget.profile?.id) {
      _disposeControllers();
      _hydrate();
    }
  }

  void _hydrate() {
    final p = widget.profile;
    _provider = p?.provider ?? AuthProvider.anthropic;
    _sessionOnly = p?.sessionOnly ?? false;
    _name = TextEditingController(text: p?.displayName ?? '');
    _baseUrl = TextEditingController(text: p?.baseUrl ?? _provider.baseUrl);
    _maxTokens = TextEditingController(
      text: '${p?.maxContextTokens ?? _provider.defaultMaxContextTokens}',
    );
    _apiKey = TextEditingController();
    _ping = null;
    _error = null;
    _hasStoredKey = false;
    if (p != null) {
      widget.vault.hasSecret(p).then((has) {
        if (mounted) setState(() => _hasStoredKey = has);
      });
    }
  }

  void _disposeControllers() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _maxTokens.dispose();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  /// Switching provider re-fills the vendor defaults, but only where the user
  /// hasn't already typed something of their own.
  void _onProvider(AuthProvider next) {
    setState(() {
      final wasDefaultUrl = _baseUrl.text.trim().isEmpty ||
          _baseUrl.text.trim() == _provider.baseUrl;
      final wasDefaultTokens =
          _maxTokens.text.trim() == '${_provider.defaultMaxContextTokens}';
      _provider = next;
      if (wasDefaultUrl) _baseUrl.text = next.baseUrl;
      if (wasDefaultTokens) {
        _maxTokens.text = '${next.defaultMaxContextTokens}';
      }
      _ping = null;
    });
  }

  /// The profile as currently edited. Not persisted until [_save].
  AuthProfile _draft() {
    final id = widget.profile?.id ?? _newId();
    return AuthProfile(
      id: id,
      displayName: _name.text.trim(),
      provider: _provider,
      baseUrl: _baseUrl.text.trim(),
      credentialRef: widget.profile?.credentialRef ?? AuthProfile.refFor(id),
      maxContextTokens: int.tryParse(_maxTokens.text.trim()) ??
          _provider.defaultMaxContextTokens,
      sessionOnly: _sessionOnly,
    );
  }

  /// Time-ordered id with a random-ish tail. Avoids a uuid dependency for what
  /// only has to be unique within one vault.
  static String _newId() {
    final now = DateTime.now();
    return 'profile-${now.microsecondsSinceEpoch.toRadixString(36)}'
        '-${now.hashCode.toRadixString(36)}';
  }

  String? _validate() {
    if (_name.text.trim().isEmpty) return 'Display Name is required';
    if (_baseUrl.text.trim().isEmpty) return 'Base URL is required';
    final tokens = int.tryParse(_maxTokens.text.trim());
    if (tokens == null || tokens <= 0) {
      return 'Max Context Tokens must be a positive number';
    }
    final needsKey = _provider != AuthProvider.ollamaLocal;
    if (needsKey && _isNew && _apiKey.text.isEmpty) {
      return 'API Key is required for ${_provider.label}';
    }
    return null;
  }

  Future<void> _testConnection() async {
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ping = null;
    });
    final draft = _draft();
    // Prefer the typed key so a test validates what is about to be saved; fall
    // back to the stored one when the field is blank on an existing profile.
    final key = _apiKey.text.isNotEmpty
        ? _apiKey.text
        : (widget.profile == null
            ? null
            : await widget.vault.secretFor(widget.profile!));
    final result = await widget.ping.test(draft, key);
    if (mounted) {
      setState(() {
        _ping = result;
        _busy = false;
      });
    }
  }

  Future<void> _save() async {
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final draft = _draft();
    try {
      await widget.vault.saveProfile(
        draft,
        apiKey: _apiKey.text.isEmpty ? null : _apiKey.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _hasStoredKey = true;
        // Clear the field on success — the key is in the vault now and this
        // widget should stop holding a copy.
        _apiKey.clear();
      });
      widget.onSaved?.call(draft);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save to the vault — ${_storeError(e)}';
        });
      }
    }
  }

  /// A diagnosable one-liner for a storage failure.
  ///
  /// Takes a [PlatformException]'s `code` and `message` but never its `details`:
  /// code and message are the OS's own status text (`-34018`, "Unexpected
  /// security result code"), whereas details can echo the arguments of the
  /// failed call — which for a write is the secret.
  String _storeError(Object e) {
    if (e is PlatformException) {
      final code = e.code;
      final message = e.message;
      return message == null || message.isEmpty
          ? 'platform error $code'
          : 'platform error $code · $message';
    }
    return e.runtimeType.toString();
  }

  Future<void> _delete() async {
    final p = widget.profile;
    if (p == null) return;
    setState(() => _busy = true);
    await widget.vault.deleteProfile(p.id);
    if (mounted) setState(() => _busy = false);
    widget.onDeleted?.call(p.id);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _field(
          controller: _name,
          label: 'Display Name',
          hint: 'Work Gemini Pro',
        ),
        const SizedBox(height: 12),
        DropdownMenu<AuthProvider>(
          enableSearch: false,
          expandedInsets: EdgeInsets.zero,
          label: const Text('Provider Type'),
          initialSelection: _provider,
          onSelected: (p) {
            if (p != null) _onProvider(p);
          },
          dropdownMenuEntries: [
            for (final p in AuthProvider.values)
              DropdownMenuEntry(value: p, label: p.label),
          ],
        ),
        const SizedBox(height: 12),
        _field(
          controller: _baseUrl,
          label: 'Base URL',
          hint: _provider.baseUrl,
        ),
        const SizedBox(height: 12),
        _apiKeyField(theme, scheme),
        const SizedBox(height: 12),
        _field(
          controller: _maxTokens,
          label: 'Max Context Tokens',
          hint: '${_provider.defaultMaxContextTokens}',
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          value: _sessionOnly,
          onChanged: _busy
              ? null
              : (v) => setState(() => _sessionOnly = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: const Text('Session Storage Only'),
          subtitle: Text(
            'Keep the key in memory for this run — nothing is written to '
            '${_persistentLabel()}.',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _testConnection,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering, size: 16),
                label: const Text('Test Connection'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.lock_outline, size: 16),
                label: const Text('Save Profile'),
              ),
            ),
          ],
        ),
        if (!_isNew) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete profile'),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
        ],
        if (_ping != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _ping!.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 16,
                color: _ping!.ok ? Colors.green : scheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _ping!.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _ping!.ok ? Colors.green : scheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _persistentLabel() =>
      'the OS keychain or the encrypted browser vault';

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboardType,
  }) =>
      TextField(
        controller: controller,
        enabled: !_busy,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      );

  Widget _apiKeyField(ThemeData theme, ColorScheme scheme) => TextField(
        controller: _apiKey,
        enabled: !_busy,
        obscureText: _obscure,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: 'API Key',
          hintText: _hasStoredKey
              ? 'A key is on file — type to replace it'
              : 'Paste the provider API key',
          helperText: _hasStoredKey
              ? 'Leave blank to keep the stored key'
              : (_provider == AuthProvider.ollamaLocal
                  ? 'Optional for a local Ollama daemon'
                  : null),
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              size: 18,
            ),
            tooltip: _obscure ? 'Show key' : 'Hide key',
          ),
        ),
      );
}
