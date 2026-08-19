# Companion App — Design Spec (2026-08-16)

> Phase 3 of [agent-shell-bridge](../../README.md): replace Discord as the remote
> surface with an own **E2E, serverless** companion app that renders agent-shell
> sessions *faithfully* and drives them back. Working codename: **`asb-app`**
> (name TBD — see Open Questions).

## 1. Goal & scope

Build a **Flutter (Android-first) companion app** that mirrors live Emacs
`agent-shell` sessions to a phone and drives the agent back, over an
**end-to-end-encrypted, serverless** transport (iroh), with **FCM wake** for
background notification.

**v1 target = usable daily-driver** ("replace Discord for me"): faithful
three-level rendering of thinking / tool-calls / files, prompt injection,
tap-to-approve permissions, slash commands, and push. Built incrementally
(skeleton → push → rendering → permissions) but specified as one slice.

**Audience:** personal use (your devices), **architected so it can go public
later** — no decision here forecloses a multi-user release.

**Explicitly out of scope for this spec** (each its own future spec):
multi-*user* accounts, monetization, iOS/web/desktop clients, self-hosted
relays. The design keeps all of these unblocked but builds none of them.

## 2. Architecture & components

```
  ┌───────────────────────── Host A (e.g. charmander) ─────────────────────┐
  │  Emacs instance 1 ─┐                                                    │
  │  Emacs instance 2 ─┼─ unix socket ($XDG_RUNTIME_DIR/asb.sock) ─┐        │
  │  (agent-shell      │   agent-shell-bridge-app.el (per instance) │       │
  │   sessions)        ┘                                            ▼       │
  │                                            ┌────────────────────────┐   │
  │                                            │  SIDECAR daemon         │   │
  │                                            │  (ONE per user/host,    │   │
  │                                            │   spawned on demand)    │   │
  │                                            │  iroh EP · roster ·     │   │
  │                                            │  PAKE · replay log ·    │   │
  │                                            │  FCM sender · presence  │   │
  │                                            └───────────┬────────────┘   │
  └────────────────────────────────────────────── iroh (E2E) ┊  FCM wake   ┘
                                                             ┊       ┊
  ┌───────────────────────── Host B (e.g. squirtle) ─── its own sidecar ────┐
  └─────────────────────────────────────────────────────────┊──────────────┘
                                                             ▼       ▼
  ┌──────────────────────────── Phone (Flutter) ────────────────────────────┐
  │  UI (session list across ALL paired hosts · 3-level render · input)      │
  │        ▲ flutter_rust_bridge ▼                                           │
  │  Rust core: iroh EP · roster(of hosts) · FCM token · reconnect/catchup   │
  └──────────────────────────────────────────────────────────────────────────┘
```

**Components**

1. **`agent-shell-bridge-app.el`** — a new provider, sibling of the Discord one.
   Translates the existing provider-seam slots (`send` / `edit` / `set-status` /
   inject / permission / interrupt) into newline-delimited JSON to/from the
   sidecar socket. Reuses all provider-agnostic **core** logic (structured
   message model, slash commands, permission registry, busy-refuse, interrupt).
   Contains **no** transport or crypto.

2. **Sidecar daemon (Rust)** — **one per user/host**, **spawned on demand** by
   the first Emacs provider to activate (others attach to the existing socket).
   Owns the single iroh endpoint, PAKE pairing, signed roster, per-session
   **persisted replay log**, client **presence**, and the **FCM sender**. All
   Emacs instances on the host connect to it over a shared unix socket. Host-agnostic
   (no Emacs dependency beyond the socket protocol) → reusable by the future
   public build.

3. **Shared transport crate (Rust)** — the wire message model + iroh session
   logic, depended on by **both** the sidecar and the phone core (single source
   of truth for the protocol). Deps: `roam-transport-iroh`, `roam-pake`. **Not**
   used: roam's CRDT / files / RBSR / share.

4. **Phone Rust core** — the shared crate compiled for Android, exposed to
   Flutter via **`flutter_rust_bridge`**. Owns the phone's iroh endpoint, its
   roster **of hosts**, FCM token, and the reconnect/catch-up state machine.

