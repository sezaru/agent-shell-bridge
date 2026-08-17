# asb-app Emacs Provider Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. TDD, one behaviour per step, commit per task.

**Goal:** An `agent-shell-bridge` provider — `agent-shell-bridge-app.el` — that mirrors sessions to the `asb-sidecar` daemon over its unix socket and drives them back, so the phone app (Plan 3) becomes a first-class remote surface alongside Discord.

**Architecture:** The provider is a struct of function slots (see `agent-shell-bridge-provider.el`). It opens ONE `make-network-process` unix-socket client to the sidecar (`$XDG_RUNTIME_DIR/asb.sock`), lazily. Outbound: each structured bridge message → one `EmacsIn` ndjson line (`session-open` / `msg` / `status` / `permission` / `session-close`). Inbound: the socket filter splits ndjson `EmacsOut` lines and fans them into the core's `on-inbound` / `on-control` callbacks. It is a **non-editing** provider (`can-edit nil`): the core buffers streaming chunks and hands us one complete message per unit (agent answer, thought, each tool call, permission), which is exactly the granularity the sidecar's append-only `Update` log wants — no wire-level edits.

**Tech Stack:** Emacs Lisp, ERT (batch), `json.el` (built-in), the Rust `asb-protocol` wire contract (`crates/asb-protocol/src/emacs.rs` in `~/projects/asb-app`).

---

## Wire contract (from `asb-protocol::emacs`, ndjson, one JSON object per line)

Provider → sidecar (`EmacsIn`, tag key `"t"`, kebab-case):
- `{"t":"session-open","session":ID,"title":STR}`
- `{"t":"msg","session":ID,"seq":0,"turn":0,"payload":{...}}` — `seq`/`turn` are placeholders; the sidecar reassigns them.
- `{"t":"status","session":ID,"state":"running"|"idle"}`
- `{"t":"permission","session":ID,"id":STR,"command":STR,"options":[{"id":STR,"label":STR}]}`
- `{"t":"session-close","session":ID}`

Sidecar → provider (`EmacsOut`, tag key `"t"`):
- `{"t":"inject","session":ID,"text":STR}`
- `{"t":"command","session":ID,"name":STR,"arg":STR|null}`
- `{"t":"permission-response","session":ID,"id":STR,"option":STR}`
- `{"t":"interrupt","session":ID}`

`payload` (from `asb-protocol::model::Payload`, tag key `"type"`, snake_case):
- `{"type":"agent_message","text":STR}`
- `{"type":"thought","text":STR}`
- `{"type":"user_message","text":STR}`
- `{"type":"tool_call","id":STR,"kind":"read|edit|command|search|fetch|other","title":STR,"command":STR|null,"status":"pending|running|done|failed","content":[CONTENT...],"locations":[STR...]}`
- `{"type":"tool_call_update","id":STR,"status":"pending|running|done|failed","content":[CONTENT...]}`

`CONTENT` (tag key `"kind"`): `{"kind":"text","text":STR}` | `{"kind":"diff","path":STR,"diff":STR}` | `{"kind":"file_ref","path":STR}`.

### Mapping rules

**Structured message → payload** (a bridge message is `(:id :role :status :collapsible :parts :session)`; each part is `(:kind :content :meta)`):

