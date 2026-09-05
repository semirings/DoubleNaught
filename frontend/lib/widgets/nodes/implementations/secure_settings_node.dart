import 'package:flutter/material.dart';

import '../../../models/auth_profile.dart';
import '../../../models/workflow.dart';
import '../../../services/infobus/output_port.dart';
import '../../../services/vault/key_vault.dart';
import '../../focus_panel.dart' show FocusContent;
import '../../key_vault_drawer.dart';
import '../base/base_node_widget.dart';
import '../base/output_connector.dart';

/// The credential source for the graph — see `DESIGN.md` → "Secure Settings
/// node".
///
/// Holds named provider profiles and emits the **selected profile's metadata**
/// on `authOutput` as a 1×5 AA. The API key is never part of that payload, of
/// this widget's state, or of the node's saved params: it lives in the vault
/// (OS keychain, or AES-GCM in IndexedDB on web) and downstream consumers redeem
/// the `credentialRef` handle against [KeyVault.secretFor] at request time.
///
/// What *is* persisted in node params is `selectedProfileId` — a pointer, so
/// reopening a workflow restores the selection without the workflow file ever
/// having held a credential.
class SecureSettingsNode extends BaseNodeWidget {
  /// Pushes the [KeyVaultDrawer] into the right-hand inspection canvas.
  final void Function(int nodeId, FocusContent content)? onContent;

  /// Opens (and selects) this node's tab.
  final void Function(int nodeId)? onView;

  /// Injected in tests; defaults to the platform vault.
  final KeyVault? vault;

  const SecureSettingsNode({
    super.key,
    required super.node,
    super.initialParams,
    super.onParams,
    super.onOutputPort,
    super.connectedOutputs,
    this.onContent,
    this.onView,
    this.vault,
  });

  @override
  State<SecureSettingsNode> createState() => _SecureSettingsNodeState();
}

/// Validation state of the selected profile, driving the header dot.
enum _Health { unknown, validated, error }

class _SecureSettingsNodeState extends BaseNodeState<SecureSettingsNode> {
  @override String   get nodeTitle => 'Secure Settings';
  @override IconData get nodeIcon  => Icons.key_outlined;
  @override double   get nodeWidth => 300;

  late final KeyVault _vault;
  final OutputPort _out = OutputPort('authOutput');