5. **Flutter UI** — unified multi-host session list, three-level disclosure
   rendering, prompt input, permission taps, slash-command entry.

## 3. Trust: symmetric many-to-many roster + PAKE pairing

- **Pairing (one-time, per host↔client pair):** `M-x agent-shell-bridge-app-pair`
  (or a sidecar CLI) makes the sidecar show a **QR + digit code**. The phone
  scans/enters it. **PAKE** (`roam-pake`, SPAKE2-style) turns the low-entropy
  code into a strong shared secret with no key material on any relay. Under it,
  the two sides exchange device **public keys**, **iroh NodeIds**, and the
  phone's **FCM token**, each signs a **roster entry**, both persist it.
- **Symmetric roster, no propagation:**
  - each **sidecar** holds a roster of *client* devices (→ broadcasts to all,
    FCM to all tokens);
  - each **client** holds a roster of *hosts* (→ maintains a connection to each,
    shows a unified session list).
  - Every host↔client combination is a separate pairing. Adding a machine or a
    second phone is just another roster entry on both ends. No cross-host sync.
- **Enforcement:** the sidecar accepts iroh connections only from rostered
  NodeIds and honors only messages signed by a rostered key.
- **Secret storage:** sidecar keypair + roster under the host state dir (later:
  sops / systemd-creds); phone keypair in Android Keystore-backed storage; the
  FCM **service-account** credential lives only on the sidecar.

## 4. Wire protocol

Two hops, **one shared structured message model**. The core stays **lossless** —
the provider forwards every chunk untouched; all collapsing happens in the
*client*.

### 4a. Emacs ↔ sidecar — local **ndjson** over the unix socket

```jsonc
// provider → sidecar
{"t":"session-open","session":"<acp-id>","title":"…"}
{"t":"msg","session":"…","seq":<n>,"turn":<t>,"payload":{…structured…}}
{"t":"status","session":"…","state":"running|idle"}
{"t":"permission","session":"…","id":"…","command":"…","options":[…]}
{"t":"session-close","session":"…"}
// sidecar → provider
{"t":"inject","session":"…","text":"…"}
{"t":"command","session":"…","name":"model|thought|mode|…","arg":"…"}
{"t":"permission-response","session":"…","id":"…","option":"allow|deny"}
{"t":"interrupt","session":"…"}
```

The provider is a thin translator — it holds no queue and no policy; core already
decides busy-refuse, command parsing, and permission resolution.

### 4b. Sidecar ↔ phone — framed **CBOR** over an iroh bidirectional stream

```jsonc
{"type":"hello","roster_sig":…,"fcm_token":…,"last_seq":{"<session>":<n>}}
{"type":"session_list","sessions":[{id,title,state,last_seq}]}
{"type":"update","session":…,"seq":…,"turn":…,"payload":{…structured…}}
{"type":"status","session":…,"state":…}
{"type":"permission_req","session":…,"id":…,"command":…,"options":[…]}
{"type":"catchup","session":…,"since":<seq>}      // phone → host (after wake)
{"type":"input","session":…,"text":…}             // phone → host
{"type":"permission_res","session":…,"id":…,"option":…}
{"type":"command","session":…,"name":…,"arg":…}
{"type":"interrupt","session":…}
```

CBOR on this hop (compact, binary-safe, first-class in Rust *and* Dart).

### 4c. Structured `payload` variants (lossless)

- **`agent_message`** — visible assistant text (streamed / coalesced).
- **`thought`** — thinking text (streamed chunks).
- **`tool_call`** — `{id, kind (read|edit|command|search|…), title, command?,
  status (pending|running|done|failed), content:[text|diff|file-ref],
  locations}`.
- **`tool_call_update`** — `{id, status, content-append}` (running call fills in
  live).
- **`plan`**, **`usage`**, **`user_message`** — as emitted.

### 4d. Turn grouping, sequencing, replay

- **`seq`** — monotonic per session; makes updates ordered + idempotent (a
  half-received turn re-pulls by seq, no dupes).
- **`turn`** — monotonic per session, opened on idle→running, closed on
  running→idle. The client groups a turn's `thought` + `tool_call`s
  **deterministically** by `turn` (not by racing status transitions).
