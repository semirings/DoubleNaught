---
name: DoubleNaught
colors:
  surface: '#0b1326'
  surface-dim: '#0b1326'
  surface-bright: '#31394d'
  surface-container-lowest: '#060e20'
  surface-container-low: '#131b2e'
  surface-container: '#171f33'
  surface-container-high: '#222a3d'
  surface-container-highest: '#2d3449'
  on-surface: '#dae2fd'
  on-surface-variant: '#bdc8d1'
  inverse-surface: '#dae2fd'
  inverse-on-surface: '#283044'
  outline: '#87929a'
  outline-variant: '#3e484f'
  surface-tint: '#7bd0ff'
  primary: '#8ed5ff'
  on-primary: '#00354a'
  primary-container: '#38bdf8'
  on-primary-container: '#004965'
  inverse-primary: '#00668a'
  secondary: '#6bd8cb'
  on-secondary: '#003732'
  secondary-container: '#29a195'
  on-secondary-container: '#00302b'
  tertiary: '#c7c8ff'
  on-tertiary: '#1000a9'
  tertiary-container: '#a7a9ff'
  on-tertiary-container: '#2b29bb'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#c4e7ff'
  primary-fixed-dim: '#7bd0ff'
  on-primary-fixed: '#001e2c'
  on-primary-fixed-variant: '#004c69'
  secondary-fixed: '#89f5e7'
  secondary-fixed-dim: '#6bd8cb'
  on-secondary-fixed: '#00201d'
  on-secondary-fixed-variant: '#005049'
  tertiary-fixed: '#e1e0ff'
  tertiary-fixed-dim: '#c0c1ff'
  on-tertiary-fixed: '#07006c'
  on-tertiary-fixed-variant: '#2f2ebe'
  background: '#0b1326'
  on-background: '#dae2fd'
  surface-variant: '#2d3449'
typography:
  display:
    fontFamily: Geist
    fontSize: 48px
    fontWeight: '600'
    lineHeight: '1.1'
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Geist
    fontSize: 32px
    fontWeight: '600'
    lineHeight: '1.2'
  headline-md:
    fontFamily: Geist
    fontSize: 24px
    fontWeight: '500'
    lineHeight: '1.3'
  body-lg:
    fontFamily: Geist
    fontSize: 16px
    fontWeight: '400'
    lineHeight: '1.5'
  body-md:
    fontFamily: Geist
    fontSize: 14px
    fontWeight: '400'
    lineHeight: '1.5'
  body-sm:
    fontFamily: Geist
    fontSize: 12px
    fontWeight: '400'
    lineHeight: '1.4'
  label-md:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '500'
    lineHeight: '1.2'
    letterSpacing: 0.02em
  label-sm:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '400'
    lineHeight: '1.2'
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  gutter: 12px
  margin: 20px
---

<!-- ────────────────────────────────────────────────────────────────────────
     ARCHITECTURE RULES — hand-authored, NOT Stitch-synced.
     Everything below the "Visual Design System" divider is regenerated from
     the Stitch project on re-sync; this section is not. Preserve it across
     syncs (or extract it to a dedicated ARCHITECTURE.md).
     ──────────────────────────────────────────────────────────────────────── -->

# Architecture Rules

These are the core, binding rules for how workflow widgets are built. They take
precedence over any incidental pattern found in existing code.

## Node composition (supersedes OOP inheritance)

We have **shifted from strict OOP inheritance to a compositional widget
pattern.** The former approach — concrete nodes extending an abstract `BaseNode`
class — is **deprecated**.

- **Every workflow widget MUST be built by composing the universal
  `DoubleNaughtNodeWrapper` shell component.** Nodes no longer subclass a base
  class; they wrap themselves in this one shell.
- `DoubleNaughtNodeWrapper` is the single owner of all node container chrome
  defined by the Base Node Blueprint: dark surface, thin cobalt-blue outline,
  rounded corners, global padding, the reserved camelCase header, and the
  text-scaling boundary.
- The wrapper **accepts modular child configurations** rather than fixed
  subclasses. A node supplies a composable child — e.g. the upcoming
  **`Sam3ControlPanel`** — which renders inside the shell body. Children are
  swappable and reusable across node types without any class hierarchy.

## Edge-Anchor port pattern

Ports are not decorations inside the body — they define the node's connection
boundary, so they must sit on its physical edges:

- **All ports are positioned on the absolute boundary edges of the
  `DoubleNaughtNodeWrapper`:** **Inputs on the left edge, Outputs on the right
  edge.** The wrapper places them with `Positioned` widgets in a `Stack` so the
  dot centers land exactly on the card's left/right boundary.
- **Noodle endpoints must coincide with the port dots.** The canvas edge
  painter and the wrapper share the same anchor geometry (`kPortLaneTop` +
  `idx * kPortSpacing` from the node's top), so a connection line terminates on
  the actual port rather than the node's center.
- **Port contract — SAM3 work node (`sam3Work`):** a **`preview`** Input port on
  the left and an **`imageArray`** Output port on the right (the segmentation
  array result stream), alongside its existing `segmentStream` output.

## What the wrapper enforces

Because all nodes pass through one shell, two cross-cutting rules are enforced in
exactly one place:

1. **Strict camelCase styling.** Header titles and port labels (e.g.
   `rawFileStream`, `inputStream`, `Sam3ControlPanel`) are rendered through the
   wrapper so the camelCase convention is applied uniformly and cannot drift per
   node.
2. **Data-contract clipping prevention.** The wrapper clamps text scaling and
   constrains label layout so key/value data-contract labels never clip or
   overflow on variable data.

## Backend data contract (camelCase keys)

The camelCase rule extends across the wire. **All JSON payloads returned by
DoubleNaught backend services MUST use camelCase keys** (e.g. `segmentMask`,
`inferenceMetrics`, `processingTimeMs`, `sessionId`), so a node's data contract
reads identically in Dart and on the server. The SAM3 service in `double_touch/`
is the reference implementation. (The upstream `mlx_sam3` reference backend uses
snake_case; that convention is **not** carried into DoubleNaught.)

## Data-contract boundary (unchanged)

- **Processing nodes are AA-in → AA-out** — they consume and emit D4M
  associative arrays.
- **Ingest nodes are the boundary** — no AA input; raw-out only. They bootstrap
  raw external bytes into the AA pipeline; a downstream parser is what first
  lifts raw data into an AA.
- **The File Source node is the canonical ingestion-layer boundary.** It reads
  from **local storage** (the native file picker) and streams the file's
  contents out as **raw string/byte data** — explicitly **not** a structured D4M
  associative array. It sits at the very edge of the graph: it has no input
  port, only a raw output stream that a downstream node parses into an AA.

## Prompt Node (`promptNode`)

A prompt-authoring processing node: it composes free text (a prompt, a code
snippet, an instruction block) and publishes it as an AA, optionally seeded from
an upstream file.

### Node contract

| | |
|---|---|
| Type | `promptNode` |
| Input port (left edge, idx 0) | **`fileInput`** — an AA carrying text/code |
| Output port (right edge, idx 0) | **`promptOutput`** — an AA carrying the composed prompt |

- **`fileInput` ingest.** An arriving AA is flattened to text and merged into the
  prompt state — **appended** by default, **prepended** when the node's insert
  mode says so. Preference order for which cells supply the text: a `text`,
  `prompt`, `content`, or `val` column if the AA has one; otherwise every string
  value, joined by newline. Ingest mutates the same editable state the user
  types into, so an ingested file is immediately editable.
- **`promptOutput` payload.** Row `prompt:<nodeId>` — stable across edits so
  downstream row keys do not churn per keystroke.

  | col | val |
  |---|---|
  | `prompt` | the full composed text |
  | `char_count` | length of `prompt` (int) |

- Being AA-in → AA-out, the Prompt Node is a **processing node**, not an ingest
  boundary: it never reads local files itself.

### Interface policy

The prompt text has exactly **one owner** — a single `TextEditingController`
held by the node's `State`. Every editing surface attaches to that controller,
so synchronisation is structural rather than a mirroring routine that can drift:

1. **Small inline editor.** A compact multi-line `TextField` in the node body
   for quick edits and clipboard work.
2. **Large expanded canvas editor.** `PromptCanvasEditor`, mounted as this
   node's tab in the right-hand Focus Panel and opened by the body's **Expand
   Editor** action. High-density monospace workspace with line numbers, a word
   wrap toggle, and Copy All / Paste / Clear actions.
3. **Bidirectional sync.** Because both surfaces share the one controller, a
   keystroke in either is visible in the other on the next frame; neither is a
   copy of the other.

### Stream dispatch

Every state change re-broadcasts on `promptOutput`, coalesced by a short
debounce so a burst of keystrokes emits once the typing settles rather than one
AA per character. Emission is unconditional on content: clearing the editor
publishes an empty prompt rather than silently retaining the last one.

## Secure Settings node (`secureSettingsNode`)

The graph's credential source. Holds named provider profiles and publishes the
selected one's **metadata** — never its secret.

### Data contract

| | |
|---|---|
| Type | `secureSettingsNode` |
| Output port (right edge, idx 0) | **`authOutput`** — a 1×5 AA of profile metadata |

Row key is the profile id; the five columns are `displayName`, `provider`,
`baseUrl`, `credentialRef`, `maxContextTokens`.

**The invariant: a raw secret never enters the AA matrix or any serialized
state.** `credentialRef` is an opaque handle (`credential:<profileId>`) that a
downstream node redeems against `KeyVault.secretFor` at request time. Three
structural guarantees back that up rather than leaving it to discipline:

- `AuthProfile` has **no field that can hold a key**, so no serializer,
  `toString`, or log line can emit one.
- `KeyVault.secretFor` is the single egress point for plaintext — one greppable
  call site per consumer.
- Node params persist only `selectedProfileId`, a pointer. A workflow file has
  never held a credential, so sharing one is safe by construction.

Emission is gated on a key actually being on file: a profile whose secret is
missing (session-only after a restart, or saved without one) reads **error** and
stays off the wire, because a `credentialRef` nobody can redeem is worse than no
payload.

### Storage layer (local-first vault)

`VaultStore` is opaque key→value storage with platform-appropriate protection;
`KeyVault` selects the backing and routes by the profile's `sessionOnly` flag.

| Mode | Backing | At rest |
|---|---|---|
| Desktop **(default)** | `EncryptedFileVaultStore` | AES-256-GCM per value into a JSON file under app-support, data key in a sibling `chmod 600` file. |
| Desktop, signed builds | `KeychainVaultStore` — opt in with `--dart-define=DN_VAULT=keychain` | OS keychain: macOS Keychain, Linux Secret Service, Windows DPAPI, iOS/Android keystore. The OS owns the key; this process holds none. Items are device-bound and non-syncing, so keys can't ride a backup off-machine. |
| Web / WASM | `EncryptedIdbVaultStore` | AES-256-GCM per value into IndexedDB. |
| Session Storage Only | `SessionVaultStore` | RAM for the process lifetime; nothing persisted. |

Both encrypting backings share one implementation of the envelope
(`SecretEnvelope`: AES-256-GCM, fresh nonce per write, ciphertext + nonce + MAC),
so the crypto is written and reasoned about once.

**Why the keychain is not the desktop default.** It is the stronger option and
should be used wherever the app is signed — but it is *unusable* from a build with
no signing identity, in both of its flavors, and neither failure degrades
gracefully:

- The **data-protection** keychain needs a `keychain-access-groups` entitlement,
  which needs a development certificate. Without one every write fails
  `-34018 errSecMissingEntitlement`; adding the entitlement anyway fails the
  build outright (*"has entitlements that require signing with a development
  certificate"*).
- The **file-based** login keychain records the accessing app's code signature in
  each item's ACL. An ad-hoc-signed binary (what `flutter run` produces, and what
  this project builds — `CODE_SIGN_IDENTITY = "-"`, no team) has no stable
  identity to record, so *Always Allow* has nothing to persist and macOS
  re-prompts for the login password on every access. An unbreakable loop, not a
  slow path.

So the vault must not depend on the keychain being usable. Desktop defaults to the
encrypted file; set up signing and pass `--dart-define=DN_VAULT=keychain` to get
the stronger backing back.

Profile IDs map to secrets through `credentialRef`; the non-secret profile index
rides in the same store under a reserved key, which buys one storage path per
platform instead of two.

**Honest limit on both encrypting paths.** Whether the sealed bytes are in
IndexedDB or in a file, the data key has to live somewhere this process can read
unaided, so it sits next to them. That defeats
anything reading the sealed records without also reading the key — DevTools
browsing, an IndexedDB export, a copied Application Support folder, a profile
backup — and GCM's MAC makes tampering fail closed rather than decrypt to
garbage. It does **not** defeat code running in the same context: script on the
page, or any process running as this user. Both encrypting backings are therefore
obfuscation-plus-integrity, not confidentiality against local code — strictly
weaker than the OS keychain, which is why the keychain remains the right choice
wherever the app is signed.

Users who need more should mark the profile **Session Storage Only** (RAM,
nothing persisted), or set up signing and switch to the keychain. A
passphrase-derived key (PBKDF2/Argon2) would close the gap at the cost of a
prompt every launch — a deliberate non-goal, not an oversight.

### Interface

- **Node body** — header status dot (green = key on file and validated, red =
  error, grey = nothing selected), a profile dropdown by display name, and
  **Add** / **Edit**, which open the drawer.
- **`KeyVaultDrawer`** — mounted in the right-hand inspection canvas. Fields:
  Display Name, Provider Type (Google Gemini · Anthropic · OpenAI/Compatible ·
  Ollama Local), Base URL (pre-filled per provider — `http://localhost:11434`
  for Ollama), API Key (masked, show/hide), Max Context Tokens, and Session
  Storage Only. Actions: **Test Connection** and **Save Profile**.
- The drawer edits a working copy and commits only on save. **A stored key is
  never read back into the field** — it shows only whether one is on file, so a
  saved key has no path back onto the screen and "leave blank to keep" is a
  guarantee rather than a hint.

### Test Connection

The cheapest authenticated request each provider offers — a model-listing call in
every case, so a test spends no inference tokens and creates no completion:

| Provider | Request | Credential carried as |
|---|---|---|
| Anthropic | `GET /v1/models` | `x-api-key` **+** `anthropic-version: 2023-06-01` |
| OpenAI/Compatible | `GET /v1/models` | `Authorization: Bearer …` |
| Google Gemini | `GET /v1beta/models` | `x-goog-api-key` |
| Ollama Local | `GET /api/tags` | none — local daemon, key optional |

Anthropic needs both headers: `anthropic-version` is required on every request to
that API, and omitting it fails for the wrong reason, which would read as a bad
key. Results distinguish causes the user can act on — 401/403 is a rejected
credential, 404 means the base URL isn't the API root, 429 means rate-limited
*with* a probably-valid key. Failure text is built from the status code and
exception type, never from the exception's string form, which can quote the
request and its headers.

## Remote Service node (`remoteServiceNode`)

The graph's egress point. Takes a payload from upstream, a credential *reference*
from the Secure Settings node, dispatches one request to an online or on-network
resource (LLM, vision service, remote API), and puts the response plus its
telemetry back on the graph as an AA.

### Node contract

| | |
|---|---|
| Type | `remoteServiceNode` |
| Input port (left edge, idx 0) | **`dataInput`** — payload AA from upstream |
| Input port (left edge, idx 1) | **`authInput`** — profile AA from `secureSettingsNode` |
| Output port (right edge, idx 0) | **`dataOutput`** — result AA |

- **`dataInput`** is flattened to prose by `AaPayload.flattenText()`: the cells of
  the first `text` / `prompt` / `content` / `val` column present, else every
  string value, newline-joined, numeric cells skipped. The Prompt Node's
  `fileInput` reads an upstream AA through the same helper, so "what counts as the
  text of an AA" is defined once rather than twice.
- **`authInput`** supplies `displayName`, `provider`, `baseUrl`, and
  `credentialRef`. Profiles accumulate across payloads keyed by profile id, so a
  Secure Settings node emitting one at a time still fills the dropdown, and a
  re-emission updates a row instead of duplicating it.
- **`dataOutput`** — row `request:<time><rand>`, one per dispatch:

  | col | val |
  |---|---|
  | `text` | the service's reply, empty on failure |
  | `serviceProvider` | the provider that served it |
  | `status` | `ok` · `error` · `cancelled` |
  | `executionTimeMs` | wall-clock for the dispatch (int) |
  | `errorMsg` | empty on success |

  Emitted on **every** outcome, not just success — a downstream node should be
  able to see a failure rather than infer it from silence.

### Credentials never travel between nodes

`authInput` carries the `credentialRef` handle, never the key. At dispatch the
node resolves the profile from the vault by id and reads the secret through
`KeyVault.secretFor`, holding it only for the length of one request. A ref is
therefore only redeemable on the machine whose vault holds it: a workflow shared
with someone else fails with *"No credential redeemable for this profile"* rather
than a puzzling 401.

### Provider dispatch

| Provider | Request | Credential carried as |
|---|---|---|
| Anthropic | `POST /v1/messages` | `x-api-key` **+** `anthropic-version: 2023-06-01` |
| OpenAI/Compatible | `POST /v1/chat/completions` | `Authorization: Bearer …` |
| Google Gemini | `POST /v1beta/models/{model}:generateContent` | `x-goog-api-key` |
| Ollama Local | `POST /api/generate` | none — local daemon |

- **Model ids come from the provider, not from a hardcoded list.** The field's
  **Available models** control asks the credential's own catalogue endpoint —
  `GET /v1/models` (Anthropic, OpenAI-compatible), `GET /v1beta/models` (Gemini,
  `models/` prefix stripped and non-`generateContent` entries dropped), or
  `GET /api/tags` (Ollama) — and offers what comes back. Only Anthropic's default
  is pre-filled (`claude-opus-5`); a hardcoded list for the others would rot, and
  a guessed id 404s in a way that reads like a broken node. The field stays
  **editable**: a catalogue can omit an id that still works (a fine-tune, an
  alias, a private deployment), so the pick-list is a convenience over free text,
  not a replacement. Dispatch refuses with no id at all.
- **Anthropic needs a refusal guard.** A request its safety classifiers decline
  returns **HTTP 200** with `stop_reason: "refusal"` and possibly an empty
  `content` array, so reading `content[0]` unconditionally would throw on a
  well-formed response. The node checks `stop_reason` first and reports the
  refusal category as the error.
- **Failure text is built from the status code and the provider's own `error.message`,
  truncated** — never from a request echo, which would carry the auth header.

### Execution and telemetry

**Submit Request** toggles to **Cancel Request** while in flight; cancelling
closes the HTTP client, which aborts the request and emits a `cancelled` AA.
The status bar reports `Idle` → `Connecting…` → `Streaming response… N bytes` →
`Complete` / `Error`, with an indeterminate progress bar during dispatch —
indeterminate because providers send no content-length for a generated reply, so
there is no honest completion fraction.

`Streaming response…` means the **response body** is arriving: requests are sent
with `stream: false` and the body is read incrementally. Token-level SSE would
mean implementing four different event dialects and is deliberately out of scope.

## Polyglot Exec node (`polyglotExecNode`)

Runs the source code on an incoming AA under a local interpreter, and puts the
run's output back on the graph. The execution half of "load a source file, then
do something with it": `Load File` → **Polyglot Exec** → Preview / Remote Service.

### Node contract

| | |
|---|---|
| Type | `polyglotExecNode` |
| Input port (left edge) | `in_aa` (idx 0) — an AA carrying code, e.g. a `Load File` `contents` output |
| Output port (right edge) | `out_aa` (idx 0) — the 1×8 result matrix |
| Backend | `POST /exec` → `PolyglotExecNode` in `polyglot_exec_node.py` |

**Input.** The documented payload is `file_path`, `language`, `code`, `shebang`,
`args`. All five are optional and read off the AA by column name, because the
node has to work with what upstream actually sends: `Load File` emits a **single
`text` column** for a `.jl` or `.py` file and says nothing about the language. So
`code` is read from the first of `code` / `text` / `content` / `source` / `val`
that is present, and both snake_case and camelCase spellings match — the Dart side
speaks camelCase on the wire. A multi-row AA runs its first usable row.

**Output** — one row, eight columns, in this order:

`status` · `language` · `stdout` · `stderr` · `exit_code` ·
`execution_time_ms` · `code` · `file_path`

`status` is `SUCCESS` | `FAILED` | `TIMEOUT`. `exit_code` stays an `int` and
`execution_time_ms` a `float`: the AA value type is `str | int | float` precisely
so numeric columns need not be stringified. `code` and `file_path` are passed
through, so a downstream node can quote the source that produced the output.

### Language resolution

Layered, most-explicit first — **override → payload `language` → file extension
→ shebang** — and it lives in the backend only. The node's dropdown sends `''`
for *Auto-detect*, so the two sides cannot disagree about precedence. The Dart
`ExecSource` mirrors the same order for the *label* it displays, so what the card
says is what the backend will pick.

| Language | Invocation | Extensions |
|---|---|---|
| `julia` | `julia --startup-file=no -e CODE` | `.jl` |
| `python` | `python3 -c CODE` | `.py` |
| `javascript` | `node -e CODE` | `.js` `.mjs` `.cjs` |
| `bash` | `bash -c CODE` | `.sh` `.bash` |

Nothing resolves ⇒ nothing runs. The node says "Pick a language" and keeps Run
disabled rather than guessing at an interpreter.

`bash -c CODE a b` binds `a` to `$0`, not `$1`, so a placeholder argv0 is
inserted for bash alone — making `$1` the first user argument, as it is in every
other language here.

### Failure is data, not an exception

A snippet that throws, times out, or names an uninstalled interpreter returns
**200 with a `status`**, and the node emits the result AA anyway. A downstream
node should be able to *read* a failure; if a failed run emitted nothing, the
graph could not tell it apart from a run that never happened. Only an unrunnable
*request* — no code at all, an unresolvable language, a non-positive timeout — is
a 4xx, and then there is no run to report on.

### Isolation and its limits

* One subprocess per run via `asyncio.create_subprocess_exec` — an argv list, so
  the snippet is a single argument that cannot be word-split or re-interpreted by
  a shell of ours. (`bash -c` and `python3 -c` are interpreters; interpreting the
  code is the point.)
* `start_new_session=True`, so a timeout kills the **whole process group** — a
  snippet that backgrounds a `sleep` does not leave it running.
* The `communicate()` read is *shielded* from the timeout, so after the kill the
  partial output is still returned. On a hung run that partial output is usually
  the most useful thing there is.
* `cwd` is the source file's directory when `file_path` names a real one, so a
  relative path inside the snippet means what its author meant.
* Output is capped (256 KB by default) with a truncation marker.

**The timeout is the only real resource guard.** There is no sandbox, no syscall
filter, no memory or CPU limit, and the cap bounds what is *returned* rather than
what the child may buffer. This node executes arbitrary code by design — it is a
local developer tool, the backend binds to 127.0.0.1, and the code comes from a
file the user picked. Do not expose `/exec` to a network you do not control.

### Widget

Status is the canonical `NodeStatus` machinery, relabelled for this node:
idle → **Idle**, working → **Running**, complete → **Success**, error → **Error**.
The badge sits at the top of the body rather than in the title bar, because the
shared node header takes a title and an icon only.

Under it: what arrived on `in_aa` (`Lang: julia · File: demo.jl · 12 lines`), the
language override, a timeout box, Run, and a collapsible dark console showing the
last run's `stdout` with `stderr` in the error colour beneath it. The console is
dark regardless of theme — it is a console, and it should read like one. A
blank timeout box falls back to 30 s rather than sending the backend a value it
would reject.

## Group node (`groupNode`)

A collapsed subgraph: several nodes and the wires between them, packed into one
card that drags, selects and deletes as a single thing.

### Node contract

| | |
|---|---|
| Type | `groupNode` |
| Input ports (left edge) | one per **input boundary** — an external source that fed a node inside |
| Output ports (right edge) | one per **output boundary** — a node inside that fed an external target |

The spec's `GroupInputNode` / `GroupOutputNode` are modelled as **data, not nodes**:
a `GroupBoundary` is the mapping `group port idx ⇄ inner child port`, which is all
an edge needs to be re-pointed in either direction. Two proxy node types would
have to be created, positioned, rendered and cleaned up, and would show up in
every `_nodes` traversal on the canvas; a boundary list does the same work
without any of that.

### Where a subgraph lives

`SubgraphGraph` — child nodes (positions **relative to the container**), internal
edges, and the input/output boundary lists — is stored as JSON in the group node's
`params['subgraph']`.

That means a group persists through the existing save/load path with **no change
to `Workflow`**: `params` is already "the node's saved settings", and for a group
the contents *are* the setting. It also keeps one source of truth — there is no
parallel map on the canvas to drift out of step with `_nodes`.

Relative child positions mean dragging the container moves its contents for free,
and expanding is one addition per child.

### Group (`⌘G`)

1. The container is placed at the selection's **top-left** (min x, min y, per axis).
2. Each child is stored at `child position − container position`.
3. Edges wholly inside move into the subgraph; edges wholly outside are untouched.
4. Edges crossing the boundary become ports, and the external edge is re-pointed
   at the group. **Several external sources into one child port share a single
   input port** — they address the same destination.
5. Boundary numbering is sorted by `(child id, port idx)`, so the same selection
   always yields the same port order and a group/ungroup/regroup cycle never
   shuffles a user's wires.

A selection of fewer than two nodes is refused: a group of one is just a node.

### Ungroup (`⌘⇧G`)

The exact inverse:

1. Read the subgraph.
2. Spawn each child at `container position + relative position`.
3. Restore internal edges verbatim.
4. Re-point every external edge from a group port to the child port that port
   proxied.
5. Remove the container.
6. **Leave the unpacked children selected**, so `⌘⌥G` can act on them immediately.

An external edge on a port index with no boundary — a hand-edited workflow file,
say — is **dropped rather than re-pointed at nothing**, since keeping it would
leave an edge addressing a node that no longer exists.

### Regroup (`⌘⌥G`)

Rebuilds the container the selection was last unpacked from, reusing its **id,
position and label** from a `_previousGroupOf` cache keyed by child id.

Boundaries are **re-derived from the current edges**, not replayed from the cache:
a wire added or removed while the nodes were loose is honoured instead of silently
reverted. With nothing cached, `⌘⌥G` forms a fresh group — which is what pressing
"regroup" on an arbitrary selection means.

### Collapsed groups do not run

The children are not mounted while packed, so their info-bus ports do not exist
and **no payload crosses the boundary**. A group is an organisational device;
ungroup to execute. The card says so, so a packed group cannot be mistaken for a
broken pipeline.

Making a collapsed group executable would mean mounting children offstage purely
to keep their ports alive, and registering each child port under the container's
boundary index — a materially different feature, and deliberately not this one.

### Where the commands live

`_groupSelected()`, `_ungroupSelected()` and `_regroupSelected()` are methods on
`_WorkflowPageState`, alongside `_deleteSelectedNodes()` and `_copySelectedNodes()`;
there is no separate `CanvasStateController` in this codebase. The **algorithm**
is not in the page: `Grouping.group` / `Grouping.ungroup` are pure functions over
`(nodes, edges, selection)` in `services/canvas/grouping.dart`, which is what
makes the edge-remapping rules — the part that silently loses connections when
wrong — testable without a widget tree.

Nodes entering or leaving a group unmount, so the canvas drops their port-bus
registrations first (`_forgetNodeWiring`); otherwise the bus keeps dead ports.

`groupNode` is **not** in the Node Catalog: a group is made by grouping, never
placed empty.

## Canvas selection

Selecting is how every multi-node command — Delete, Copy, Group, multi-drag —
gets its operands, so the gestures are specified here rather than left to each
command.

| Gesture | Result |
|---|---|
| Click a card | selects it, replacing the selection |
| Shift-click a card | toggles that card in the selection |
| Click empty canvas | clears the node selection (and selects an edge if one is under the pointer) |
| **Left-drag on empty canvas** | **box select** — a marquee |
| **Shift + left-drag** | box select **added** to the existing selection |
| Press-and-drag a card's title bar | moves it, or the whole selection if it is a member |
| Right-click inside a selection | keeps the selection and opens the node menu |

### Box select

A left-drag beginning on empty canvas draws a rectangle and selects every node
it **touches** — a node need not be wholly enclosed, matching every other
node-graph canvas.

No modifier is needed because plain left-drag on empty canvas was unused: the
**view** pans on middle-mouse drag and trackpad two-finger, and zooms on scroll
and pinch. The marquee therefore steals no existing gesture.

Three details are load-bearing:

1. **A drag that begins on a card is not a marquee.** The press belongs to that
   card, so `_onCanvasPanStart` bails when `_nodeAt(pressPoint)` hits something.
   The canvas gesture layer sits *beneath* the cards but a card body has no pan
   handler of its own, so without this check a body-drag would rubber-band over
   the very node being pressed.
2. **`dragStartBehavior: DragStartBehavior.down`.** The default (`start`) reports
   the position where the pan was *recognised* — a slop-distance into the drag —
   which would both offset the anchor corner and test the wrong point in rule 1.
3. **Heights are measured, not assumed.** Cards size themselves to their content,
   so `_nodeRect` takes width from the type table but height from the rendered
   box (via a per-node `GlobalKey`, read only while dragging). A nominal height
   would put the hit test tens of pixels out on the tall nodes.

The previous selection stands until the first move event replaces it, rather than
being cleared on press. The selection bar lives in the page column, so clearing
on press would drop the bar and re-insert it moments later, jolting the canvas
twice during one drag.

The marquee ends leaving focus on the canvas, so ⌘G / Delete apply to what was
just swept up without an intervening click.

<!-- ──────────────────────── Visual Design System (Stitch-synced) ──────────── -->

## Brand & Style

The design system is engineered for high-fidelity technical environments where precision and data density are paramount. The aesthetic is rooted in **Technical Minimalism**, prioritizing clarity and functional efficiency over decorative elements. 

The visual language evokes the feeling of a sophisticated command center: calm, organized, and authoritative. It targets power users who require a focused workspace that minimizes cognitive load while providing deep utility. The emotional response is one of reliability and "expert-grade" toolset performance, achieved through thin strokes, balanced proportions, and a restrained dark-mode palette.

## Colors

The palette for this design system is built on a foundation of deep, layered neutrals to provide a low-strain environment for extended use.

*   **Primary:** A crisp Technical Blue (#38BDF8) used sparingly for active states, focus rings, and critical indicators.
*   **Secondary:** A muted Teal (#0D9488) used for secondary actions and success states.
*   **Neutral (Core):** The background is a "Deep Charcoal" (#0F172A). Surface layers use increments of Slate to define hierarchy without relying on shadows.
*   **Accents:** A subtle Indigo (#6366F1) is available for tertiary data visualization or categorizations.

Avoid large blocks of saturated color. Color should be applied as a "precision tool"—highlighting a line of code, a status dot, or a thin border.

## Typography

Typography is used to reinforce the technical nature of the application. 

*   **Geist** is the primary typeface for all interface elements and body copy, chosen for its exceptional legibility and modern, "developer-tool" aesthetic.
*   **JetBrains Mono** is utilized for labels, metadata, status indicators, and actual technical data/code. This provides a clear visual distinction between "the app interface" and "the data being managed."

Scale is kept tight. For a desktop workspace, font sizes favor the 12px–14px range for high information density, ensuring that users can view large amounts of data without excessive scrolling.

## Layout & Spacing

The design system employs a **Fixed Grid** system for the primary layout shells (sidebar, main stage, inspector) and a **Fluid Flexbox** model for internal content components. 

*   **Spacing Rhythm:** A strict 4px baseline grid ensures alignment.
*   **Density:** Padding is intentionally tight (e.g., 8px for list items, 12px for card interiors) to maximize screen real estate.
*   **Grid Model:** A 12-column grid is used for the main workspace, with gutters of 12px to maintain the "compact" feel.
*   **Adaptability:** On desktop, the sidebar is collapsible to a narrow icon-only state. Content does not reflow wildly but instead utilizes horizontal scrolling or truncation with tooltips to maintain data integrity.

## Elevation & Depth

This system avoids traditional drop shadows to maintain a flat, technical appearance. Depth is conveyed through **Tonal Layering** and **Thin Outlines**:

1.  **Level 0 (Background):** The deepest Slate/Charcoal (#020617).
2.  **Level 1 (Surface):** Panels and sidebars use a slightly lighter Slate (#0F172A).
3.  **Level 2 (Active/Floating):** Modals or popovers use a border of 1px (#1E293B) and a subtle backdrop blur (8px) to separate from the background.

Instead of shadows, use "Ghost Borders"—1px strokes that are only 10-15% lighter than the surface they sit on. This creates a crisp, architectural structure without the "fuzziness" of elevation shadows.

## Shapes

The shape language is disciplined and geometric. 

*   **Corner Radius:** A universal 4px (`0.25rem`) radius is applied to buttons, inputs, and cards. This "Soft" setting provides enough modern polish to feel contemporary while remaining sharp enough to feel professional and technical.
*   **Consistency:** Avoid large pill shapes or full circles except for status pips (e.g., online/offline indicators). Every structural element should feel like a modular block in a larger machine.

## Components

Components in this design system follow an "Outline-First" philosophy.

*   **Buttons:** Default state is a 1px border with no fill. On hover, the border brightens. Only the "Primary Action" button should ever have a subtle solid fill (use 10% opacity of the primary color).
*   **Inputs:** Minimalist outlines with "JetBrains Mono" text. The focus state should be a sharp 1px primary color border with no outer glow.
*   **Chips/Tags:** Small, rectangular with 2px rounding. Use monospaced labels. Backgrounds should be a dark tint of the tag's semantic color (e.g., 5% red for an 'error' tag).
*   **Lists:** High-density rows (32px height). Use subtle dividers (#1E293B) and a "solid Slate" highlight for the selected state.
*   **Cards:** Defined by 1px borders rather than shadows. Headers are separated from content by a thin horizontal rule.
*   **Scrollbars:** Ultra-thin (4px), dark grey, appearing only on hover to reduce visual noise.

<!-- The "Visual Design System" sections above (Brand & Style → Components) plus the YAML frontmatter are synced from Stitch project "DoubleNaught Workflow Manager" (projects/4113127279095342047) on 2026-06-17. Source of truth for visual tokens: the Stitch design system; re-sync via the Stitch MCP rather than editing tokens by hand. WARNING: a full re-sync regenerates this file and will overwrite the hand-authored "Architecture Rules" section at the top — preserve it (or move it to ARCHITECTURE.md) before re-syncing. -->

