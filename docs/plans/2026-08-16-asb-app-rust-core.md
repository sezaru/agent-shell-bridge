# asb-app Rust Core — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless Rust core of the agent-shell companion app — the shared protocol crate and the sidecar daemon — proving the full E2E transport (PAKE pairing over iroh, roster gating, session mirroring, prompt inject-back, wake-push) with loopback integration tests, before any Emacs or Flutter code exists.

**Architecture:** Two crates in a new `asb-app/` Cargo workspace. `asb-protocol` holds the wire message model (structured payloads with `seq`/`turn`), the ndjson (Emacs) and CBOR (phone) codecs, a persisted append-file replay log, minimal ed25519 identity, an iroh endpoint builder (ALPN `asb/1`), 4-byte-length framing, and the PAKE pairing flow (host + join) — all reused by the sidecar, the future phone core, and tests. `asb-sidecar` is the daemon binary: a unix-socket ndjson server for N Emacs instances, a session registry over the replay log, an iroh server for rostered phones, presence tracking, and a `PushSender` trait (FCM later, Noop in tests).

**Tech Stack:** Rust (tokio async), `iroh` 1.0.0, `roam-pake` (SPAKE2, path dep), `ciborium` (CBOR), `serde_json` (ndjson), `ed25519-dalek`, `ciborium`, `anyhow`/`thiserror`, `fs2` (flock). Nix flake devenv. Build/test **native on squirtle** (aarch64) — this plan needs no Android/charmander (that starts in Plan 3).

**Reuse decision:** only `roam-pake` is taken from roam (standalone, security-critical crypto). `IrohTransport` is bound to roam's `Frame`/loro model, so we write our own endpoint/framing/identity patterned on `roam-transport-iroh`'s `endpoint.rs`/`pairing_lan.rs` (verbatim 4-byte-BE framing, `presets::N0`, `Endpoint::builder(...).secret_key(...).alpns(...)`).

**Key API facts (from roam source):**
- iroh NodeId == ed25519 verifying-key bytes. `SecretKey::from_bytes(&secret_32)` is infallible. `EndpointId::from_bytes(&key32)?` → `EndpointAddr::new(node_id)` → `endpoint.connect(addr, ALPN).await?`.
- Dialer opens the bi stream and **writes first** (`conn.open_bi()`), acceptor `conn.accept_bi()`; `conn.remote_id()` is the authenticated peer NodeId.
- Must `endpoint.close().await` before exit or peers hang ~30s.
- `roam_pake`: `Initiator::start(&code, my_id32, peer_id32) -> (Initiator, msg1)`; `.accept(&msg2) -> (PendingInitiator, my_confirm)`; `PendingInitiator::verify(&their_confirm) -> SessionKey`. `Responder::new(code, my_id32)`, `.respond(peer_id32, &msg1) -> (PendingResponder, msg2)`, `.verify(pending, &their_confirm) -> (SessionKey, my_confirm)`. `SessionKey::split(Side) -> (Sealer, Opener)`; `Sealer::seal(&[u8]) -> Vec<u8>`; `Opener::open(&[u8]) -> Result<Vec<u8>>`. Strictly ordered stateful ciphers, one per direction.

---

## Conventions for every task

- **TDD:** write the failing test, run it red, implement minimally, run it green, commit.
- Build/test command (from `asb-app/`): `nix develop -c cargo test -p <crate> <filter>` (the devenv from Chunk 0). Plain `cargo test` also works inside `nix develop`.
- Commit messages: conventional (`feat:`, `test:`, `chore:`). Commit after each green step.
- Keep files focused; module layout is given per chunk.

---

## Chunk 0: Workspace + devenv scaffold

**Files:**
- Create: `~/projects/asb-app/flake.nix`, `~/projects/asb-app/.envrc`, `~/projects/asb-app/Cargo.toml`, `~/projects/asb-app/.gitignore`
- Create: `~/projects/asb-app/crates/asb-protocol/Cargo.toml`, `.../src/lib.rs`
- Create: `~/projects/asb-app/crates/asb-sidecar/Cargo.toml`, `.../src/main.rs`

- [ ] **Step 1: Create the repo skeleton**

```bash
mkdir -p ~/projects/asb-app/crates/asb-protocol/src ~/projects/asb-app/crates/asb-sidecar/src
cd ~/projects/asb-app && git init
```

- [ ] **Step 2: Write the flake devenv** (`flake.nix`) — Rust toolchain + iroh build deps

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      forAll = f: nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.cargo pkgs.rustc pkgs.rust-analyzer pkgs.clippy pkgs.rustfmt pkgs.pkg-config ];
          RUST_BACKTRACE = "1";
        };
      });
    };
}
```

`.envrc`: `use flake` · `.gitignore`: `/target` `result` `.direnv`.

- [ ] **Step 3: Workspace `Cargo.toml`**

```toml
[workspace]
resolver = "2"
members = ["crates/asb-protocol", "crates/asb-sidecar"]

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
anyhow = "1"
thiserror = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
ciborium = "0.2"
ed25519-dalek = { version = "2", features = ["rand_core"] }
rand = "0.8"
iroh = { version = "1.0.0", features = ["platform-verifier"] }
roam-pake = { path = "../roam/roam-sync/crates/roam-pake" }
fs2 = "0.4"
tracing = "0.1"
tracing-subscriber = "0.3"
```

(Path is relative to `asb-app/`; `roam` is a sibling of `asb-app` under `~/projects`.)

- [ ] **Step 4: `asb-protocol` crate manifest + a trivial test**

`crates/asb-protocol/Cargo.toml`:
```toml
[package]
name = "asb-protocol"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { workspace = true }
serde_json = { workspace = true }
ciborium = { workspace = true }
thiserror = { workspace = true }
anyhow = { workspace = true }
ed25519-dalek = { workspace = true }
rand = { workspace = true }
iroh = { workspace = true }
roam-pake = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }

[dev-dependencies]
tempfile = "3"
```

`src/lib.rs`:
```rust
#[cfg(test)]
mod smoke {
    #[test]
    fn toolchain_works() { assert_eq!(2 + 2, 4); }
}
```

- [ ] **Step 5: `asb-sidecar` manifest + stub main**

`crates/asb-sidecar/Cargo.toml`: depends on `asb-protocol = { path = "../asb-protocol" }` plus `tokio`, `anyhow`, `fs2`, `tracing`, `tracing-subscriber`. `src/main.rs`:
```rust
fn main() { println!("asb-sidecar"); }
```

- [ ] **Step 6: Prove the toolchain builds (esp. the iroh + roam-pake deps resolve)**

Run: `cd ~/projects/asb-app && git add -A && nix develop -c cargo test`
Expected: compiles (iroh + roam-pake fetched/built), `toolchain_works` PASSES. **This step de-risks the whole plan** — if the roam-pake path dep or iroh 1.0.0 doesn't resolve, fix it here before anything else.

- [ ] **Step 7: Commit**
```bash
git add -A && git commit -m "chore: asb-app workspace + devenv scaffold"
```

---

## Chunk 1: `asb-protocol` — message model & codecs

**Files:**
- Create: `crates/asb-protocol/src/model.rs` (structured payloads, ids)
- Create: `crates/asb-protocol/src/emacs.rs` (ndjson envelope)
- Create: `crates/asb-protocol/src/wire.rs` (CBOR phone envelope)
- Modify: `src/lib.rs` (`pub mod model; pub mod emacs; pub mod wire;`)

- [ ] **Step 1: Failing test — `model.rs` payload round-trips through serde_json**

```rust
// tests live inline in model.rs
#[test]
fn tool_call_payload_roundtrips() {
    let p = Payload::ToolCall(ToolCall {
        id: "t1".into(), kind: ToolKind::Command, title: "run tests".into(),
        command: Some("cargo test".into()), status: ToolStatus::Running,
        content: vec![Content::Text("…".into())], locations: vec![],
    });
    let j = serde_json::to_string(&p).unwrap();
    let back: Payload = serde_json::from_str(&j).unwrap();
    assert_eq!(p, back);
}
```

- [ ] **Step 2: Run red** — `nix develop -c cargo test -p asb-protocol tool_call_payload` → FAIL (types undefined).

- [ ] **Step 3: Implement `model.rs`**

```rust
use serde::{Deserialize, Serialize};