| role | status | → payload |
|------|--------|-----------|
| `agent`  | any | `agent_message` (text = concatenated part text) |
| `thinking` | any | `thought` |
| `user`   | any | `user_message` |
| `system` | any | `agent_message` (no System payload; fold into agent text) |
| `tool`   | `pending` | `tool_call` (from the `tool-call` part's `:meta`) |
| `tool`   | `success`/`error`/`streaming` | `tool_call_update` (`status` = `done`/`failed`/`running`) |
| `permission` | — | NOT a `msg`; emit `EmacsIn::permission` instead (see below) |

`tool_call` fields come from the part `:meta` built by `agent-shell-bridge--normalize-update`: `:tool-call-id`→`id`, `:kind`→`kind` (map ACP kind string → our enum, default `other`), `:title`→`title`, `:command`→`command`, `:content`→`content`. The part `:content` string, when non-empty, becomes one `{"kind":"text","text":…}`.

**Permission message → `EmacsIn::permission`:** the permission bridge message carries `:parts[0] :meta (:options ACP-OPTIONS :request-id ID)` and `:content` = the command/title string. `send` must:
1. mint a stable `remote-id` (a string, our monotonic counter) — this is what the core stores in `pending-permissions` and what the phone echoes back;
2. build `options` by classifying each ACP option's `kind` into a **semantic id** — `allow`/`accept`/`allow_once`→`"approve"`, `always*`→`"always"`, `reject`/`deny*`→`"deny"` (mirror of `agent-shell-bridge--find-option-id`), `label` = the ACP option `name`/`optionId`; dedupe by semantic id;
3. emit `{"t":"permission","session":handle,"id":remote-id,"command":…,"options":…}`;
4. return `remote-id`.

**Inbound `EmacsOut` → core callbacks:**
- `inject`  → `on-inbound (:text text :session handle)`
- `command` → `on-inbound (:text "/NAME[ ARG]" :session handle)` (reuse the core's slash-command parser; no separate control path)
- `permission-response` → `on-control (:action (intern option) :target id :session handle)` — `option` is already the semantic id (`approve`/`deny`/`always`); `handle-control` maps `approve`/`deny` (treat `always` as `approve`) to the ACP option kind.
- `interrupt` → `on-control (:action interrupt :session handle)`

> Note: `handle-control` only understands `approve`/`deny`/`interrupt`. Map incoming `always` → `approve` before interning (v1: always-allow degrades to allow-once). Record as a follow-up to thread `always` through the core.

---

## File Structure

- Create: `agent-shell-bridge-app.el` — the provider (socket lifecycle, encode, decode, provider struct, `-register`).
- Create: `test/agent-shell-bridge-app-test.el` — ERT: encode mapping (pure), decode/dispatch (pure, via injected callbacks), and a live loopback against a stub socket server.
- Modify: `README.md` — a short "App provider" section (after the plan lands & is green).

Run tests with:
```sh
emacs -Q -batch -L . -L test -l ert \
  -l test/agent-shell-bridge-app-test.el -f ert-run-tests-batch-and-exit
```

---

## Task 1: Payload encoding (pure)

**Files:** Create `agent-shell-bridge-app.el`; Test `test/agent-shell-bridge-app-test.el`.

- [ ] **Step 1: Failing test — agent/thinking/user/tool encode.**

```elisp
(require 'ert)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-app)

(ert-deftest asb-app-encode-agent ()
  (let ((p (agent-shell-bridge-app--payload
            (agent-shell-bridge-make-message
             :role 'agent :status 'complete
             :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))))
    (should (equal (alist-get 'type p) "agent_message"))
    (should (equal (alist-get 'text p) "hi"))))

(ert-deftest asb-app-encode-thinking ()
  (let ((p (agent-shell-bridge-app--payload
            (agent-shell-bridge-make-message :role 'thinking :status 'streaming
             :parts (list (agent-shell-bridge-make-part :kind 'text :content "hmm"))))))
    (should (equal (alist-get 'type p) "thought"))))

(ert-deftest asb-app-encode-tool-call ()
  (let* ((m (agent-shell-bridge-make-message
             :id "t1" :role 'tool :status 'pending
             :parts (list (agent-shell-bridge-make-part
                           :kind 'tool-call :content "cargo test"
                           :meta (list :tool-call-id "t1" :title "run tests"
                                       :kind "execute" :command "cargo test")))))
         (p (agent-shell-bridge-app--payload m)))
    (should (equal (alist-get 'type p) "tool_call"))
    (should (equal (alist-get 'id p) "t1"))
    (should (equal (alist-get 'command p) "cargo test"))
    (should (equal (alist-get 'status p) "pending"))))

(ert-deftest asb-app-encode-tool-update-failed ()
  (let* ((m (agent-shell-bridge-make-message
             :id "t1" :role 'tool :status 'error
             :parts (list (agent-shell-bridge-make-part
                           :kind 'tool-call :content "boom"
                           :meta (list :tool-call-id "t1" :status "failed")))))
         (p (agent-shell-bridge-app--payload m)))
    (should (equal (alist-get 'type p) "tool_call_update"))
    (should (equal (alist-get 'status p) "failed"))))
```

- [ ] **Step 2: Run — expect FAIL (function void).**
- [ ] **Step 3: Implement `agent-shell-bridge-app--payload`** — dispatch on role; helpers `--tool-kind` (ACP kind string → `"read"/"edit"/"command"/"search"/"fetch"/"other"`) and `--tool-status` (`success`→`done`, `error`→`failed`, else `running`; pending stays `pending` on `tool_call`). Content vector via `--encode-content` (text part → `{kind:text,text:…}`, skip empty). Emit alists that `json-encode` renders correctly (use `(cons 'type "…")`).
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** (`feat(app): structured-message → asb payload encoder`).

## Task 2: Line encoding & permission mapping (pure)

- [ ] **Step 1: Failing tests** — `agent-shell-bridge-app--line` for `session-open`/`status`; and `--permission-line` classifying ACP options into semantic ids + returning a fresh remote-id.

```elisp
(ert-deftest asb-app-status-line ()
  (should (equal (json-read-from-string
                  (agent-shell-bridge-app--line
                   (list (cons 't "status") (cons 'session "s") (cons 'state "running"))))
                 '((t . "status") (session . "s") (state . "running")))))

(ert-deftest asb-app-permission-options-semantic ()
  (let* ((opts (vector '((optionId . "a") (kind . "allow_once") (name . "Allow"))
                       '((optionId . "d") (kind . "reject_once") (name . "Deny"))))
         (m (agent-shell-bridge-make-message
             :role 'permission :status 'pending
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content "rm -rf /"
                           :meta (list :options opts :request-id 7)))))
         (rid "9")
         (obj (agent-shell-bridge-app--permission-object m rid)))
    (should (equal (alist-get 'id obj) "9"))
    (should (equal (alist-get 'command obj) "rm -rf /"))
    (should (member '((id . "approve") (label . "Allow"))
                    (append (alist-get 'options obj) nil)))
    (should (member '((id . "deny") (label . "Deny"))
                    (append (alist-get 'options obj) nil)))))
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** `agent-shell-bridge-app--line` (`json-encode` + `"\n"`) and `agent-shell-bridge-app--permission-object` (classify + dedupe by semantic id). Reuse the kind lists from the mapping table.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** (`feat(app): line encoder + semantic permission mapping`).

## Task 3: Inbound decode → callbacks (pure)

- [ ] **Step 1: Failing test** — feed raw `EmacsOut` alists to `agent-shell-bridge-app--handle` with captured callbacks.

```elisp
(ert-deftest asb-app-inbound-inject ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "inject") (session . "s") (text . "go"))
     (lambda (ev) (setq got ev)) #'ignore)
    (should (equal (plist-get got :text) "go"))
    (should (equal (plist-get got :session) "s"))))