  List<AuthProfile> _profiles = const [];
  AuthProfile? _selected;
  _Health _health = _Health.unknown;
  String? _detail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _vault = widget.vault ?? KeyVault();
    initOutputPort(_out);
    _load(select: widget.initialParams?['selectedProfileId']);
  }

  @override
  void dispose() {
    _out.dispose();
    super.dispose();
  }

  Future<void> _load({String? select}) async {
    final profiles = await _vault.profiles();
    if (!mounted) return;
    AuthProfile? chosen;
    final targetId = select ?? _selected?.id;
    if (targetId != null) {
      chosen = profiles.firstWhere(
        (p) => p.id == targetId,
        orElse: () => _missing,
      );
    }
    setState(() {
      _profiles = profiles;
      _selected = chosen == null || identical(chosen, _missing) ? null : chosen;
      _loading = false;
    });
    if (_selected != null) await _refreshHealth();
  }

  /// Sentinel for "no profile" — `firstWhere` needs a non-null fallback.
  static const AuthProfile _missing = AuthProfile(
    id: '',
    displayName: '',
    provider: AuthProvider.anthropic,
    baseUrl: '',
    credentialRef: '',
    maxContextTokens: 0,
  );

  /// Green requires a key actually on file. A profile whose secret is gone —
  /// session-only after a restart, or one saved without a key — reads red, since
  /// emitting it would hand downstream nodes an unredeemable ref.
  Future<void> _refreshHealth() async {
    final p = _selected;
    if (p == null) return;
    final hasKey = await _vault.hasSecret(p);
    if (!mounted) return;
    setState(() {
      if (hasKey) {
        _health = _Health.validated;
        _detail = p.provider.label;
      } else {
        _health = _Health.error;
        _detail = p.sessionOnly
            ? 'session key not loaded — re-enter it'
            : 'no key on file';
      }
    });
  }

  Future<void> _select(AuthProfile profile) async {
    setState(() => _selected = profile);
    saveParams({'selectedProfileId': profile.id});
    await _refreshHealth();
    _emit();
    _republishDrawer();
  }

  /// Publish the selected profile's metadata. Emitting is gated on a live key:
  /// a downstream node that receives a `credentialRef` should be able to redeem
  /// it, so a broken profile stays off the wire.
  void _emit() {
    final p = _selected;
    if (p == null || _health != _Health.validated) return;
    _out.emit(p.toAa());
  }

  void _openDrawer({AuthProfile? profile, bool create = false}) {
    _republishDrawer(profile: profile, create: create);
    widget.onView?.call(widget.node.id);
  }

  bool _drawerMounted = false;
  AuthProfile? _drawerProfile;
  bool _drawerCreating = false;

  /// (Re)build this node's drawer tab. No-op until the drawer has been opened
  /// once, so a state change never throws the panel open unbidden.
  void _republishDrawer({AuthProfile? profile, bool? create}) {
    if (create != null) {
      _drawerCreating = create;
      _drawerProfile = create ? null : (profile ?? _selected);
    } else if (!_drawerMounted) {
      return;
    } else if (!_drawerCreating) {
      _drawerProfile = profile ?? _selected;
    }
    _drawerMounted = true;

    widget.onContent?.call(
      widget.node.id,
      FocusContent.panel(
        KeyVaultDrawer(
          vault: _vault,
          profile: _drawerProfile,
          onSaved: (saved) async {
            _drawerCreating = false;
            await _load(select: saved.id);
            _emit();
            _republishDrawer(profile: saved);
          },
          onDeleted: (id) async {
            _drawerCreating = false;
            if (_selected?.id == id) {
              setState(() {
                _selected = null;
                _health = _Health.unknown;
                _detail = null;
              });
            }
            await _load();
            _republishDrawer();
          },
        ),
        subtitle: _drawerCreating
            ? 'New profile'
            : (_drawerProfile?.displayName ?? 'Key Vault'),
      ),
    );
  }

  // ── Build overrides ──────────────────────────────────────────────────────

  @override
  List<Widget> buildOutputConnectors(BuildContext context) => [
        OutputConnector(
          label: 'authOutput',
          idx: 0,
          active: _health == _Health.validated ||
              widget.connectedOutputs.contains(0),
          dragData: PortRef(nodeId: widget.node.id, idx: 0),
        ),
      ];

  @override
  Widget buildNodeBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: BaseNodeState.portLaneClearance(1)),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: switch (_health) {
                  _Health.validated => Colors.green,
                  _Health.error => scheme.error,
                  _Health.unknown => scheme.outline,
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _statusText(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: _health == _Health.error
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_profiles.isEmpty)
          Text(
            _loading ? 'Opening vault…' : 'No profiles yet',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          )
        else
          DropdownMenu<AuthProfile>(
            enableSearch: false,
            expandedInsets: EdgeInsets.zero,
            label: const Text('Select Credential'),
            initialSelection: _selected,
            onSelected: (p) {
              if (p != null) _select(p);
            },
            dropdownMenuEntries: [
              for (final p in _profiles)
                DropdownMenuEntry(
                  value: p,
                  label: p.displayName.isEmpty ? p.id : p.displayName,
                  trailingIcon: p.sessionOnly
                      ? Icon(Icons.timelapse, size: 14, color: scheme.outline)
                      : null,
                ),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _openDrawer(create: true),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _selected == null
                    ? null
                    : () => _openDrawer(profile: _selected),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Edit'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _statusText() {
    if (_loading) return 'reading vault…';
    final p = _selected;
    if (p == null) return 'no profile selected';
    final detail = _detail;
    return detail == null ? p.displayName : '${p.displayName} · $detail';
  }
}