pub type SessionId = String;   // the agent-shell ACP session id (UUID string)
pub type Seq = u64;
pub type TurnId = u64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Payload {
    AgentMessage { text: String },
    Thought { text: String },
    ToolCall(ToolCall),
    ToolCallUpdate { id: String, status: ToolStatus, content: Vec<Content> },
    Plan { entries: Vec<String> },
    Usage { input: u64, output: u64 },
    UserMessage { text: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub kind: ToolKind,
    pub title: String,
    pub command: Option<String>,
    pub status: ToolStatus,
    pub content: Vec<Content>,
    pub locations: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolKind { Read, Edit, Command, Search, Fetch, Other }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolStatus { Pending, Running, Done, Failed }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Content { Text(String), Diff { path: String, diff: String }, FileRef { path: String } }
// NOTE: Text(String) with internal tag needs a newtype; if serde complains, use
//   Text { text: String }. Adjust the test accordingly. Decide in Step 1.

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionState { Running, Idle }

/// One mirrored event, ordered by `seq`, grouped by `turn`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Update {
    pub session: SessionId,
    pub seq: Seq,
    pub turn: TurnId,
    pub payload: Payload,
}
```

- [ ] **Step 4: Run green** — same command → PASS. (If the internally-tagged `Content::Text(String)` fails to derive, switch to `Text { text: String }` and update the test — resolve now.)

- [ ] **Step 5: Failing test — `emacs.rs` ndjson envelope** (provider ↔ sidecar)

```rust
#[test]
fn emacs_in_msg_parses() {
    let line = r#"{"t":"msg","session":"s","seq":1,"turn":1,"payload":{"type":"agent_message","text":"hi"}}"#;
    match serde_json::from_str::<EmacsIn>(line).unwrap() {
        EmacsIn::Msg { session, seq, .. } => { assert_eq!(session, "s"); assert_eq!(seq, 1); }
        _ => panic!("wrong variant"),
    }
}
```

- [ ] **Step 6: Implement `emacs.rs`**

```rust
use serde::{Deserialize, Serialize};
use crate::model::{Payload, SessionId, Seq, TurnId, SessionState};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum EmacsIn {   // provider -> sidecar
    SessionOpen { session: SessionId, title: String },
    Msg { session: SessionId, seq: Seq, turn: TurnId, payload: Payload },
    Status { session: SessionId, state: SessionState },
    Permission { session: SessionId, id: String, command: String, options: Vec<PermOption> },
    SessionClose { session: SessionId },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum EmacsOut {  // sidecar -> provider
    Inject { session: SessionId, text: String },
    Command { session: SessionId, name: String, arg: Option<String> },
    PermissionResponse { session: SessionId, id: String, option: String },
    Interrupt { session: SessionId },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PermOption { pub id: String, pub label: String }
```

- [ ] **Step 7: Run green; commit** (`test: model + emacs ndjson codecs`).

- [ ] **Step 8: Failing test — `wire.rs` CBOR round-trip** (sidecar ↔ phone)

```rust
#[test]
fn wire_update_cbor_roundtrips() {
    let m = WireMsg::Update(Update { session: "s".into(), seq: 3, turn: 1,
        payload: Payload::AgentMessage { text: "hi".into() } });
    let mut buf = Vec::new();
    ciborium::into_writer(&m, &mut buf).unwrap();
    let back: WireMsg = ciborium::from_reader(&buf[..]).unwrap();
    assert_eq!(m, back);
}
```

- [ ] **Step 9: Implement `wire.rs`**

```rust
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use crate::model::{SessionId, Seq, SessionState, Update};
use crate::emacs::PermOption;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WireMsg {
    Hello { fcm_token: Option<String>, last_seq: HashMap<SessionId, Seq> },
    SessionList { sessions: Vec<SessionMeta> },
    Update(Update),
    Status { session: SessionId, state: SessionState },
    PermissionReq { session: SessionId, id: String, command: String, options: Vec<PermOption> },
    Catchup { session: SessionId, since: Seq },
    Input { session: SessionId, text: String },
    PermissionRes { session: SessionId, id: String, option: String },
    Command { session: SessionId, name: String, arg: Option<String> },
    Interrupt { session: SessionId },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionMeta { pub id: SessionId, pub title: String, pub state: SessionState, pub last_seq: Seq }
```

- [ ] **Step 10: Run green; commit** (`test: wire CBOR codec`).

---

## Chunk 2: `asb-protocol` — persisted replay log

**Files:**
- Create: `crates/asb-protocol/src/replay.rs`
- Modify: `src/lib.rs` (`pub mod replay;`)

Format: one file per session under a base dir, each record = 4-byte BE length + CBOR of `Update`. `seq` is the 1-based record index (assigned on append).

- [ ] **Step 1: Failing test — append assigns increasing seq and read_since replays**

```rust
#[test]
fn append_and_read_since() {
    let dir = tempfile::tempdir().unwrap();
    let mut log = ReplayLog::open(dir.path(), "s").unwrap();
    let s1 = log.append(Payload::AgentMessage { text: "a".into() }, 1).unwrap();
    let s2 = log.append(Payload::AgentMessage { text: "b".into() }, 1).unwrap();
    assert_eq!((s1, s2), (1, 2));
    let got = log.read_since(1).unwrap();          // strictly after seq 1
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].seq, 2);
}

#[test]
fn survives_reopen() {
    let dir = tempfile::tempdir().unwrap();
    { let mut log = ReplayLog::open(dir.path(), "s").unwrap();
      log.append(Payload::AgentMessage { text: "a".into() }, 1).unwrap(); }
    let log = ReplayLog::open(dir.path(), "s").unwrap();   // reopen must recover next seq + records
    assert_eq!(log.read_since(0).unwrap().len(), 1);
}
```

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement `replay.rs`**

```rust
use std::fs::{File, OpenOptions};
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use crate::model::{Payload, Seq, TurnId, Update};

pub struct ReplayLog { path: PathBuf, session: String, file: File, next_seq: Seq }

const MAX_RECORD: usize = 16 * 1024 * 1024;

impl ReplayLog {
    pub fn open(dir: &Path, session: &str) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join(format!("{session}.log"));
        let existing = Self::scan(&path)?;                 // -> Vec<Update>
        let next_seq = existing.last().map(|u| u.seq + 1).unwrap_or(1);
        let file = OpenOptions::new().create(true).append(true).read(true).open(&path)?;
        Ok(Self { path, session: session.to_string(), file, next_seq })
    }

    pub fn append(&mut self, payload: Payload, turn: TurnId) -> std::io::Result<Seq> {
        let seq = self.next_seq;
        let u = Update { session: self.session.clone(), seq, turn, payload };
        let mut body = Vec::new();
        ciborium::into_writer(&u, &mut body).expect("cbor");
        self.file.write_all(&(body.len() as u32).to_be_bytes())?;
        self.file.write_all(&body)?;
        self.file.flush()?;
        self.next_seq += 1;
        Ok(seq)
    }

    pub fn read_since(&self, since: Seq) -> std::io::Result<Vec<Update>> {
        Ok(Self::scan(&self.path)?.into_iter().filter(|u| u.seq > since).collect())
    }

    fn scan(path: &Path) -> std::io::Result<Vec<Update>> {
        let f = match File::open(path) { Ok(f) => f, Err(_) => return Ok(vec![]) };
        let mut r = BufReader::new(f);
        let mut out = Vec::new();
        loop {
            let mut len = [0u8; 4];
            if r.read_exact(&mut len).is_err() { break; }        // EOF (or torn tail -> stop)
            let n = u32::from_be_bytes(len) as usize;
            if n == 0 || n > MAX_RECORD { break; }
            let mut body = vec![0u8; n];
            if r.read_exact(&mut body).is_err() { break; }       // torn record -> ignore tail
            match ciborium::from_reader::<Update, _>(&body[..]) { Ok(u) => out.push(u), Err(_) => break }
        }
        Ok(out)
    }

    pub fn prune(self) -> std::io::Result<()> { std::fs::remove_file(&self.path) }
}
```

- [ ] **Step 4: Run green.**

- [ ] **Step 5: Test — a torn trailing write is ignored, not fatal** (write a valid record, then append 2 junk bytes; `scan` returns the 1 good record). Implement already handles it; assert it.

- [ ] **Step 6: Commit** (`feat: persisted per-session replay log`).

---

## Chunk 3: `asb-protocol` — identity, endpoint, framing

**Files:**
- Create: `crates/asb-protocol/src/identity.rs`
- Create: `crates/asb-protocol/src/net.rs` (endpoint builder + framing)
- Modify: `src/lib.rs`

- [ ] **Step 1: Failing test — identity save/load is stable**

```rust
#[test]
fn identity_roundtrips_node_id() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("id.json");
    let a = Identity::load_or_create(&p).unwrap();
    let b = Identity::load_or_create(&p).unwrap();          // second call loads
    assert_eq!(a.node_id_bytes(), b.node_id_bytes());
}
```

- [ ] **Step 2: Run red. Step 3: Implement `identity.rs`**

```rust
use ed25519_dalek::SigningKey;
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use std::path::Path;

