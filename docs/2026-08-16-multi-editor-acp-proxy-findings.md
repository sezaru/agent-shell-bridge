# Multi-editor support via an ACP proxy — findings (2026-08-16)

## Goal

Extend the bridge beyond Emacs `agent-shell` to other editors (Neovim, VS Code,
Zed, JetBrains) **without writing per-editor plugin code**. The premise of the
whole bridge is that the remote surface (Discord / the future app) and the editor
show **the same data** — including *user messages injected remotely*. If an
injected message can't render as real user text in the editor, that premise
collapses for that editor.

## Approach: a transparent ACP proxy on the agent's stdio

ACP is newline-delimited JSON-RPC 2.0 over stdio; the editor is the client, the
agent is the server. The editor's *only* integration point is "which agent
command to launch." So instead of hooking each editor's plugin, sit as a
transparent proxy in the agent's position:

```
editor (client) <--stdio--> [ proxy ] <--stdio--> agent (server)
                                 ^
                                 | control socket
                           inject (Discord / app / phone)
```

The proxy forwards every byte both ways (fully observable — the "mirror out"
half), tracks `sessionId` from `session/new`, and a control socket lets an
outside actor inject a turn (the "drive back" half). One proxy ⇒ every ACP
editor, zero per-editor code — *in principle*.

POC lives at `~/projects/acp-proxy-poc/` (Python stdlib, run via
`nix shell nixpkgs#python3`). `proxy.py` is the proxy; `inject.py` the control
client; `mock_*` a pure demo; `real_client.py`/`emacs-test/`/`nvim-test/` the
real-agent stages.

### Injection mechanism

- Fabricate a `session/prompt` to the agent using an id from the proxy's own
  range (**90000+**). **Consume** the agent's *response* to it (the editor never
  sent that request, so leaking the response would confuse it) while
  **forwarding** the id-less `session/update` *notifications* (so the editor
  renders the streamed turn). That split — consume the response, forward the
  notifications — is the core trick.
- For surfacing the injected **user message** (see below), the proxy also drives
  `session/push` (ids **95000+**) or emits a bare synthetic
  `user_message_chunk`, depending on what the editor supports.

## What was verified

**Stage 1 — proxy + real `claude-agent-acp`:** proxy is transparent to a real
agent; an out-of-band injected prompt makes the real Claude model reply. Real
message shapes (`messageId`, `usage_update`, UUID `sessionId`) pass through
untouched.

**Stage 2 — proxy + real `agent-shell`** (throwaway `-Q` Emacs, never the user's
instance): an injected turn renders in the buffer, and a subsequent *normal*
editor prompt completes a full round-trip — **no turn-state desync**.

## The user-message dealbreaker

A bare injected `session/prompt` shows only the **assistant reply**; the injected
*user* text is invisible, because:

- the editor draws user text **locally** from its own input box, and
- the agent emits **zero** `user_message_chunk` for a live turn
  (`claude-agent-acp`'s `--replay-user-messages` only replays on session
  resume/load, never on live turns).

A synthetic `user_message_chunk` on its own renders (in agent-shell) as an
**"Out of turn user_message_chunk — ACP server bug"** banner — there's no active
request to attach it to.

### The fix that works for agent-shell: `session/push`

`session/push` (agent-shell-experimental.el) is a **server-initiated** prompt
push — the ACP *multiplexing* primitive for surfacing one client's prompt to the
others:

1. proxy → editor: `session/push` request (puts agent-shell into push mode)
2. proxy → editor: `user_message_chunk` → renders as **clean user text**
3. proxy → agent: the real `session/prompt`; its reply streams to the editor
   under the active push
4. on the agent's `stopReason`: proxy → editor `session_push_end`; the editor
   responds to the push request (proxy consumes it) and returns to idle

**Verified** in the `-Q` harness (`emacs-test/run-push-test.el`) — the buffer
reads identically to a native session (injected message is a real `Claude> …`
user prompt, assistant replies, subsequent normal prompt round-trips).

