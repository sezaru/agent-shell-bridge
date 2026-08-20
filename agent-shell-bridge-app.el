;;; agent-shell-bridge-app.el --- asb-sidecar provider for the bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A provider that mirrors sessions to the `asb-sidecar' daemon over its
;; unix socket ($XDG_RUNTIME_DIR/asb.sock) and drives them back, so the
;; phone app becomes a first-class remote surface beside Discord.
;;
;; Non-editing provider: the core buffers streaming chunks and hands us
;; one complete message per unit (answer, thought, each tool call,
;; permission), which is the granularity the sidecar's append-only
;; `Update' log wants -- no wire-level edits.  Every outbound message is
;; one `EmacsIn' ndjson line; the socket filter fans inbound `EmacsOut'
;; lines into the core's `on-inbound'/`on-control' callbacks.  Wire
;; contract: `asb-protocol::{emacs,model}' in ~/projects/asb-app.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-provider)

(defcustom agent-shell-bridge-app-socket
  (let ((rt (getenv "XDG_RUNTIME_DIR")))
    (if rt (expand-file-name "asb.sock" rt)
      (expand-file-name "~/.local/state/asb/asb.sock")))
  "Path to the `asb-sidecar' unix socket."
  :type 'file
  :group 'agent-shell-bridge)

(defcustom agent-shell-bridge-app-binary
  (or (executable-find "asb-sidecar") "asb-sidecar")
  "The `asb-sidecar' binary Emacs spawns on demand.
Emacs owns the daemon's lifecycle: the first agent-shell session lazily
spawns it (detached, so it outlives this Emacs); it is shared across every
Emacs on the machine (flock-elected) and self-exits once the last live
agent-shell buffer anywhere closes."
  :type 'string
  :group 'agent-shell-bridge)

(defvar agent-shell-bridge-app--proc nil
  "The live network process to the sidecar, or nil.")
(defvar agent-shell-bridge-app--rx ""
  "Partial inbound buffer for line framing.")
(defvar agent-shell-bridge-app--inbound-cb nil)
(defvar agent-shell-bridge-app--control-cb nil)
(defvar agent-shell-bridge-app--create-cb nil
  "Global handler for remote session-creation (`new-session'/`resume-session').
Registered once at startup (not per buffer): these arrive with no owning
session, so the first session can be created from the phone.")
(defvar agent-shell-bridge-app--counter 0)
(defvar agent-shell-bridge-app--handles nil
  "Known session handles, for `session-close' on stop.")
(defvar agent-shell-bridge-app--last-handle nil
  "Most recent session handle, used when a message omits `:session'.")
(defvar agent-shell-bridge-app--outbox nil
  "FIFO queue of pending messages awaiting *acknowledgement* (oldest first).
Each entry is a cons (CID . OBJ). The sidecar link is treated as unreliable:
a message is held here until the sidecar acks its CID (durably applied), not
merely until it is written to the socket -- so a daemon that dies mid-write
loses nothing, the un-acked entry is replayed on reconnect.")
(defvar agent-shell-bridge-app--cid 0
  "Monotonic client-id counter for the ack/outbox transport layer only.
NOT a dedup key -- semantic dedup is the per-session `ord' (see `--ordinals').")
(defvar agent-shell-bridge-app--ordinals (make-hash-table :test 'equal)
  "Per-session (handle -> u64) monotonic phrase ordinal: the daemon's dedup key.
Seeded from the daemon's persisted high-water on `session-hw', reset to 0 at the
start of a `session/load' replay so the replay reproduces the original 1..N
ordinals (deduped), then continued so genuinely-new phrases append past N.")
(defvar agent-shell-bridge-app--replaying (make-hash-table :test 'equal)
  "Per-session (handle -> t) flag: a `session/load' replay is in progress, used
to fire the ordinal reset exactly once on the replay's leading edge.")
(defvar agent-shell-bridge-app--inflight nil
  "CIDs already written on the *current* connection (so a live pump does not
resend them). Cleared on every fresh connection, forcing a full replay.")
(defvar agent-shell-bridge-app--titles nil
  "Alist of session handle -> title, replayed as `session-open' on reconnect
so a restarted daemon (which forgot its in-memory registry) re-learns them
before any queued `msg' is delivered.")
(defvar agent-shell-bridge-app--was-live nil
  "Non-nil once the current connection has been (re-)announced.")
(defvar agent-shell-bridge-app--retry-timer nil
  "Pending reconnect/flush timer, or nil.")
(defvar agent-shell-bridge-app--spawn-cooldown nil
  "Non-nil for a short window after we spawn the daemon, so a burst of failed
connects doesn't launch a storm (redundant spawns are harmless -- they lose
the flock election and exit 0 -- but pointless).")
(defvar agent-shell-bridge-app--claim-cid 0
  "Correlation counter for synchronous `session-claim' round-trips.")
(defvar agent-shell-bridge-app--claim-results nil
  "Alist of claim CID -> granted-boolean, filled by inbound `claim-result'.")

(defcustom agent-shell-bridge-app-claim-timeout 2.0
  "Seconds to wait for the daemon's resume `claim-result' before failing open.
A resume gate must not hang Emacs, so a silent daemon lets the resume proceed."
  :type 'number
  :group 'agent-shell-bridge)

;;;; Encoding: structured message -> payload alist

(defun agent-shell-bridge-app--tool-kind (kind)
  "Map an ACP tool KIND string to our enum string."
  (pcase (and kind (downcase (format "%s" kind)))
    ((or "read" "read_file") "read")
    ((or "edit" "write" "create") "edit")
    ((or "execute" "command" "run" "terminal") "command")
    ((or "search" "grep" "glob") "search")
    ((or "fetch" "web" "http") "fetch")
    (_ "other")))

(defun agent-shell-bridge-app--tool-status (status meta)
  "Wire tool status for a tool message STATUS, preferring META `:status'."
  (let ((s (plist-get meta :status)))
    (cond
     ((member s '("completed" "success" "done")) "done")
     ((member s '("failed" "error")) "failed")
     ((member s '("pending")) "pending")
     ((eq status 'pending) "pending")
     ((eq status 'success) "done")
     ((eq status 'error) "failed")
     (t "running"))))

(defun agent-shell-bridge-app--encode-content (message)
  "Content vector for MESSAGE: one text block when the text is non-empty."
  (let ((text (agent-shell-bridge-message-text message)))
    (if (and text (> (length text) 0))
        (vector (list (cons 'kind "text") (cons 'text text)))
      (vector))))

(defun agent-shell-bridge-app--payload (message)
  "Encode a structured bridge MESSAGE to a payload alist, or nil."
  (let* ((role (plist-get message :role))
         (status (plist-get message :status))
         (part (car (plist-get message :parts)))
         (meta (plist-get part :meta)))
    (pcase role
      ('agent  (list (cons 'type "agent_message")
                     (cons 'text (agent-shell-bridge-message-text message))))
      ('system (list (cons 'type "agent_message")
                     (cons 'text (agent-shell-bridge-message-text message))))
      ('thinking (list (cons 'type "thought")
                       (cons 'text (agent-shell-bridge-message-text message))))
      ('user   (list (cons 'type "user_message")
                     (cons 'text (agent-shell-bridge-message-text message))))
      ('plan
       (list (cons 'type "plan")
             (cons 'entries
                   (apply #'vector
                          (mapcar
                           (lambda (e)
                             (list (cons 'content (or (map-elt e 'content)
                                                      (map-elt e 'step) ""))
                                   ;; ACP already uses pending/in_progress/
                                   ;; completed, matching our PlanStatus.
                                   (cons 'status (or (map-elt e 'status) "pending"))))
                           (append (plist-get meta :entries) nil))))))
      ('tool
       (let ((id (or (plist-get meta :tool-call-id) (plist-get message :id) "")))
         (if (eq status 'pending)
             (list (cons 'type "tool_call")
                   (cons 'id id)
                   (cons 'kind (agent-shell-bridge-app--tool-kind (plist-get meta :kind)))
                   (cons 'title (or (plist-get meta :title) ""))
                   (cons 'command (plist-get meta :command))
                   (cons 'status (agent-shell-bridge-app--tool-status status meta))
                   (cons 'content (agent-shell-bridge-app--encode-content message))
                   (cons 'locations (vector)))
           (list (cons 'type "tool_call_update")
                 (cons 'id id)
                 (cons 'status (agent-shell-bridge-app--tool-status status meta))
                 (cons 'content (agent-shell-bridge-app--encode-content message))))))
      (_ nil))))

;;;; Per-session ordinal (the daemon's dedup key)

(defun agent-shell-bridge-app--session-loading-p (handle)
  "Non-nil when HANDLE's agent-shell buffer is mid `session/load' (history
replay).  Reads agent-shell's `--state' `:active-requests', an alist of
in-flight requests each carrying a `:method'."
  (let ((buf (and (boundp 'agent-shell-bridge--session->buffer)
                  (gethash handle agent-shell-bridge--session->buffer))))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (and (boundp 'agent-shell--state)
                (seq-find (lambda (r)
                            (equal (map-elt r :method) "session/load"))
                          (map-elt agent-shell--state :active-requests))
                t)))))

(defun agent-shell-bridge-app--next-ord (handle)
  "Assign HANDLE's next per-session ordinal, handling the replay edge.
On the first phrase of a `session/load' replay, reset to 0 so the replay
reproduces the original 1..N ordinals (the daemon dedups them); afterwards the
counter continues, so new phrases append past the high-water."
  (let ((loading (agent-shell-bridge-app--session-loading-p handle)))
    (cond
     ((and loading (not (gethash handle agent-shell-bridge-app--replaying)))
      (puthash handle 0 agent-shell-bridge-app--ordinals)
      (puthash handle t agent-shell-bridge-app--replaying))
     ((not loading)
      (remhash handle agent-shell-bridge-app--replaying)))
    (puthash handle (1+ (gethash handle agent-shell-bridge-app--ordinals 0))
             agent-shell-bridge-app--ordinals)))

;;;; Line encoding + permission mapping

(defun agent-shell-bridge-app--line (obj)
  "Encode OBJ (an alist) to one ndjson line."
  (concat (let ((json-encoding-pretty-print nil)) (json-encode obj)) "\n"))

(defun agent-shell-bridge-app--option-action (kind)
  "Classify an ACP option KIND string into a semantic action id, or nil."
  (pcase (and kind (downcase (format "%s" kind)))
    ((or "allow" "accept" "allow_once") "approve")
    ((or "always" "allowalways" "allow_always" "always_allow") "always")
    ((or "deny" "reject" "reject_once") "deny")
    (_ nil)))

(defun agent-shell-bridge-app--permission-object (message remote-id)
  "Build an `EmacsIn::permission' alist from a permission MESSAGE + REMOTE-ID."
  (let* ((part (car (plist-get message :parts)))
         (meta (plist-get part :meta))
         (acp-opts (append (plist-get meta :options) nil))
         (seen (make-hash-table :test 'equal))
         (options nil))
    (dolist (o acp-opts)
      (let* ((kind (or (alist-get 'kind o) (alist-get :kind o)))
             (id (agent-shell-bridge-app--option-action kind))
             (name (or (alist-get 'name o) (alist-get :name o)
                       (alist-get 'optionId o) (alist-get :optionId o))))
        (when (and id (not (gethash id seen)))
          (puthash id t seen)
          (push (list (cons 'id id) (cons 'label (format "%s" (or name id)))) options))))
    (list (cons 't "permission")
          (cons 'session (or (plist-get message :session)
                             agent-shell-bridge-app--last-handle))
          (cons 'id (format "%s" remote-id))
          (cons 'command (or (plist-get part :content) "Permission required"))
          (cons 'options (vconcat (nreverse options))))))

;;;; Inbound decode -> callbacks

(defun agent-shell-bridge-app--handle (obj inbound control &optional create)
  "Dispatch a decoded `EmacsOut' OBJ to INBOUND/CONTROL/CREATE callbacks."
  (let ((session (alist-get 'session obj)))
    (pcase (alist-get 't obj)
      ("ack"
       (agent-shell-bridge-app--ack (alist-get 'cid obj)))
      ("claim-result"
       (push (cons (alist-get 'cid obj) (eq (alist-get 'granted obj) t))
             agent-shell-bridge-app--claim-results))
      ("session-hw"
       ;; Seed a still-untouched per-session counter to the daemon's high-water
       ;; (resume-without-replay). Once any phrase (live or replayed) has
       ;; advanced it, a late/duplicate hw must not clobber that progress.
       (let ((h (alist-get 'session obj)) (hw (alist-get 'hw obj)))
         (when (and h (integerp hw)
                    (= 0 (gethash h agent-shell-bridge-app--ordinals 0)))
           (puthash h hw agent-shell-bridge-app--ordinals))))
      ("inject"
       (when inbound
         (funcall inbound (list :text (alist-get 'text obj) :session session))))
      ("command"
       (when inbound
         (let* ((name (alist-get 'name obj))
                (arg (alist-get 'arg obj))
                (text (if (and arg (stringp arg) (> (length arg) 0))
                          (format "/%s %s" name arg)
                        (format "/%s" name))))
           (funcall inbound (list :text text :session session)))))
      ("permission-response"
       (when control
         (let* ((opt (alist-get 'option obj))
                (action (pcase opt ("always" 'approve) (_ (intern (format "%s" opt))))))
           (funcall control (list :action action
                                  :target (format "%s" (alist-get 'id obj))
                                  :session session)))))
      ("interrupt"
       (when control
         (funcall control (list :action 'interrupt :session session))))
      ("new-session"
       (when create
         (funcall create (list :action 'new
                               :prompt (alist-get 'prompt obj)
                               :cwd (alist-get 'cwd obj)))))
      ("resume-session"
       (when create
         (funcall create (list :action 'resume :session session)))))))

;;;; Socket lifecycle + framing

(defun agent-shell-bridge-app--sentinel (_proc _event)
  (when (or (not agent-shell-bridge-app--proc)
            (not (process-live-p agent-shell-bridge-app--proc)))
    (setq agent-shell-bridge-app--proc nil
          agent-shell-bridge-app--rx ""
          agent-shell-bridge-app--was-live nil)
    ;; The socket dropped -- keep retrying while anything is queued so the
    ;; backlog flushes the instant the daemon (or network) returns.
    (when agent-shell-bridge-app--outbox
      (agent-shell-bridge-app--schedule-retry))))

(defun agent-shell-bridge-app--filter (_proc chunk)
  (setq agent-shell-bridge-app--rx (concat agent-shell-bridge-app--rx chunk))
  (while (string-match "\n" agent-shell-bridge-app--rx)
    (let ((line (substring agent-shell-bridge-app--rx 0 (match-beginning 0))))
      (setq agent-shell-bridge-app--rx
            (substring agent-shell-bridge-app--rx (match-end 0)))
      (when (> (length (string-trim line)) 0)
        (condition-case err
            (agent-shell-bridge-app--handle
             (json-read-from-string line)
             agent-shell-bridge-app--inbound-cb
             agent-shell-bridge-app--control-cb
             agent-shell-bridge-app--create-cb)
          (error (agent-shell-bridge--log "app: bad inbound line %S: %S" line err)))))))

(defun agent-shell-bridge-app--state-dir ()
  "Where the daemon keeps its shared state (matches its own `state_dir')."
  (let ((xdg (getenv "XDG_STATE_HOME")))
    (if xdg (expand-file-name "asb" xdg)
      (expand-file-name "~/.local/state/asb"))))

(defun agent-shell-bridge-app--ensure-daemon ()
  "Spawn the shared `asb-sidecar' daemon, detached, unless just tried.
Emacs owns the daemon's lifecycle, spawning it lazily when the first
session needs it.  Detached via `setsid' so it outlives this Emacs; a
duplicate spawn is safe (it loses the flock election and exits 0).  The
cooldown only avoids a pointless launch storm while the winner binds."
  (unless agent-shell-bridge-app--spawn-cooldown
    (setq agent-shell-bridge-app--spawn-cooldown
          (run-with-timer 5 nil (lambda ()
                                  (setq agent-shell-bridge-app--spawn-cooldown nil))))
    (condition-case err
        (let* ((state (agent-shell-bridge-app--state-dir))
               (log (expand-file-name "daemon.log" state))
               (cmd (format "exec %s run </dev/null >>%s 2>&1"
                            (shell-quote-argument agent-shell-bridge-app-binary)
                            (shell-quote-argument log)))
               ;; The shell opens `daemon.log' (>>) before exec; without this dir
               ;; the redirect fails and the daemon never starts (it can't create
               ;; its own state dir -- the binary never runs). Bites the first
               ;; spawn on a machine with no state dir yet. Must precede the spawn.
               (_ (make-directory state t))
               (proc (make-process
                      :name "asb-sidecar-spawn" :noquery t
                      :connection-type 'pipe :buffer nil
                      :command (list "setsid" "sh" "-c" cmd))))
          (set-process-query-on-exit-flag proc nil)
          (agent-shell-bridge--log "app: spawned daemon (%s)"
                                   agent-shell-bridge-app-binary))
      (error (agent-shell-bridge--log "app: daemon spawn failed: %S" err)))))

(defun agent-shell-bridge-app--ensure-proc ()
  "Return a live process to the sidecar, connecting if needed, or nil.
On a failed connect, lazily spawn the daemon; the outbox retry timer then
reconnects once it binds the socket."
  (unless (and agent-shell-bridge-app--proc
               (process-live-p agent-shell-bridge-app--proc))
    (setq agent-shell-bridge-app--rx "")
    (condition-case err
        (setq agent-shell-bridge-app--proc
              (make-network-process
               :name "asb-app" :family 'local
               :service agent-shell-bridge-app-socket
               :coding 'utf-8-unix :nowait nil
               :filter #'agent-shell-bridge-app--filter
               :sentinel #'agent-shell-bridge-app--sentinel))
      (error
       (agent-shell-bridge--log "app: connect failed (%s): %S"
                                agent-shell-bridge-app-socket err)
       (setq agent-shell-bridge-app--proc nil)
       ;; Nothing listening yet -- Emacs owns the lifecycle, so start it.
       (agent-shell-bridge-app--ensure-daemon))))
  agent-shell-bridge-app--proc)

(defun agent-shell-bridge-app--title-for (handle)
  "Best-known title for HANDLE: the cached title, else the owning buffer's."
  (or (alist-get handle agent-shell-bridge-app--titles nil nil #'equal)
      (let ((buf (and (boundp 'agent-shell-bridge--session->buffer)
                      (gethash handle agent-shell-bridge--session->buffer))))
        (and (buffer-live-p buf)
             (buffer-local-value 'agent-shell-bridge--session-title buf)))
      "session"))

(defun agent-shell-bridge-app--reannounce ()
  "Re-send `session-open' for every known session on a fresh connection.
Iterates the live handle set (not just the title cache) so a session
opened before this connection is still re-registered -- otherwise a
restarted daemon rejects its queued `msg's as unknown."
  (dolist (handle agent-shell-bridge-app--handles)
    (ignore-errors
      (process-send-string
       agent-shell-bridge-app--proc
       (agent-shell-bridge-app--line
        (list (cons 't "session-open")
              (cons 'session handle)
              (cons 'title (agent-shell-bridge-app--title-for handle))))))))

(defun agent-shell-bridge-app--schedule-retry ()
  "Ensure a pending timer will retry delivery of the outbox."
  (unless agent-shell-bridge-app--retry-timer
    (setq agent-shell-bridge-app--retry-timer
          (run-with-timer 1 nil #'agent-shell-bridge-app--retry-tick))))

(defun agent-shell-bridge-app--retry-tick ()
  (setq agent-shell-bridge-app--retry-timer nil)
  (when agent-shell-bridge-app--outbox
    (agent-shell-bridge-app--pump)))

(defun agent-shell-bridge-app--ack (cid)
  "Drop the acked CID from the outbox -- the sidecar has durably applied it."
  (when (integerp cid)
    (setq agent-shell-bridge-app--outbox
          (assq-delete-all cid agent-shell-bridge-app--outbox)
          agent-shell-bridge-app--inflight
          (delq cid agent-shell-bridge-app--inflight))
    ;; No timer needed once everything is acknowledged.
    (when (and (null agent-shell-bridge-app--outbox)
               agent-shell-bridge-app--retry-timer)
      (cancel-timer agent-shell-bridge-app--retry-timer)
      (setq agent-shell-bridge-app--retry-timer nil))))

(defun agent-shell-bridge-app--pump ()
  "Ensure a connection and write every un-acked outbox entry; retry until acked.
Entries are held until the sidecar acks their CID, not merely until written,
so a daemon dying mid-write loses nothing -- the un-acked entry is resent on
the next connection."
  (let ((proc (agent-shell-bridge-app--ensure-proc)))
    (if (not proc)
        (agent-shell-bridge-app--schedule-retry)
      ;; A fresh (re)connection: the daemon may have restarted and forgotten
      ;; its session registry, so re-announce every session before replaying
      ;; queued `msg's (which it would otherwise reject as unknown). Clearing
      ;; in-flight forces a full replay of everything not yet acked.
      (unless agent-shell-bridge-app--was-live
        (setq agent-shell-bridge-app--was-live t
              agent-shell-bridge-app--inflight nil)
        (agent-shell-bridge-app--reannounce))
      (let ((ok t))
        (dolist (entry agent-shell-bridge-app--outbox)
          (let ((cid (car entry)) (obj (cdr entry)))
            (when (and ok (not (memq cid agent-shell-bridge-app--inflight)))
              (condition-case err
                  (progn
                    (process-send-string
                     proc (agent-shell-bridge-app--line
                           (append obj (list (cons 'cid cid)))))
                    (push cid agent-shell-bridge-app--inflight))
                (error
                 (agent-shell-bridge--log "app: send failed, will retry: %S" err)
                 (setq ok nil agent-shell-bridge-app--was-live nil)
                 (agent-shell-bridge-app--schedule-retry)))))))
      ;; Keep a heartbeat while anything is still awaiting an ack.
      (when agent-shell-bridge-app--outbox
        (agent-shell-bridge-app--schedule-retry)))))

(defun agent-shell-bridge-app--send-emacs-in (obj)
  "Queue OBJ (an `EmacsIn' alist) for reliable, ack-gated, in-order delivery."
  (let ((cid (cl-incf agent-shell-bridge-app--cid)))
    (setq agent-shell-bridge-app--outbox
          (nconc agent-shell-bridge-app--outbox (list (cons cid obj)))))
  (agent-shell-bridge-app--pump)
  t)

(defun agent-shell-bridge-app--disconnect ()
  (when agent-shell-bridge-app--proc
    (ignore-errors (delete-process agent-shell-bridge-app--proc)))
  (setq agent-shell-bridge-app--proc nil
        agent-shell-bridge-app--rx ""
        agent-shell-bridge-app--was-live nil))

;;;; Provider slots

(defun agent-shell-bridge-app--start-session (meta)
  "Open a sidecar session and return its handle."
  (let ((handle (or (ignore-errors (agent-shell-bridge--session-id))
                    (format "%d-%d" (emacs-pid)
                            (cl-incf agent-shell-bridge-app--counter)))))
    (setq agent-shell-bridge-app--last-handle handle)
    (cl-pushnew handle agent-shell-bridge-app--handles :test #'equal)
    (let ((title (or (plist-get meta :title) (plist-get meta :name) "session")))
      (setf (alist-get handle agent-shell-bridge-app--titles nil nil #'equal) title)
      (agent-shell-bridge-app--send-emacs-in
       (list (cons 't "session-open")
             (cons 'session handle)
             (cons 'title title))))
    handle))

(defun agent-shell-bridge-app--on-relink (handle)
  "Register a RESUMED session with the daemon (relink hook).
On resume the core relinks to the persisted post without calling
`start-session', so the daemon never learns the session and would reject its
replayed `msg's as unknown.  Send `session-open' here so it registers and
replies `session-hw' (seeding our ordinal counter).  No-op unless the app
provider is the active one."
  (when (eq (ignore-errors
              (agent-shell-bridge-provider-name (agent-shell-bridge-active-provider)))
            'app)
    (cl-pushnew handle agent-shell-bridge-app--handles :test #'equal)
    (setq agent-shell-bridge-app--last-handle handle)
    (agent-shell-bridge-app--send-emacs-in
     (list (cons 't "session-open") (cons 'session handle)
           (cons 'title (agent-shell-bridge-app--title-for handle))))))

(defun agent-shell-bridge-app--send (message)
  "Mirror MESSAGE to the sidecar; return a remote id."
  (let ((handle (or (plist-get message :session)
                    agent-shell-bridge-app--last-handle)))
    (if (eq (plist-get message :role) 'permission)
        (let ((rid (format "%d" (cl-incf agent-shell-bridge-app--counter))))
          (agent-shell-bridge-app--send-emacs-in
           (agent-shell-bridge-app--permission-object message rid))
          rid)
      (when-let* ((payload (agent-shell-bridge-app--payload message)))
        (agent-shell-bridge-app--send-emacs-in
         (list (cons 't "msg") (cons 'session handle)
               (cons 'seq 0) (cons 'turn 0)
               (cons 'ord (agent-shell-bridge-app--next-ord handle))
               (cons 'payload payload))))
      (format "%d" (cl-incf agent-shell-bridge-app--counter)))))

(defun agent-shell-bridge-app--set-status (handle running)
  (agent-shell-bridge-app--send-emacs-in
   (list (cons 't "status") (cons 'session (or handle agent-shell-bridge-app--last-handle))
         (cons 'state (if running "running" "idle")))))

(defun agent-shell-bridge-app--wire-opts (opts)
  "Encode provider-agnostic config OPTS as a wire vector of {id,name,description}."
  (apply #'vector
         (mapcar (lambda (o)
                   (list (cons 'id (or (plist-get o :id) ""))
                         (cons 'name (or (plist-get o :name) ""))
                         (cons 'description (plist-get o :description))))
                 opts)))

(defun agent-shell-bridge-app--config (handle plist)
  "Mirror a session's backend knobs/commands PLIST for HANDLE as a `config' line."
  (agent-shell-bridge-app--send-emacs-in
   (list
    (cons 't "config")
    (cons 'session handle)
    (cons 'config
          (list (cons 'models (agent-shell-bridge-app--wire-opts (plist-get plist :models)))
                (cons 'current_model (plist-get plist :current-model))
                (cons 'modes (agent-shell-bridge-app--wire-opts (plist-get plist :modes)))
                (cons 'current_mode (plist-get plist :current-mode))
                (cons 'thought_levels
                      (agent-shell-bridge-app--wire-opts (plist-get plist :thought-levels)))
                (cons 'current_thought (plist-get plist :current-thought))
                (cons 'commands
                      (apply #'vector
                             (mapcar (lambda (c)
                                       (list (cons 'name (or (plist-get c :name) ""))
                                             (cons 'description (plist-get c :description))))
                                     (plist-get plist :commands)))))))))

(defun agent-shell-bridge-app--claim-session (handle)
  "Synchronously reserve HANDLE against the daemon before a resume opens it.
Returns `granted', `denied', or `unavailable'.  Blocks up to
`agent-shell-bridge-app-claim-timeout'; a missing/silent daemon yields
`unavailable' so the caller fails open (never wedges a resume)."
  (let ((proc (agent-shell-bridge-app--ensure-proc)))
    (if (not proc)
        'unavailable
      (let ((cid (cl-incf agent-shell-bridge-app--claim-cid)))
        (if (not (ignore-errors
                   (process-send-string
                    proc (agent-shell-bridge-app--line
                          (list (cons 't "session-claim")
                                (cons 'session handle) (cons 'cid cid))))
                   t))
            'unavailable
          (let ((deadline (+ (float-time) agent-shell-bridge-app-claim-timeout))
                (result 'pending))
            (while (and (eq result 'pending) (< (float-time) deadline))
              (accept-process-output proc 0.05)
              (let ((cell (assq cid agent-shell-bridge-app--claim-results)))
                (when cell
                  (setq result (if (cdr cell) 'granted 'denied)
                        agent-shell-bridge-app--claim-results
                        (assq-delete-all cid agent-shell-bridge-app--claim-results)))))
            (if (eq result 'pending) 'unavailable result)))))))

(defun agent-shell-bridge-app--close-session (handle)
  "Close just HANDLE: its agent-shell buffer was killed.
Sends one `session-close' so the daemon's live-session ref-count falls;
when the last such buffer anywhere closes, the daemon self-exits.  Leaves
the connection up for the other sessions."
  (when (member handle agent-shell-bridge-app--handles)
    (agent-shell-bridge-app--send-emacs-in
     (list (cons 't "session-close") (cons 'session handle)))
    (setq agent-shell-bridge-app--handles
          (delete handle agent-shell-bridge-app--handles))
    (setf (alist-get handle agent-shell-bridge-app--titles nil t #'equal) nil)
    (remhash handle agent-shell-bridge-app--ordinals)
    (remhash handle agent-shell-bridge-app--replaying)
    (when (equal agent-shell-bridge-app--last-handle handle)
      (setq agent-shell-bridge-app--last-handle
            (car agent-shell-bridge-app--handles)))))

(defun agent-shell-bridge-app--stop ()
  (dolist (h agent-shell-bridge-app--handles)
    (agent-shell-bridge-app--send-emacs-in
     (list (cons 't "session-close") (cons 'session h))))
  (setq agent-shell-bridge-app--handles nil
        agent-shell-bridge-app--titles nil)
  (clrhash agent-shell-bridge-app--ordinals)
  (clrhash agent-shell-bridge-app--replaying)
  (when agent-shell-bridge-app--retry-timer
    (cancel-timer agent-shell-bridge-app--retry-timer)
    (setq agent-shell-bridge-app--retry-timer nil))
  (agent-shell-bridge-app--disconnect))

(defun agent-shell-bridge-app-provider ()
  "Return a freshly-built asb-sidecar provider."
  (agent-shell-bridge-provider-create
   :name 'app
   :can-edit nil
   :start-session #'agent-shell-bridge-app--start-session
   :send #'agent-shell-bridge-app--send
   :edit (lambda (&rest _) nil)
   :delete (lambda (&rest _) nil)
   :set-status #'agent-shell-bridge-app--set-status
   :config #'agent-shell-bridge-app--config
   :close-session #'agent-shell-bridge-app--close-session
   :claim-session #'agent-shell-bridge-app--claim-session
   :on-inbound (lambda (cb) (setq agent-shell-bridge-app--inbound-cb cb))
   :on-control (lambda (cb) (setq agent-shell-bridge-app--control-cb cb))
   :on-create (lambda (cb) (setq agent-shell-bridge-app--create-cb cb))
   :stop #'agent-shell-bridge-app--stop))

;;;###autoload
(defun agent-shell-bridge-app-register ()
  "Register and select the asb-sidecar (app) provider."
  (interactive)
  (agent-shell-bridge-register-provider (agent-shell-bridge-app-provider))
  (agent-shell-bridge-set-provider 'app)
  ;; Wire the global remote-create handler once (session-less, so not per
  ;; buffer): lets the phone start a new session or reopen a closed one.
  (when-let* ((p (agent-shell-bridge-active-provider))
              (on-create (agent-shell-bridge-provider-on-create p)))
    (funcall on-create #'agent-shell-bridge--handle-create))
  ;; Register a resumed session with the daemon when the core relinks it
  ;; (idempotent: add-hook de-dups on the same symbol).
  (add-hook 'agent-shell-bridge--relink-functions
            #'agent-shell-bridge-app--on-relink))

(provide 'agent-shell-bridge-app)
;;; agent-shell-bridge-app.el ends here