- **Replay log** — the sidecar keeps a **persisted per-session append file** on
  disk (one file per `(session)`, seq-ordered). It survives daemon restart, so
  nothing is lost even across a crash/reboot while the phone was away. On
  `hello` / `catchup`, the sidecar replays everything after the client's
  `last_seq`, then streams live. Same path serves a fresh pair (seq 0) and a
  post-wake reconnect. The sidecar is the source of truth while the host runs;
  the phone may persist its own copy for offline viewing. Old files are pruned
  when their session is closed and fully acknowledged by all rostered clients.

## 5. Client rendering — agent-shell's three-level disclosure

Presentation only; the protocol feeds full detail.

1. **Collapsed turn line** — "Thought, ran a command, edited a file" (verb/noun
   phrasing lifted from agent-shell's `--tool-call-kind-phrases`; present tense
   while running → past when done).
2. **Expand line → per-item rows**, each collapsed: 💭 Thinking · 🔧 `command`
   · 📄 read `file` · ✏️ edited `file`, with a status glyph.
3. **Expand item → full content:** thinking text / command + output / file
   **diff**.

Assistant messages and user messages render as normal chat bubbles; permission
requests render as an inline card with tappable **allow / deny**.

## 6. Connection lifecycle & push

- **Foreground:** the client holds a live iroh connection per paired host; on
  connect it `hello`s with `last_seq`, gets the gap replayed, then streams live.
- **Background/closed:** connections drop. When a turn completes or a permission
  is requested **and no client is connected**, the sidecar sends an **FCM data
  message** — wake-only: `{host_id, session_id, kind}`, no agent content
  (optionally E2E-sealed under the roster key).
- **Wake → catch-up:** FCM wakes the app in the background → it reconnects over
  iroh → `catchup{since:last_seq}` → pulls the missed turn → posts a **local
  notification** ("charmander · edited 2 files — reply?"); tapping opens the
  populated conversation.
- **Nothing-lost:** FCM is only a hint; content always comes over iroh from the
  persisted replay-log file. A dropped/dup/late FCM — or a daemon restart while
  the phone was away — never loses or corrupts data (worst case: open the app
  manually, same catch-up runs).
- **Presence** gates whether an FCM wake is sent at all (foreground clients are
  already live).
- **Reconnect:** iroh relays handle NAT traversal; client retries with backoff
  and re-`hello`s on network changes (wifi↔cellular).

## 7. Emacs provider integration

- New file `agent-shell-bridge-app.el`, registered like the Discord provider:
  `agent-shell-bridge-app-register` + `agent-shell-mode-hook →
  agent-shell-bridge-mode`.