pub struct Identity { signing: SigningKey }

#[derive(Serialize, Deserialize)]
struct OnDisk { secret_b64: String }

impl Identity {
    pub fn load_or_create(path: &Path) -> anyhow::Result<Self> {
        if let Ok(bytes) = std::fs::read(path) {
            let od: OnDisk = serde_json::from_slice(&bytes)?;
            let raw = base64_decode(&od.secret_b64)?;      // helper; or use `base64` crate
            let signing = SigningKey::from_bytes(&raw.try_into().unwrap());
            return Ok(Self { signing });
        }
        let signing = SigningKey::generate(&mut OsRng);
        let od = OnDisk { secret_b64: base64_encode(signing.to_bytes()) };
        std::fs::write(path, serde_json::to_vec(&od)?)?;
        #[cfg(unix)] { use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?; }
        Ok(Self { signing })
    }
    pub fn secret_bytes(&self) -> [u8; 32] { self.signing.to_bytes() }
    pub fn node_id_bytes(&self) -> [u8; 32] { self.signing.verifying_key().to_bytes() }
    pub fn signing(&self) -> &SigningKey { &self.signing }
}
```

(Add `base64 = "0.22"` to the crate; use it instead of the `base64_*` placeholders.)

- [ ] **Step 4: Run green; commit.**

- [ ] **Step 5: Implement `net.rs` — endpoint builder + framing (no unit test for the live endpoint; framing is tested over an in-memory duplex).**

```rust
use iroh::{Endpoint, SecretKey, endpoint::presets};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const ASB_ALPN: &[u8] = b"asb/1";
pub const MAX_FRAME: usize = 8 * 1024 * 1024;

pub async fn build_endpoint(secret_32: [u8; 32]) -> anyhow::Result<Endpoint> {
    let secret = SecretKey::from_bytes(&secret_32);
    let ep = Endpoint::builder(presets::N0)
        .secret_key(secret)
        .alpns(vec![ASB_ALPN.to_vec()])
        .bind().await?;
    Ok(ep)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, body: &[u8]) -> anyhow::Result<()> {
    anyhow::ensure!(body.len() <= MAX_FRAME, "frame too large");
    w.write_all(&(body.len() as u32).to_be_bytes()).await?;
    w.write_all(body).await?;
    w.flush().await?;
    Ok(())
}

pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> anyhow::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await?;
    let n = u32::from_be_bytes(len) as usize;
    anyhow::ensure!(n <= MAX_FRAME, "frame too large");
    let mut body = vec![0u8; n];
    r.read_exact(&mut body).await?;
    Ok(body)
}
```

- [ ] **Step 6: Failing test — frame round-trip over `tokio::io::duplex`**

```rust
#[tokio::test]
async fn frame_roundtrips_over_duplex() {
    let (mut a, mut b) = tokio::io::duplex(1024);
    let payload = b"hello frame".to_vec();
    let p2 = payload.clone();
    let h = tokio::spawn(async move { write_frame(&mut a, &p2).await.unwrap(); });
    let got = read_frame(&mut b).await.unwrap();
    h.await.unwrap();
    assert_eq!(got, payload);
}
```

- [ ] **Step 7: Run green; commit** (`feat: identity + iroh endpoint + framing`).

---

## Chunk 4: `asb-protocol` — roster + PAKE pairing over iroh

**Files:**
- Create: `crates/asb-protocol/src/roster.rs`
- Create: `crates/asb-protocol/src/pairing.rs`
- Modify: `src/lib.rs`

Steady-state security = iroh QUIC/TLS (peer authenticated by NodeId) + roster allow-list. PAKE is used **only during pairing** to bootstrap trust and exchange NodeIds + FCM token over an untrusted relay.

- [ ] **Step 1: Failing test — roster save/load + membership**

```rust
#[test]
fn roster_persists_and_gates() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("roster.json");
    let mut r = Roster::load(&p).unwrap();
    let node = [7u8; 32];
    r.add(RosterEntry { node_id: node, kind: PeerKind::Client, fcm_token: Some("tok".into()), added_at: 0 }).unwrap();
    let r2 = Roster::load(&p).unwrap();
    assert!(r2.contains(&node));
    assert_eq!(r2.client_tokens(), vec!["tok".to_string()]);
}
```

- [ ] **Step 2: Implement `roster.rs`** — `PeerKind { Host, Client }`, `RosterEntry { node_id:[u8;32], kind, fcm_token:Option<String>, added_at:u64 }` (serialize node_id as base64/hex), `Roster { entries: Vec<RosterEntry>, path }` with `load/add(persist)/contains/client_tokens/hosts`.

- [ ] **Step 3: Green; commit.**

- [ ] **Step 4: Failing integration test — two endpoints pair with the right code, fail on the wrong one**

```rust
// pairing.rs #[cfg(test)]
#[tokio::test]
async fn pake_pairing_loopback_ok_and_wrong_code_fails() {
    // host endpoint
    let host_id = Identity::load_or_create(&tmp("h")).unwrap();
    let join_id = Identity::load_or_create(&tmp("j")).unwrap();
    let host_ep = build_endpoint(host_id.secret_bytes()).await.unwrap();
    let join_ep = build_endpoint(join_id.secret_bytes()).await.unwrap();
    let host_node = iroh::EndpointId::from_bytes(&host_id.node_id_bytes()).unwrap();

    let code = roam_pake::PairingCode::generate();
    let code_str = code.as_str().to_string();

    let host_task = tokio::spawn({
        let host_ep = host_ep.clone();
        async move { pair_host(&host_ep, &code, &host_id).await }   // -> RosterEntry(client)
    });
    let joined = pair_join(&join_ep, host_node, &join_ep_addr, code_str.parse().unwrap(),
                           &join_id, Some("fcmtok".into())).await.unwrap();
    let host_side = host_task.await.unwrap().unwrap();

    assert_eq!(host_side.node_id, join_id.node_id_bytes());    // host learned client id
    assert_eq!(host_side.fcm_token.as_deref(), Some("fcmtok"));
    assert_eq!(joined.node_id, host_id.node_id_bytes());       // client learned host id

    // wrong code path: expect a PakeError on join
    // (spin a fresh host with a NEW code, join with a different code -> Err)
}
```

- [ ] **Step 5: Implement `pairing.rs`** — copy the `pairing_lan.rs` sequence but with our own post-handshake payload (exchange node ids + fcm token), using `write_frame`/`read_frame` for the raw PAKE blobs and `Sealer`/`Opener` for the identity exchange.

```rust
use roam_pake::{Initiator, Responder, Side, PairingCode};
use iroh::{Endpoint, EndpointId, EndpointAddr};
use crate::net::{ASB_ALPN, read_frame, write_frame};
use crate::identity::Identity;
use crate::roster::{RosterEntry, PeerKind};
use serde::{Serialize, Deserialize};

pub const PAIR_ALPN: &[u8] = b"asb-pair/1";   // separate ALPN from steady-state asb/1

#[derive(Serialize, Deserialize)]
struct JoinInfo { node_id: [u8;32], fcm_token: Option<String> }
#[derive(Serialize, Deserialize)]
struct HostInfo { node_id: [u8;32] }

// JOINER (phone): dials, is PAKE Initiator, speaks first.
pub async fn pair_join(ep: &Endpoint, host: EndpointId, _addr: &EndpointAddr,
    code: PairingCode, me: &Identity, fcm: Option<String>) -> anyhow::Result<RosterEntry> {
    let conn = ep.connect(EndpointAddr::new(host), PAIR_ALPN).await?;
    let (mut send, mut recv) = conn.open_bi().await?;
    let (init, msg1) = Initiator::start(&code, me.node_id_bytes(), *host.as_bytes());
    write_frame(&mut send, &msg1).await?;
    let msg2 = read_frame(&mut recv).await?;
    let (pending, my_confirm) = init.accept(&msg2)?;
    write_frame(&mut send, &my_confirm).await?;
    let their_confirm: [u8;32] = read_frame(&mut recv).await?.try_into()
        .map_err(|_| anyhow::anyhow!("bad confirm len"))?;
    let key = pending.verify(&their_confirm)?;
    let (mut sealer, mut opener) = key.split(Side::Initiator);
    // exchange identities under the PAKE-derived channel
    write_frame(&mut send, &sealer.seal(&serde_json::to_vec(&JoinInfo {
        node_id: me.node_id_bytes(), fcm_token: fcm })?)).await?;
    let host_info: HostInfo = serde_json::from_slice(&opener.open(&read_frame(&mut recv).await?)?)?;
    conn.close(0u8.into(), b"done");
    Ok(RosterEntry { node_id: host_info.node_id, kind: PeerKind::Host, fcm_token: None, added_at: 0 })
}

