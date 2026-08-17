# asb-app Flutter Client Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`). TDD where a host test can hold the logic; device/emulator only for the generated bridge and UI. **All Flutter / Rust-Android / emulator work runs on charmander (x86_64) over `ssh charmander` — never on arm64 squirtle.** Commit per task.

**Goal:** An Android-first Flutter app that pairs with an `asb-sidecar` host, mirrors its live agent-shell sessions with faithful 3-level (turn → item → detail) rendering, and drives them back (inject prompts, answer permissions, interrupt) — over the end-to-end-encrypted iroh transport from Plan 1.

**Architecture:** The app lives **inside the `asb-app` repo** at `app/` so its Rust bridge can path-depend on `crates/asb-protocol` (which itself path-deps `../roam/...roam-pake`; both must be present on the build box — they are on charmander). Structure copies caremate's proven `roam_flutter` bridge verbatim: a local frb plugin `app/packages/asb_client/` wrapping a Rust crate that re-exposes `asb-protocol`'s `Identity` + pairing + `PhoneClient` to Dart via `flutter_rust_bridge`. Two Rust layers (plain-Rust core `client.rs` exercised by host `cargo test`; a thin `api/` shim with no logic). The Dart side is Riverpod-free, plain `ChangeNotifier`/streams to start — YAGNI.

**Tech Stack:** Flutter 3.41 (nix), `flutter_rust_bridge` 2.11.1 (pinned, matching caremate), fenix Rust + 3 Android ABIs, cargo-ndk, the `asb-protocol` crate. Devenv copied from `~/projects/hex_hound/caremate` (flake + `.nix/devenv.nix`).

---

## Prerequisites / build host

- Sync the repo to charmander before any build: `rsync -a --delete --exclude target --exclude .direnv --exclude .devenv --exclude build ~/projects/asb-app/ charmander:projects/asb-app/`. Location MUST be `~/projects/asb-app` so `asb-protocol`'s `../roam/...` path-dep resolves against charmander's `~/projects/roam`.
- All `flutter`, `cargo ndk`, `flutter_rust_bridge_codegen`, `gradlew`, and emulator commands: `ssh charmander 'cd ~/projects/asb-app/app && nix develop -c <cmd>'` (or enter the devenv once and run interactively).
- Host `cargo test` for the bridge core CAN run on squirtle (native aarch64-linux, not Android) — that's how the logic is tested fast. Only the generated bridge + APK need charmander.

## File Structure

```
app/                                   # Flutter project (flutter create output, trimmed to android+linux)
  flake.nix .envrc .nix/devenv.nix     # copied from caremate, renamed
  pubspec.yaml
  lib/
    main.dart                          # RustLib.init() then runApp
    app.dart                           # MaterialApp, routing (pair ↔ sessions)
    bridge.dart                        # thin re-export of the generated RustLib + api types
    state/
      host_store.dart                  # paired hosts (persisted), the active connection
      session_store.dart               # per-host sessions + their update log, live stream
    model/
      turn.dart                        # client-side 3-level collapse: groups Updates by `turn`
    ui/
      pair_page.dart                   # enter code + host node-id (QR later)
      sessions_page.dart               # list of sessions across hosts
      session_page.dart                # one session: turns list, input, permission sheet
      widgets/turn_tile.dart           #   collapsed turn -> expand -> item -> detail
  packages/asb_client/                 # frb bridge (copy of roam_flutter shape)
    pubspec.yaml flutter_rust_bridge.yaml
    android/build.gradle android/src/main/AndroidManifest.xml
    lib/asb_client.dart                # export surface (RustLib + api types)
    lib/src/rust/...                   # GENERATED (committed)
    rust/
      Cargo.toml                       # cdylib+staticlib+rlib; dep asb-protocol (path), frb 2.11.1
      src/lib.rs  src/api/mod.rs  src/api/client.rs  src/client.rs  src/frb_generated.rs (GENERATED)
      tests/                           # host cargo tests over src/client.rs
```

---

## Phase A: Rust bridge that cross-compiles to Android

The load-bearing risk. Prove the toolchain end-to-end before writing any UI.

### Task A1: Scaffold app + devenv on charmander