(ert-deftest asb-app-inbound-command-becomes-slash ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "command") (session . "s") (name . "model") (arg . "opus"))
     (lambda (ev) (setq got ev)) #'ignore)
    (should (equal (plist-get got :text) "/model opus"))))

(ert-deftest asb-app-inbound-permission-response ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "permission-response") (session . "s") (id . "9") (option . "approve"))
     #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'approve))
    (should (equal (plist-get got :target) "9"))))

(ert-deftest asb-app-inbound-always-degrades-to-approve ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "permission-response") (session . "s") (id . "9") (option . "always"))
     #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'approve))))

(ert-deftest asb-app-inbound-interrupt ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "interrupt") (session . "s"))
     #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'interrupt))))
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** `agent-shell-bridge-app--handle (obj inbound control)` — `pcase` on `(alist-get 't obj)`; `command` → `"/NAME"` plus `" ARG"` when arg non-null/non-empty; `permission-response` → intern option, `always`→`approve`; `null`-safe `arg`.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** (`feat(app): inbound EmacsOut → core callbacks`).

## Task 4: Socket lifecycle + framing (loopback)

- [ ] **Step 1: Failing test** — stand up a stub unix-socket server with `make-network-process :server t :family 'local`, point the provider at it, drive a session, assert the server received the right ndjson, then have the server send an `inject` line and assert the inbound callback fired. Split-frame test: deliver a line in two chunks and assert one decode.