// HOST (sidecar): accepts on PAIR_ALPN, is PAKE Responder.
pub async fn pair_host(ep: &Endpoint, code: &PairingCode, me: &Identity) -> anyhow::Result<RosterEntry> {
    let incoming = ep.accept().await.ok_or_else(|| anyhow::anyhow!("endpoint closed"))?;
    let conn = incoming.accept()?.await?;
    let joiner = conn.remote_id();                       // authenticated peer NodeId
    let (mut send, mut recv) = conn.accept_bi().await?;
    let mut responder = Responder::new(code.clone(), me.node_id_bytes());
    let msg1 = read_frame(&mut recv).await?;
    let (pending, msg2) = responder.respond(*joiner.as_bytes(), &msg1)?;
    write_frame(&mut send, &msg2).await?;
    let their_confirm: [u8;32] = read_frame(&mut recv).await?.try_into()
        .map_err(|_| anyhow::anyhow!("bad confirm len"))?;
    let (key, my_confirm) = responder.verify(pending, &their_confirm)?;
    write_frame(&mut send, &my_confirm).await?;
    let (mut sealer, mut opener) = key.split(Side::Responder);
    let join_info: JoinInfo = serde_json::from_slice(&opener.open(&read_frame(&mut recv).await?)?)?;
    anyhow::ensure!(join_info.node_id == *joiner.as_bytes(), "identity mismatch");   // bind PAKE id to QUIC id
    write_frame(&mut send, &sealer.seal(&serde_json::to_vec(&HostInfo { node_id: me.node_id_bytes() })?)).await?;
    Ok(RosterEntry { node_id: join_info.node_id, kind: PeerKind::Client,
                     fcm_token: join_info.fcm_token, added_at: 0 })
}
```

Notes for the implementer: the pairing listener must bind ALPN `asb-pair/1` in addition to `asb/1` (adjust `build_endpoint` to accept a list, or add a second alpn). The test uses one process with two endpoints on loopback — `presets::N0` still connects via relay/localhost; if loopback discovery is flaky in CI, seed the addr with `EndpointAddr` direct addresses (`ep.node_addr()`), which the test already threads as `_addr`.

- [ ] **Step 6: Run green** (`nix develop -c cargo test -p asb-protocol pake_pairing` — may take longer, it builds iroh + opens real endpoints). If loopback discovery stalls, switch the connect to a seeded `EndpointAddr` from `host_ep.node_addr().await`.

- [ ] **Step 7: Commit** (`feat: roster + PAKE-over-iroh pairing`).

---

## Chunk 5: `asb-sidecar` — Emacs unix-socket ndjson server

**Files:**
- Create: `crates/asb-sidecar/src/registry.rs` (session registry over replay logs)
- Create: `crates/asb-sidecar/src/emacs_server.rs` (unix socket accept loop)
- Create: `crates/asb-sidecar/src/lib.rs` (wire the pieces; keep `main.rs` thin)

- [ ] **Step 1: Failing test — a session registry appends to the log and broadcasts**

```rust
#[tokio::test]
async fn registry_records_and_broadcasts() {
    let dir = tempfile::tempdir().unwrap();
    let reg = Registry::new(dir.path().to_path_buf());
    let mut rx = reg.subscribe();                       // broadcast::Receiver<WireMsg>
    reg.handle_emacs(EmacsIn::SessionOpen { session: "s".into(), title: "t".into() }).await.unwrap();
    reg.handle_emacs(EmacsIn::Msg { session: "s".into(), seq: 0, turn: 1,
        payload: Payload::AgentMessage { text: "hi".into() } }).await.unwrap();
    let msg = rx.recv().await.unwrap();                  // first broadcast is the Update
    match msg { WireMsg::Update(u) => assert_eq!(u.seq, 1), _ => panic!() }
    assert_eq!(reg.last_seq("s"), 1);                    // seq is authoritative from the log, not the provider
}
```

Key design point encoded here: the **sidecar** assigns `seq` from its replay log (the provider's `seq` field is advisory / ignored) so seq is monotonic even across provider reconnects.

- [ ] **Step 2: Implement `registry.rs`** — `Registry` holds `HashMap<SessionId, SessionEntry>` (each: `ReplayLog`, `title`, `state`, `current_turn`), a `tokio::sync::broadcast::Sender<WireMsg>`, and the base dir. `handle_emacs` matches `EmacsIn`: `SessionOpen` creates the entry + log; `Msg` appends → gets seq → broadcasts `WireMsg::Update`; `Status` updates state (idle→running bumps `current_turn`) + broadcasts `WireMsg::Status`; `Permission` broadcasts `WireMsg::PermissionReq`; `SessionClose` marks closed. Add `session_list()`, `last_seq()`, `read_since()`.

- [ ] **Step 3: Green; commit.**

- [ ] **Step 4: Failing test — unix socket server parses ndjson lines into the registry, and routes EmacsOut back**

```rust
#[tokio::test]
async fn emacs_socket_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("asb.sock");
    let reg = std::sync::Arc::new(Registry::new(dir.path().to_path_buf()));
    let (out_tx, out_rx) = tokio::sync::mpsc::channel(16);   // EmacsOut to send to the provider
    let srv = spawn_emacs_server(sock.clone(), reg.clone(), out_rx);

    // a fake Emacs client connects and writes a session-open + msg
    let mut cli = tokio::net::UnixStream::connect(&sock).await.unwrap();
    cli.write_all(b"{\"t\":\"session-open\",\"session\":\"s\",\"title\":\"t\"}\n").await.unwrap();
    cli.write_all(b"{\"t\":\"msg\",\"session\":\"s\",\"seq\":0,\"turn\":1,\"payload\":{\"type\":\"agent_message\",\"text\":\"hi\"}}\n").await.unwrap();
    // give it a tick, then assert the registry saw it
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert_eq!(reg.last_seq("s"), 1);

    // an EmacsOut inject must be written to the connected client as a line
    out_tx.send(EmacsOut::Inject { session: "s".into(), text: "go".into() }).await.unwrap();
    let line = read_one_line(&mut cli).await;
    assert!(line.contains("\"t\":\"inject\""));
    drop(srv);
}
```

- [ ] **Step 5: Implement `emacs_server.rs`** — bind `UnixListener` (unlink stale path first; `flock` a lockfile so only one daemon owns it), accept loop: per-connection task reads lines (`BufReader::lines`), `serde_json::from_str::<EmacsIn>` → `reg.handle_emacs`. Maintain a per-session → connection map so `EmacsOut` (from `out_rx`) is written to the socket that owns that session (the one that sent `SessionOpen`). Serialize `EmacsOut` as a JSON line.

- [ ] **Step 6: Green; commit** (`feat: sidecar Emacs unix-socket server`).

---

## Chunk 6: `asb-sidecar` — phone iroh server, presence, push trait

**Files:**
- Create: `crates/asb-sidecar/src/push.rs` (`PushSender` trait + `NoopPush`)
- Create: `crates/asb-sidecar/src/phone_server.rs` (iroh accept loop, per-client session)
- Create: `crates/asb-sidecar/src/presence.rs` (connected-client count)

- [ ] **Step 1: Implement `push.rs`**

```rust
#[async_trait::async_trait]
pub trait PushSender: Send + Sync {
    async fn wake(&self, token: &str, host_id: &str, session: &str, kind: &str);
}
pub struct NoopPush;
#[async_trait::async_trait]
impl PushSender for NoopPush { async fn wake(&self, _:&str,_:&str,_:&str,_:&str) {} }
```

(Add `async-trait` to the sidecar crate. A real `FcmPush` lands in the push plan; the trait is the seam.)

- [ ] **Step 2: Failing integration test — the walking skeleton, headless**

This is the plan's centerpiece. In one process: a `Registry`, the phone iroh server, and an in-test "phone" using `asb-protocol` client helpers, all on loopback.

```rust
#[tokio::test]
async fn phone_mirrors_and_injects() {
    // --- host/sidecar side ---
    let dir = tempfile::tempdir().unwrap();
    let host_id = Identity::load_or_create(&dir.path().join("host.json")).unwrap();
    let reg = Arc::new(Registry::new(dir.path().join("logs")));
    let roster = Arc::new(Mutex::new(Roster::load(&dir.path().join("roster.json")).unwrap()));
    let (out_tx, out_rx) = mpsc::channel(16);           // phone Input -> becomes EmacsOut
    let push = Arc::new(SpyPush::default());
    let host_ep = build_endpoint(host_id.secret_bytes()).await.unwrap();

    // --- phone side ---
    let phone_id = Identity::load_or_create(&dir.path().join("phone.json")).unwrap();
    let phone_ep = build_endpoint(phone_id.secret_bytes()).await.unwrap();

    // pair (reuse Chunk 4): phone joins host, both add roster entries
    // ... pair_host/pair_join on the PAIR_ALPN, then roster.add(...) on the host

    // run the phone server
    let _srv = spawn_phone_server(host_ep.clone(), reg.clone(), roster.clone(),
                                  out_tx.clone(), push.clone(), "host".into());

    // feed a scripted turn through the registry (as if from Emacs)
    reg.handle_emacs(EmacsIn::SessionOpen { session:"s".into(), title:"demo".into() }).await.unwrap();
    reg.handle_emacs(EmacsIn::Status { session:"s".into(), state: SessionState::Running }).await.unwrap();
    reg.handle_emacs(EmacsIn::Msg { session:"s".into(), seq:0, turn:1,
        payload: Payload::AgentMessage { text:"the answer is 42".into() } }).await.unwrap();

    // phone connects, hello, and must receive the update
    let mut client = PhoneClient::connect(&phone_ep, host_id.node_id_bytes()).await.unwrap();
    client.hello(None, Default::default()).await.unwrap();
    let got = client.next_update_timeout(Duration::from_secs(5)).await.unwrap();
    assert!(matches!(got.payload, Payload::AgentMessage { text } if text.contains("42")));

    // phone injects -> arrives as EmacsOut on out_rx
    client.input("s", "run it again").await.unwrap();
    let ev = timeout(Duration::from_secs(5), out_rx.recv()).await.unwrap().unwrap();
    assert!(matches!(ev, EmacsOut::Inject { text, .. } if text == "run it again"));
}
```

`PhoneClient` and `SpyPush` are test helpers; put `PhoneClient` in `asb-protocol` (`src/client.rs`) because the real Flutter core will use it too — it's the reusable phone-side session logic (connect, hello, catchup, stream `WireMsg`, send input/permission/command/interrupt over framed CBOR).

- [ ] **Step 3: Implement `phone_server.rs`** — accept loop on `ASB_ALPN`; reject `conn.remote_id()` not in roster; per-connection task: read the client `hello`, send `SessionList`, replay each session's `read_since(last_seq)`, then forward live `broadcast` `WireMsg`s; read inbound `WireMsg::{Input,PermissionRes,Command,Interrupt}` → translate to `EmacsOut` on `out_tx`; register/deregister in `presence`.

- [ ] **Step 4: Implement `client.rs` in `asb-protocol`** — `PhoneClient::connect(ep, host_node32)`, `hello`, `catchup`, `next_update`, `input`, `permission`, `command`, `interrupt`, all over `write_frame`/`read_frame` + ciborium of `WireMsg`.

- [ ] **Step 5: Run the centerpiece test green** (`nix develop -c cargo test -p asb-sidecar phone_mirrors_and_injects`). **This is the walking skeleton proven headlessly.**

- [ ] **Step 6: Failing test — push fires only when no client is connected**

```rust
#[tokio::test]
async fn push_on_turn_complete_when_no_client() {
    // no PhoneClient connected; roster has one client with an fcm token
    // feed Status running -> Msg -> Status idle (turn complete)
    // assert SpyPush recorded one wake(token, "host", "s", "turn_done")
}
```

Wire the presence check into the registry→push path (on `Status idle` or `Permission`, if `presence.connected() == 0`, call `push.wake` for each `roster.client_tokens()`).

- [ ] **Step 7: Green; commit** (`feat: phone iroh server + presence + push seam`).

---

## Chunk 7: `asb-sidecar` binary — daemon + pairing CLI

**Files:**
- Modify: `crates/asb-sidecar/src/main.rs`
- Create: `crates/asb-sidecar/src/cli.rs`

- [ ] **Step 1: `run` subcommand** — load identity + roster from a state dir (`$XDG_STATE_HOME/asb` or `~/.local/state/asb`), `flock` a lockfile (exit if another daemon holds it), bind the endpoint, spawn `emacs_server` + `phone_server`, install a Ctrl-C/SIGTERM handler that `endpoint.close().await`s, and an idle-exit timer (no Emacs connections AND no phone clients for N minutes → close + exit).

- [ ] **Step 2: `pair` subcommand** — generate a `PairingCode`, print it big + render a QR to the terminal (add `qrcode` crate; QR encodes `{host_node_id_hex, code}` so the phone can scan both), run `pair_host` once, `roster.add(entry)`, print "paired with <client>". (A running daemon should instead be signaled to enter pair mode; for v1 the `pair` subcommand can bind its own short-lived endpoint on `PAIR_ALPN` using the same identity — document the "stop the daemon before pairing, or pair via the daemon's control socket" choice; simplest v1: the daemon owns pairing via an Emacs-socket `EmacsIn::Pair`-style trigger or a `SIGUSR1`. Pick the socket-trigger; note it.)

- [ ] **Step 3: Manual verification** (documented, not automated):

```bash
# terminal 1
nix develop -c cargo run -p asb-sidecar -- run
# terminal 2
nix develop -c cargo run -p asb-sidecar -- pair     # shows code + QR
# then drive an integration harness that joins with the code and mirrors a scripted session
```

- [ ] **Step 4: Commit** (`feat: asb-sidecar daemon + pairing CLI`).

---

## Definition of done (Plan 1)

- `nix develop -c cargo test` green on squirtle (all unit + the `phone_mirrors_and_injects` + `push_on_turn_complete` integration tests).
- `asb-sidecar run` boots, `pair` completes a real PAKE handshake with a test joiner, and a rostered joiner mirrors a scripted session and injects back.
- No Emacs, no Flutter, no Android yet — those are **Plan 2** (`agent-shell-bridge-app.el` provider driving the unix socket) and **Plan 3** (Flutter UI + `flutter_rust_bridge` wrapping `asb-protocol`, built on charmander).

## Open follow-ups to carry into Plan 2/3

- Confirm the exact structured-message fields agent-shell's provider seam emits (map onto `Payload`) — cross-check `agent-shell-bridge.el`'s normalizer.
- QR payload format shared with the Flutter scanner.
- `presets::N0` relay reachability from a real phone on cellular (validate early in Plan 3).
- Whether `pair` runs in-daemon (socket-triggered) or standalone — decide when writing Plan 2's provider `pair` command.