- [ ] **Step 1:** `ssh charmander`, `cd ~/projects/asb-app`, `flutter create --platforms=android,linux --org com.sezdm --project-name asb app`. (Linux desktop kept so a fast non-emulator smoke of pure-Dart UI is possible; iOS/web deferred.)
- [ ] **Step 2:** Copy `flake.nix`, `.envrc`, `.nix/devenv.nix` from caremate into `app/`; strip caremate-only bits (mobile-dev plugin deps, saf_backup, playwright/mcp, mempalace) down to: fenix toolchain + 3 Android `rust-std`, `cargo-ndk`, `flutter_rust_bridge_codegen`, `cargo-expand`, `modules.flutter { android.emulator }`. Keep the `CARGO_HOME`/`CARGO_TARGET_DIR`/`ANDROID_NDK_HOME`/`CARGO_NET_GIT_FETCH_WITH_CLI` env and the gradlew-shebang `enterShell` heal verbatim.
- [ ] **Step 3:** `nix develop -c flutter doctor -v` on charmander → Android toolchain OK. Commit (`chore(app): flutter scaffold + devenv copied from caremate`).

### Task A2: Bridge crate skeleton + host test (logic first)

**Files:** `app/packages/asb_client/rust/{Cargo.toml,src/lib.rs,src/client.rs,src/api/mod.rs,src/api/client.rs}`, `rust/tests/`.

- [ ] **Step 1: Failing host test** in `rust/tests/pairing.rs` — the plain-Rust core `client.rs` must expose a `Client` façade with the pairing + connect surface, testable against a stub sidecar the same way `phone_server`'s `phone_mirrors_and_injects` does. Reuse `asb-protocol`'s `build_endpoint_minimal`, `pair_host`, `PhoneClient`. Assert: `Client::pair(code, host_id_hex, host_addr_ticket)` returns a persisted host entry, and `Client::connect(host)` yields a stream that mirrors a scripted Update and accepts an injected input.
- [ ] **Step 2:** `cargo test -p asb_client` → FAIL (no `Client`). (Runs on squirtle, native.)
- [ ] **Step 3: Implement `src/client.rs`** — a plain-Rust façade over `asb-protocol`: identity load/create at a given dir; `pair`; hold an `Endpoint`; `connect` → spawn a task owning `PhoneClient`, expose `mpsc::Receiver<Update>` drained by the bridge; `send_input`/`answer_permission`/`interrupt`/`hello`. `anyhow::Result` throughout, no frb attributes. `Cargo.toml`: `crate-type=["cdylib","staticlib","rlib"]`, `flutter_rust_bridge="=2.11.1"`, `asb-protocol={path="../../../../crates/asb-protocol"}`, tokio, anyhow. Add the `[lints.rust] unexpected_cfgs cfg(frb_expand)` and `[profile.release] opt-level="z",lto,codegen-units=1,strip` blocks from roam_flutter.
- [ ] **Step 4:** `cargo test -p asb_client` → PASS.
- [ ] **Step 5:** Commit (`feat(app): asb_client rust core + host pairing test`).

### Task A3: frb api shim + codegen