```elisp
(ert-deftest asb-app-loopback-send-and-receive ()
  (let* ((sock (make-temp-name (expand-file-name "asb-test-" temporary-file-directory)))
         (lines nil) (server nil) (client-conn nil)
         (agent-shell-bridge-app-socket sock))
    (setq server
          (make-network-process
           :name "asb-stub" :server t :family 'local :service sock
           :filter (lambda (proc chunk)
                     (setq client-conn proc)
                     (dolist (l (split-string chunk "\n" t))
                       (push (json-read-from-string l) lines)))))
    (unwind-protect
        (progn
          (agent-shell-bridge-app--send-emacs-in
           (list (cons 't "session-open") (cons 'session "s") (cons 'title "demo")))
          (accept-process-output nil 0.3)
          (should (assoc 'session (car (last lines))))
          ;; server -> client inbound
          (let (got)
            (setq agent-shell-bridge-app--inbound-cb (lambda (ev) (setq got ev)))
            (process-send-string client-conn "{\"t\":\"inject\",\"session\":\"s\",\"text\":\"go\"}\n")
            (accept-process-output nil 0.3)
            (should (equal (plist-get got :text) "go"))))
      (ignore-errors (delete-process server))
      (agent-shell-bridge-app--disconnect)
      (ignore-errors (delete-file sock)))))
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** the socket layer:
  - `defcustom agent-shell-bridge-app-socket` (default `$XDG_RUNTIME_DIR/asb.sock`, else `~/.local/state/asb/asb.sock`).
  - `--ensure-proc` — reuse a live process; else `make-network-process :family 'local :service socket :coding 'utf-8-unix :filter #'--filter :sentinel #'--sentinel :nowait nil`; on failure log + return nil (mirroring degrades gracefully, never throws into agent-shell).
  - `--send-emacs-in (obj)` — `--ensure-proc`, then `process-send-string` the encoded line; swallow errors.
  - `--filter (proc chunk)` — append to `--rx`, split complete lines on `\n`, `json-read-from-string` each (tolerate malformed → log+skip), `--handle` with the stored callbacks.
  - `--sentinel` — on close, clear `--proc` so the next send reconnects.
  - `--disconnect` — delete process, clear state (for tests + `stop`).
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** (`feat(app): unix-socket lifecycle + ndjson framing`).

## Task 5: Provider struct + registration (loopback, end-to-end)

- [ ] **Step 1: Failing test** — build the provider via `agent-shell-bridge-app-provider`, register+select it, call `start-session`/`send`/`set-status` and assert the stub server sees `session-open`, a `msg` with the right payload, and a `status`. Then feed a permission message through `send` and assert a `permission` line with semantic options and that `send` returned the remote-id.

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement:**
  - `agent-shell-bridge-app--counter` for remote-ids and session fallbacks.
  - `--start-session (meta)` → handle = `(or (agent-shell-bridge--session-id) (format "%d-%d" (emacs-pid) (cl-incf counter)))`; send `session-open` titled `(plist-get meta :title)`; return handle. (Global uniqueness across Emacs instances sharing one sidecar: ACP UUID when available, pid+counter otherwise.)
  - `--send (message)` → if role `permission`: mint remote-id, `--send-emacs-in` the permission object, return remote-id. Else: `--send-emacs-in` a `msg` with `session` = message `:session` (fall back to the buffer handle), `seq` 0, `turn` 0, `payload` = `--payload`; return a fresh local id (so the core's edit/delete correlation has a value; unused by a non-editing provider).
  - `--edit`, `--delete` → no-ops (append-only wire; the core never calls them for a non-editing provider, but define them safe).
  - `--set-status (handle running)` → `status` line `running`/`idle`.
  - `--on-inbound`/`--on-control` → store the callbacks (used by `--filter`).
  - `--stop` → `session-close` for known handles (optional) + `--disconnect`.
  - `agent-shell-bridge-app-provider` builds the struct with `:can-edit nil`.
  - `;;;###autoload agent-shell-bridge-app-register` → register + `set-provider 'app`.
- [ ] **Step 4: Run — PASS. Run the whole file — all green.**
- [ ] **Step 5: Commit** (`feat(app): provider struct + registration`).

## Task 6: Docs

- [ ] **Step 1:** Add an "App provider (`asb-sidecar`)" section to `README.md`: what it is, `M-x agent-shell-bridge-app-register`, that it needs the sidecar running (`asb-sidecar run`), the socket path defcustom, and the v1 `always`→`approve` degrade. Commit (`docs: app provider`).

---

## Definition of done (Plan 2)

- `agent-shell-bridge-app.el` loads clean (`-batch` byte-compile: no errors).
- All ERT tests in `test/agent-shell-bridge-app-test.el` pass, plus the existing suites still pass.
- Loopback proves: session-open + msg (agent/thought/tool) + status + permission go out as correct ndjson; inject/command/permission-response/interrupt come back into the right callbacks; split frames decode once.
- NOT covered here (needs the real daemon + a phone): an end-to-end run against a live `asb-sidecar` with a real agent-shell turn. That's the Plan 3 integration milestone. Do not claim the loop is proven end-to-end until that runs.
