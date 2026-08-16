# agent-shell-bridge Implementation Plan

> **For agentic workers:** Phases 0–2 are executable now (Emacs Lisp, TDD with ERT). Phases 3–5 are roadmap-level and each needs its own detailed plan before execution — do NOT treat their sub-bullets as bite-sized steps. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A transport-agnostic bridge that mirrors an agent-shell session to a remote surface and lets you drive the agent back from it — shipping Discord first, and a bespoke end-to-end-encrypted app (roam/iroh) second, over the same seam.

**Architecture:** Harvest the transport-agnostic half of `ElleNajt/agent-shell-to-go` (agent-shell capture, streaming accumulator, permission model, 3-state formatting) and put every remote interaction behind a **provider protocol**. The core emits *structured* messages (role / parts / collapsible thinking / tool-call breakdown / status); each provider decides how faithfully to render them. Discord flattens to text+truncation+reactions; the own-app provider passes structure through untouched so a purpose-built client renders it exactly like agent-shell does.

**Tech Stack:** Emacs Lisp (`agent-shell`, `websocket`, ERT) for the bridge + providers; Rust (`roam-transport-iroh`, `roam-pake`, roster) for the own-app companion; a mobile/web client + FCM for push (later phases).

---

## Why this shape (decisions locked in conversation)

- **Discord/Telegram can't render agent-shell's structure** (collapsed thinking, tool-call parts). A bespoke app can. So the seam must carry structure, not flattened strings — this is the load-bearing decision.
- **Fork to harvest, not to preserve.** Keep the agent-shell integration + formatting logic (expensive, already correct); throw away all Slack transport. Source of truth for what to harvest: `~/projects/agent-shell-to-go/agent-shell-to-go.el` (2,618 lines).
- **Discord is free, feature-complete** (threads, reactions, edits, uploads), and has mobile push out of the box. It's provider #1.
- **Own app is the long game:** E2E (agent transcripts never touch a vendor), no rate/length limits, native rendering, and **monetizable** (ads, public release). It reuses roam's `roam-transport-iroh` + `roam-pake` (SPAKE2 pairing) + signed roster for device auth — NOT the CRDT/file-sync/RBSR machinery. Transcript-as-Loro-doc is an optional later refinement, not v1.
- **Push for the own app:** a pure iroh mesh cannot wake a backgrounded phone. Solution: when a client joins the roster it registers its **FCM token** in the pairing/roster handshake; the Emacs side (or companion) sends an FCM push on `new-message` / `turn-complete`. FCM is the wake path; iroh is the data path.

---

## File / component structure

**Emacs bridge (new package, harvested from the fork):**
- `agent-shell-bridge.el` — core: agent-shell capture (advice + `agent-shell-subscribe-to`), the structured message model, session lifecycle, dispatch to the active provider.
- `agent-shell-bridge-provider.el` — the provider protocol (`cl-defstruct` of function slots) + registration/selection, mirroring the `agent-shell-notifications` pluggable-provider pattern.
- `agent-shell-bridge-echo.el` — a log/echo provider (renders to a buffer) used by tests and as the reference implementation.
- `agent-shell-bridge-discord.el` — Discord provider (webhook push → gateway bot two-way).
- `test/` — ERT tests for the message model, provider dispatch, and each provider's flattening.

**Own-app companion (later, separate repo/crate):**
- A Rust binary using iroh (custom ALPN) + `roam-pake` + roster; local socket bridge to Emacs; the wire protocol; FCM sender.
- A mobile/web client rendering the structured message model natively.

---

## The provider protocol (the crux — design it once, right)

A provider is a struct of function slots. All messages crossing the seam are **structured**, never pre-flattened:

```
message := {
  :id            local correlation id
  :role          agent | user | tool | thinking | permission | system
  :status        streaming | complete | success | error | pending
  :collapsible   bool          ; e.g. thinking blocks default-collapsed
  :parts         list of { :kind text|code|diff|tool-call|image, :content, :meta }
  :session       session-handle
}
```