- [ ] **Step 1:** Write `src/api/client.rs` — the boundary: `RustClient` opaque type wrapping the core; `#[frb]` async methods `pair`, `connect` (returns a `StreamSink<UpdateDto>`), `send_input`, `answer_permission`, `interrupt`; plus DTOs (`UpdateDto`, `PayloadDto`, `HostDto`, `PermissionOptionDto`) that flatten `asb-protocol` types into frb-friendly shapes (frb dislikes deep serde enums — mirror caremate's `VaultChange` flattening). `src/api/mod.rs` = `pub mod client;`. `src/lib.rs` = `pub mod api; pub mod client; mod frb_generated;`.
- [ ] **Step 2:** `flutter_rust_bridge.yaml` (`rust_input: crate::api`, `rust_root: rust/`, `dart_output: lib/src/rust`). Run `nix develop -c flutter_rust_bridge_codegen generate` on charmander from `packages/asb_client/`.
- [ ] **Step 3:** Commit the generated `frb_generated.rs` + `lib/src/rust/**` (`feat(app): frb api surface + generated bridge`).

### Task A4: Android .so builds (the real gate)

- [ ] **Step 1:** Copy `android/build.gradle` + `android/src/main/AndroidManifest.xml` from roam_flutter; rename group/namespace to `com.sezdm.asb_client`, keep the `cargoBuild`/`preBuild` wiring and all guard `doFirst` checks. `pubspec.yaml` for the plugin: `ffiPlugin: true` android+ios, `flutter_rust_bridge: 2.11.1` pinned.
- [ ] **Step 2:** `lib/asb_client.dart` exports `RustLib` + the api types (mirror `roam_flutter.dart`).
- [ ] **Step 3:** Add `asb_client: {path: packages/asb_client}` to the app `pubspec.yaml`; `nix develop -c flutter pub get`.
- [ ] **Step 4: The gate:** `ssh charmander 'cd ~/projects/asb-app/app && nix develop -c bash -c "cd packages/asb_client/rust && cargo ndk -t arm64-v8a -t x86_64 build --release"'`. Expected: three (or two) `libasb_client.so` under `packages/asb_client/android/src/main/jniLibs/<abi>/`. **This proves iroh + roam-pake + asb-protocol cross-compile to Android** — the biggest unknown. If `ring`/`aws-lc`/quinn fails here, resolve toolchain/NDK before proceeding (caremate's comments name the usual failure modes).
- [ ] **Step 5:** Commit (`feat(app): android jniLibs build via cargo-ndk`). Record in the plan whether the .so built for all ABIs.

## Phase B: Dart connection layer

### Task B1: init + host persistence

- [ ] `main.dart` calls `RustLib.init()` before `runApp`. `host_store.dart`: load/save paired hosts (host node-id hex + iroh addr ticket + label) to `shared_preferences` or a JSON file in the app support dir. Test with a Flutter widget test on Linux desktop (no emulator). Commit.

### Task B2: pairing flow

- [ ] `pair_page.dart`: text fields for pairing code + host node-id (+ addr ticket); calls `RustClient.pair`; on success stores the host. (QR scan is a follow-up — `mobile_scanner` — noted, not built.) Manual verify against a real `asb-sidecar pair` on a host over the internet. Commit.

### Task B3: connect + live stream

- [ ] `session_store.dart`: on selecting a host, `RustClient.connect` → consume the `Stream<UpdateDto>`; bucket updates by `session` then by `turn`; expose a `ChangeNotifier`. Reconnect on drop with backoff. Send `hello` with the per-session `last_seq` high-water so catch-up is incremental. Commit.

## Phase C: UI — faithful 3-level rendering

Mirror agent-shell: a turn collapses to one line; expand → each item (thought / tool call / message) collapsed; expand an item → its detail (diff, command output, full text).

### Task C1: sessions list

- [ ] `sessions_page.dart`: all sessions across paired hosts, each showing title + running/idle + last activity. Tap → `session_page`. Commit.

### Task C2: turn tile (the collapse)

- [ ] `model/turn.dart`: pure grouping of `[UpdateDto]` → `Turn{ userPrompt, items:[Item], status }`, `Item` = thought | toolCall | agentMessage with a `detail`. Unit-test the grouping on Linux. `widgets/turn_tile.dart`: three ExpansionTile levels. Commit.

### Task C3: input + permission + interrupt

- [ ] `session_page.dart`: an input box → `RustClient.send_input`; when a permission item arrives, a bottom sheet with the semantic option buttons → `answer_permission`; an interrupt button → `interrupt`. Manual verify against a live host turn. Commit.

## Phase D: emulator + on-device smoke

- [ ] `ssh charmander` → `nix develop -c flutter emulators --launch <avd>` then `flutter run -d emulator`. Pair against a real host, run a turn from Emacs, confirm it mirrors and that inject/permission/interrupt round-trip. This is the first true end-to-end proof (Emacs ↔ sidecar ↔ phone). Record results. Commit any fixes.

---

## Open questions / follow-ups (do NOT silently skip)

- **iroh addr exchange:** pairing needs the host's dialable `EndpointAddr`, not just its node-id. v1: the host's `pair` CLI must also print an addr ticket (relay URL + direct addrs) the phone enters. Add that print to `asb-sidecar pair` (small change in `main.rs`) — flag it during A2/B2. Long-term: node-id-only dialing via a discovery service.
- **FCM push:** the `PushSender` trait is Noop in the sidecar. Wiring real FCM (Firebase project, token registration during pairing, a wake-only data message, `firebase_messaging` on the phone) is a whole sub-plan — deferred, tracked, not part of this plan's "done".
- **QR pairing:** deferred (`mobile_scanner`), noted in B2.
- **iOS:** the bridge already emits a staticlib; iOS packaging is a later platform pass.

## Definition of done (Plan 3)

- Phase A green: `libasb_client.so` cross-compiles for arm64-v8a + x86_64 on charmander (the toolchain risk retired), host `cargo test -p asb_client` passes.
- Phases B–C: the app pairs, connects, mirrors sessions with 3-level rendering, and drives inject/permission/interrupt — verified on the emulator against a real `asb-sidecar` + Emacs turn (Phase D).
- Honest scope: FCM push, QR pairing, iOS, and multi-host niceties are explicitly follow-ups. Do not claim the companion is "done" until Phase D's end-to-end emulator run passes; a green APK build ≠ a working remote surface.
