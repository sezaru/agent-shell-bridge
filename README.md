# agent-shell-bridge

Mirror an Emacs [`agent-shell`](https://github.com/xenodium/agent-shell)
session to a remote surface and drive the agent back from it. The provider
seam carries **structured** messages (role / parts / collapsible thinking /
tool-call breakdown / status), so each surface renders them its own way.

The provider shipped today is **Discord**, bot-only: a single bot token
drives both directions — it posts, edits and uploads out, and listens on the
Gateway websocket for messages and reactions in.

Each session opens one **forum post** (thread); every message threads under
it. Background work (thinking + tool calls) folds into one edited
"Thought, ran a command" subtext line, mirroring agent-shell's collapsed
header.

---

## Requirements

- Emacs 29+ with `agent-shell` working.
- The [`websocket`](https://github.com/ahyatt/emacs-websocket) package (for
  the inbound Gateway listener).
- `curl` on `PATH` (all REST calls shell out to it).

---

## 1. Create the Discord bot

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
   → **New Application**, name it (e.g. "Agent Shell"), **Create**.
2. Left sidebar → **Bot**. Under **Token**, click **Reset Token** and copy it.
   This is your `bot-token` — treat it as a password.
3. On the same **Bot** page, scroll to **Privileged Gateway Intents** and turn
   **Message Content Intent** **ON**, then **Save**. This is required — without
   it the gateway connects, sends HELLO, then closes, and inbound messages
   never arrive.

## 2. Invite the bot to your server

1. Left sidebar → **OAuth2** → **URL Generator**.
2. **Scopes:** check `bot`.
3. **Bot Permissions:** check
   - View Channel
   - Send Messages
   - Send Messages in Threads
   - Create Public Threads
   - Attach Files (for `/transcript`)
   - Add Reactions
   - Read Message History
4. Copy the generated URL, open it, pick your server, **Authorize**.

(Managing/deleting other people's messages is **not** needed — the bot only
reacts, it never edits or deletes user messages.)

## 3. Create the forum channel

1. In your server, create a **Forum** channel (not a text channel) — sessions
   need to open posts (threads), which only a forum channel allows.
2. Make sure the bot's role can see and post in it.

## 4. Collect the three IDs

Enable **Settings → Advanced → Developer Mode** in your Discord client, then
right-click → **Copy ID**:

| Variable                                   | Copy ID of…                     |
| ------------------------------------------ | ------------------------------- |
| `agent-shell-bridge-discord-channel-id`    | the **forum channel**           |
| `agent-shell-bridge-discord-guild-id`      | the **server** (guild)          |

(The `bot-token` is the one from step 1.)

---

## 5. Install and configure in Emacs

Install the package (all of the below assume `websocket` is also installed):

**Doom / straight:**

```elisp
;; packages.el
(package! websocket)
(package! agent-shell-bridge
  :recipe (:host github :repo "sezaru/agent-shell-bridge"))
```

**use-package + straight:**

```elisp
(use-package agent-shell-bridge
  :straight (:host github :repo "sezaru/agent-shell-bridge"))
```

Then configure and register the provider once `agent-shell` is loaded:

```elisp
(with-eval-after-load 'agent-shell
  (require 'agent-shell-bridge-discord-gateway)

  (setq agent-shell-bridge-discord-bot-token  "YOUR_BOT_TOKEN"
        agent-shell-bridge-discord-forum-p    t
        agent-shell-bridge-discord-channel-id "YOUR_FORUM_CHANNEL_ID"
        agent-shell-bridge-discord-guild-id   "YOUR_GUILD_ID")

  ;; Registers the hybrid provider and connects the bot listener.
  (agent-shell-bridge-discord-register)

  ;; Mirror every agent-shell buffer to Discord.
  (add-hook 'agent-shell-mode-hook #'agent-shell-bridge-mode))
```

> **Keep the token out of your dotfiles.** Read it from the environment,
> authinfo, or a secret manager rather than hard-coding it — it grants full
> control of the bot.

Restart Emacs (or re-eval the block) and start an `agent-shell` session. A new
forum post appears; the session mirrors into it.

---

## Using it

**Send a message** in the session's forum post and the bot injects it into
`agent-shell`, then reacts:

| Reaction | Meaning                                            |
| -------- | -------------------------------------------------- |
| ✅       | consumed — injected into the agent                 |
| ❌ + ⏳   | refused — the agent is busy                        |
| ❌ + 💤   | refused — offline backlog (typed while Emacs was closed) |
| ❌ + ❓   | refused — no session owns this post                |
| 💬       | handled as a command                               |
| 🛑       | handled as an interrupt                            |

The forum post's starter message carries a status reaction: **⚙️ running** /
**💤 idle**.

**Slash commands** (type them as a message):

| Command       | Effect                                                          |
| ------------- | -------------------------------------------------------------- |
| `/model`      | list available models (no arg) or switch to one (`/model <id-or-name>`) |
| `/thought`    | list or set the thinking level                                 |
| `/mode`       | list or set the session mode                                   |
| `/transcript` | attach the full session transcript as a file                   |
| `/interrupt`, `/stop` | interrupt the running turn                             |
| `/help`       | list the commands                                              |

Anything else starting with `/` (or plain text) is injected as a prompt.

**Control reactions** on the bot's messages:

| Reaction | Action    |
| -------- | --------- |
| ✅       | approve (e.g. a permission request) |
| ❌       | deny      |
| 👀       | expand    |
| 🔽       | collapse  |
| 📄       | full      |
| 🙈       | hide      |
| 🛑       | interrupt |

When the agent asks for permission, the bot posts the request and pre-adds
tappable ✅ / ❌ — tap one to allow or deny.

Sessions persist across Emacs restarts: on resume, the bridge re-links the
existing forum post (rather than opening a duplicate) and rejects any backlog
typed while it was closed.