- On first activation it **connects** to the shared socket; if the socket is
  absent it **spawns the daemon on demand** (under a lock/flock so concurrent
  Emacs instances don't double-spawn) and connects. Multiple Emacs instances
  share the one daemon.
- Slot mapping: `send`/`edit` → `{t:"msg"}`; `set-status` → `{t:"status"}`;
  permission request (via the existing `--on-request` path) → `{t:"permission"}`;
  inbound `inject`/`command`/`permission-response`/`interrupt` from the socket
  drive the existing core (`agent-shell-bridge-inject`, `--resolve-permission`,
  interrupt) exactly as the gateway does.
- Session identity = ACP session id `(map-nested-elt agent-shell--state
  '(:session :id))` — stable across resume, matching the Discord provider's key.

## 8. Sidecar daemon

- Single binary; socket at `$XDG_RUNTIME_DIR/asb.sock`. **Spawned on demand** by
  the first Emacs provider (flock-guarded); stays resident after all Emacs
  instances exit (holds the replay log + roster + FCM sender), idle-exits after a
  configurable timeout with no clients and no Emacs connections.
- Responsibilities: iroh endpoint + relay config; PAKE pairing CLI/RPC; signed
  roster (load/verify/enforce); per-session replay log; client presence; FCM
  sender (holds the service-account credential); fan-out to all connected
  clients; idempotent permission resolution across clients (first-wins).
- Multi-instance: aggregates sessions from all connected Emacs instances (UUID
  keys, no collision). If an Emacs instance disconnects, its sessions are marked
  closed after a grace period.

## 9. Flutter client

- Copy the **flake-based devenv** structure from `~/projects/hex_hound/caremate`
  (`flake.nix` + `.envrc`, standard Flutter layout). Add **`flutter_rust_bridge`**
  + a `rust/` crate that wraps the shared transport crate.
- Layers: `lib/` (UI + state) → `frb` generated bindings → `rust/` core (iroh,
  roster, reconnect). FCM via `firebase_messaging`; background isolate handles
  data messages → triggers catch-up → local notification.
- v1 screens: **paired-hosts / pairing (QR scan)**, **session list** (across
  hosts), **conversation** (3-level render + input + permission cards).

## 10. Repo & build layout

- **New standalone repo** (not inside roam, not inside agent-shell-bridge —
  it goes public independently): e.g. `asb-app/`, workspace with
  `crates/asb-protocol` (shared), `crates/asb-sidecar` (daemon), `phone/` (the
  Flutter app + its `rust/` frb crate). roam crates consumed via **path deps**
  (`~/projects/roam/roam-sync/crates/...`) for now; vendor/publish before any
  public release.
- **The elisp provider** (`agent-shell-bridge-app.el`) lives in the existing
  `~/projects/agent-shell-bridge` repo beside the other providers.
- **All Flutter/Android/Rust compilation, tests, and emulator runs happen on
  `charmander` (x86_64)** — arm64 (squirtle) cannot. Develop on squirtle, build
  /test over `ssh charmander`.

## 11. Security model

- Transport E2E via iroh (QUIC/TLS to rostered NodeIds only) + app-layer
  signatures under roster keys.
- Pairing secrecy via PAKE — a passive relay observer learns nothing usable.
- FCM carries **no plaintext agent content** — wake-only metadata, optionally
  sealed. Google sees "a push happened to this token," nothing more (Signal
  model).
- No server holds data or keys; the only third parties are iroh relays (traffic
  is encrypted) and FCM (wake hints).

## 12. Error handling

- **Socket down / daemon absent:** provider buffers briefly, attempts
  (re)start, surfaces a status in the agent-shell buffer; never blocks Emacs.
- **iroh disconnect:** client backoff-reconnects + re-`hello`s; sidecar holds
  the replay log so nothing is lost.
- **FCM undelivered/duplicated:** idempotent by design (seq + manual-open
  fallback).
- **Multi-client permission race:** first response wins; later ones ignored.
- **Malformed/unsigned message:** dropped + logged; never crashes the daemon
  (lesson from the ACP proxy — parse for tracking, never die on a bad line).

## 13. Testing strategy

- **Shared crate:** Rust unit tests for protocol encode/decode, seq/turn
  grouping, replay/catch-up, roster verify.
- **Sidecar:** integration test with a mock Emacs socket client + a mock phone
  iroh peer (loopback) — pair, stream a scripted turn, drop + catch-up, FCM
  trigger (mocked sender), multi-client fan-out + permission first-wins.
- **Provider (elisp):** ERT with the socket stubbed (mirror the existing
  gateway-test approach) — slot→ndjson mapping, inbound dispatch into core.
- **Flutter:** widget tests for the three-level disclosure; an integration test
  against a local sidecar (loopback iroh) on **charmander**.
- **End-to-end:** phone (emulator on charmander) ↔ real sidecar ↔ real Emacs +
  `claude-agent-acp` — pair, mirror a turn, inject, approve a permission, push.

## 14. Future (unblocked, not built)

Multi-user accounts & discovery; monetization (E2E as the selling point); iOS /
web (roam-wasm) / desktop clients from the same shared crate; self-hosted iroh
relays; roster propagation across a user's own hosts (if pair-per-host ever
chafes).

## 15. Decisions (resolved 2026-08-16)

1. **Name** — codename `asb-app` for now; rename later (cheap).
2. **Push** — **FCM** for v1, **behind a push trait** so UnifiedPush can slot in
   later without touching call sites.
3. **Replay log** — a **persisted per-session append file** (not a bounded
   in-memory ring); durable across daemon restart; pruned on session close once
   all rostered clients have acked.
4. **Daemon lifecycle** — **spawned on demand** by the first Emacs provider
   (flock-guarded), resident afterward, idle-exit timeout. No systemd unit for
   v1.