Provider slots:
- `start-session(session-meta) -> session-handle`   ; Discord: create/find thread; app: open channel to paired devices
- `send(session-handle, message) -> remote-msg-id`
- `edit(remote-msg-id, message)`                     ; Discord: chat edit; push-only providers: no-op
- `delete(remote-msg-id)`
- `on-inbound(callback)`                             ; callback gets {text, session-handle} -> inject into shell
- `on-control(callback)`                             ; callback gets {action, target-remote-msg-id, session}
- `stop()`

`action` vocabulary (transport-neutral): `approve` | `deny` | `expand` | `collapse` | `full` | `hide` | `interrupt`. Discord maps reactions→actions; the app maps buttons→actions. The core never knows about emoji.

---

## Chunk 0: Provider seam + echo provider

### Task 0.1: Vendor the harvest and stand up the package skeleton

**Files:**
- Create: `agent-shell-bridge.el`, `agent-shell-bridge-provider.el`, `agent-shell-bridge-echo.el`
- Reference (read-only, do not ship): `~/projects/agent-shell-to-go/agent-shell-to-go.el`

- [ ] **Step 1:** Copy the agent-shell capture layer from the fork (the `advice-add` block around lines 2103–2111 and `--on-notification`, `--on-request`, streaming accumulator) into `agent-shell-bridge.el`, stripping every Slack reference. Keep the structure; replace all sends with a single call to the active provider.
- [ ] **Step 2:** Define the provider `cl-defstruct` (slots above) in `agent-shell-bridge-provider.el` plus `agent-shell-bridge-register-provider` / `agent-shell-bridge-set-provider`.
- [ ] **Step 3:** Commit.

### Task 0.2: Structured message model (TDD)

**Files:** `agent-shell-bridge.el`, `test/agent-shell-bridge-test.el`

- [ ] **Step 1: Write the failing test** — feed a captured agent-shell notification (thinking chunk + a tool call + final text) into the normalizer; assert it produces a `message` with the right `:role`, `:collapsible` on the thinking part, and a `tool-call` part with status.
- [ ] **Step 2:** Run ERT, verify it fails.
- [ ] **Step 3:** Implement `agent-shell-bridge--normalize-update` mapping agent-shell notification payloads → the structured `message`.
- [ ] **Step 4:** Run ERT, verify pass.
- [ ] **Step 5:** Commit.

### Task 0.3: Echo provider + end-to-end dispatch (TDD)

**Files:** `agent-shell-bridge-echo.el`, `test/agent-shell-bridge-test.el`

- [ ] **Step 1: Write the failing test** — set the echo provider, run a fake session, assert the echo buffer contains one line per structured message with role/status rendered.
- [ ] **Step 2:** Run, fail.
- [ ] **Step 3:** Implement the echo provider (all slots; `send` appends to a buffer, `edit` replaces in place, `on-inbound`/`on-control` are manually fired in tests).
- [ ] **Step 4:** Run, pass.
- [ ] **Step 5:** Commit.

---

## Chunk 1: Discord provider — read-only push (webhook)

Delivers "agent output mirrored to Discord with mobile push" — the notification use case — with zero bot/gateway/intents. One HTTPS POST.

### Task 1.1: Discord webhook `send` (TDD)

**Files:** `agent-shell-bridge-discord.el`, `test/agent-shell-bridge-discord-test.el`

- [ ] **Step 1: Write the failing test** — call the flattener on a structured message with a collapsed thinking part + a 3k-char tool output; assert output is ≤2000 chars, thinking rendered collapsed, overflow marked for truncation.
- [ ] **Step 2:** Run, fail.
- [ ] **Step 3:** Implement `--discord-flatten` (port the truncation/3-state logic from the fork, but as a *provider* concern) and `send` via `call-process curl` POST to a configured webhook URL. `edit`/`delete`/`on-inbound`/`on-control` are no-ops in the webhook variant.
- [ ] **Step 4:** Run, pass.
- [ ] **Step 5:** Commit.

### Task 1.2: Wire it up + manual verify

- [ ] Add `use-package!`/config to select the Discord webhook provider; set the webhook URL via a defcustom (read from an env/authinfo, never hard-coded).
- [ ] **Manual verify:** run a real agent-shell turn; confirm the transcript appears in the Discord channel and the phone gets a push. Note the 2000-char behavior.
- [ ] Commit.