## Per-editor results

| Editor | Client | Injected assistant reply | Injected **user** message | Mechanism |
| --- | --- | --- | --- | --- |
| **Emacs agent-shell** | native | ✅ | ✅ | `session/push` (`proxy.py --push`) — implemented |
| **Neovim** | `agentic.nvim` | ✅ | ❌ | none available |
| **VS Code** | `formulahendry/vscode-acp` | ✅ | ✅ | bare `user_message_chunk` (`--echo-user`) |

### Neovim — `agentic.nvim` (negative)

Tested headless against real `claude-agent-acp` via the `--echo-user` proxy
(`nvim-test/harness.lua`). The injected **assistant reply renders, but the
injected user message does not**:

- `session_manager.lua:355` renders `user_message_chunk` only
  `if self._is_restoring_session`, and that flag is set true **only** inside its
  own `session/load` restore flow (line 1088) — same design as agent-shell.
- `acp_client.lua:334` incoming-request handlers cover only `session/update`,
  `session/request_permission`, `fs/read_text_file`, `fs/write_text_file` — **no
  `session/push`**.

So the dealbreaker **recurs** for nvim. The proxy can show injected user messages
cleanly only where the editor implements a server-push/multiplex mechanism —
today that's essentially just agent-shell.

### VS Code — `formulahendry/vscode-acp` (positive, but fragile)

Source review of the credible client (354★, community, active; **no** official
VS Code ACP client exists — Microsoft's own multi-agent work is a *different*
protocol, "Agent Host Protocol"):

- `ChatWebviewProvider.ts:2424` handles `user_message_chunk` **unconditionally**
  for the active session: `finalizeCurrentAssistantTurn()` then
  `addMessage('user', text)` — **no restore/load guard**. So the bare
  `--echo-user` message that failed in nvim and banner-ed in agent-shell would
  render here as **clean user text**, and it doesn't even need `session/push`.
- `session/push` is implemented **nowhere** in the extension (and isn't
  standardized).

Caveats: (a) it relies on an *unenforced assumption* — the code even comments
that "only session/load replay emits this," they just don't gate it, so an
upstream tightening would break us; (b) the extension self-draws local input, so
injecting *during the user's own turn* could double-render (same busy-guard
concern we already have); (c) **not runtime-verified** — VS Code renders into a
webview that can't be asserted on headlessly, so this verdict is source-level
only.

## Protocol status

Live cross-client user-message injection is **not standardized**. `session/push`
is experimental (agent-shell only). The relevant standardization efforts:

- **ACP multiplexing RFD #533** — the protocol's own take on surfacing one
  client's prompt to others.
- **proxy-chains RFD** (agentclientprotocol.com/rfds/proxy-chains).
- Prior art: **`acp-multiplex`** (ElleNajt) — an unofficial ACP multiplexer, the
  same bet; worth studying how it handles the user-echo problem.

## Bottom line

The ACP proxy is a genuinely good **mirror + remote-control** layer for any ACP
editor. But "**both surfaces show identical data, including user messages**" is,
today, only fully achievable on:

- **agent-shell** — via `session/push` (which we already have natively, so the
  proxy adds nothing there);
- **VS Code** — via a bare `user_message_chunk`, but on a fragile unenforced
  assumption and unverified at runtime.

For **Neovim** (and any editor that gates `user_message_chunk` to restore and
lacks `session/push`) the dealbreaker recurs. Making it truly universal means
either upstreaming per-editor changes (defeats the editor-agnostic appeal) or the
ecosystem adopting the multiplexing extension.

**Implication for the app:** the multi-editor story is **not** a solved
transport we can lean on yet. The near-term, reliable surface is still
agent-shell (native inject, no proxy needed). The proxy is a promising but
partial direction — park it as an experiment, keep the provider seam
editor-agnostic, and don't block the app on it.