---

## Chunk 2: Discord provider — two-way (gateway bot)

Adds receive + controls: full parity with the original Slack tool.

### Task 2.1: Gateway connection (websocket)

- [ ] Implement the Discord Gateway client over `websocket.el`: IDENTIFY (with **Message Content** intent), HEARTBEAT loop, RESUME on reconnect. Reference the fork's Socket Mode code (`--get-websocket-url`, `--handle-websocket-message`) for shape only — the opcodes differ.
- [ ] Test the heartbeat/opcode framing with a recorded fixture (no live network in ERT).
- [ ] Commit.

### Task 2.2: Inbound message → inject

- [ ] On `MESSAGE_CREATE` in a session thread (and not from the bot itself), call the core's inject path (harvested `--inject-message`) to feed it into the agent-shell buffer.
- [ ] Commit.

### Task 2.3: Reactions → control actions

- [ ] Map `MESSAGE_REACTION_ADD`/`REMOVE` emoji → the transport-neutral `action` vocabulary; route to the core's permission/expand/hide handlers. Implement `edit`/`delete` via the bot REST API so 3-state expansion and header updates work.
- [ ] Manual verify: approve a permission via reaction; expand a truncated output; reply from Discord and see it run in Emacs.
- [ ] Commit.

**End of Phase 2: Discord parity achieved. This is a shippable, useful tool on its own.**

---

## Phase 3 (roadmap): Own-app companion over roam/iroh

> Needs its own detailed plan. Deliverable: a paired mobile/web client can receive structured messages and send prompts/approvals, E2E, no third party.

- Rust companion binary: iroh `Endpoint` + a custom ALPN for the control channel; reuse `roam-pake` (SPAKE2 six-digit pairing) and the signed **roster** for "only my paired devices." Do **not** pull in `roam-crdt`/`roam-files`/`roam-rbsr` for v1 — a message/RPC channel, not document sync.
- Define the wire protocol = the structured message model above, serialized (CBOR/JSON), plus control ops. This is deliberately the same shape as the Emacs provider seam so the app is "just another provider."
- Emacs ↔ companion bridge: a local socket; add `agent-shell-bridge-roam.el` provider that talks to the companion instead of to Discord.
- Open question to resolve in that plan: transcript as a live Loro text doc (offline reading, history, merge) vs. a plain streamed message log. Loro is the elegant fit but more work; defer unless offline reading is a v1 requirement.

## Phase 4 (roadmap): Mobile/web client + FCM push

> Needs its own detailed plan. Deliverable: an installable client that renders agent-shell-faithfully and wakes the phone.

- Client renders the structured model natively: collapsible thinking, tool-call breakdown, streaming, inline permission **buttons** (mapping to `approve`/`deny`), diffs.
- **Push:** on join, the client registers its **FCM token** into the roster/pairing handshake. The Emacs side (or companion) fires an FCM push on `turn-complete` and on new agent messages while the app is backgrounded. iroh carries the payload once the app is foregrounded; FCM only carries the wake + a short preview.
- Starting point for the web variant: roam's `roam-wasm` browser façade (relay leaf).

## Phase 5 (roadmap): Monetization & release

> Business/packaging, not covered by an implementation plan here.

- Ads in the free tier; publish to app stores for third-party users.
- Implication for earlier phases: keep the companion/protocol and the client generic and account-scoped (roster = a user's devices), so a public release doesn't require re-architecting. No third-party user's data should ever transit your infrastructure in plaintext — the E2E property is also the selling point.

---

## Notes & risks

- **Message Content Intent** (Discord) is a privileged intent — toggle on in the dev portal; free under 100 servers.
- **Discord 2000-char cap** is tighter than Slack's ~4000; the 3-state truncation matters more, not less.
- **Fork licensing:** `agent-shell-to-go` is GPL (check `LICENSE`); a harvested derivative inherits that. Fine for the Emacs package; the Rust companion/app are separate works but keep the boundary clean.
- **The seam is the investment.** Everything downstream (Discord now, roam app later, even a hypothetical Telegram provider) plugs into Chunk 0. Get the structured message model right there and the rest is providers.
