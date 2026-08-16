;;; agent-shell-bridge-discord.el --- Discord bot provider core -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The Discord provider's outbound half: rendering, the activity
;; aggregator, and the bot REST transport.  Everything speaks to Discord
;; through the *bot token* -- there is no webhook.  A session opens one
;; forum post (a thread) and every message posts under it via
;; `POST /channels/{thread}/messages'; the bot edits its own messages
;; (activity subtext) and reacts (permission taps, status).  The inbound
;; half -- the gateway websocket listener -- lives in
;; `agent-shell-bridge-discord-gateway'.
;;
;; The flattener collapses a structured message to a single Discord
;; message: role header, hard truncation to the 2000-char cap, thinking
;; and tool calls folded into one edited "Thought, ran a command" subtext.
;; This is Discord-specific and lossy on purpose; the core still forwards
;; the full structured stream, so a richer provider can consume every
;; thinking chunk and tool call instead of discarding them.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-util)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-provider)

(defcustom agent-shell-bridge-discord-bot-token nil
  "Discord bot token.  Read from environment/authinfo; never hard-code."
  :type '(choice (const nil) string)
  :group 'agent-shell-bridge)

(defcustom agent-shell-bridge-discord-channel-id nil
  "Discord forum channel id the sessions post under and the bot listens on."
  :type '(choice (const nil) string)
  :group 'agent-shell-bridge)

(defcustom agent-shell-bridge-discord-forum-p nil
  "When non-nil, open one forum post (thread) per session.
Each session's messages thread under that post.  Requires
`agent-shell-bridge-discord-channel-id' to name a forum/media channel."
  :type 'boolean
  :group 'agent-shell-bridge)

(defconst agent-shell-bridge-discord-max-length 2000
  "Discord's per-message character cap.")

(defconst agent-shell-bridge-discord--truncation-marker "\n… **[truncated]**"
  "Appended when a flattened message overflows the cap.")

(defconst agent-shell-bridge-discord--body-overhead 40
  "Chars reserved for header, spoiler/code wrappers, marker and newlines.")

(defconst agent-shell-bridge-discord--separator "\n​"
  "Appended to each posted message so consecutive messages read apart.
A bare trailing newline is trimmed by Discord; the zero-width space after
it survives, yielding one blank line of separation.")

(defconst agent-shell-bridge-discord--api-base "https://discord.com/api/v10"
  "Base URL for the Discord REST API.")

(defun agent-shell-bridge-discord--separated (content)
  "CONTENT with the trailing blank-line separator appended."
  (concat content agent-shell-bridge-discord--separator))

;;;; REST transport (bot token)

(defun agent-shell-bridge-discord--rest-args (method path body)
  "The curl argument list (after \"curl\") for METHOD PATH with BODY."
  (append
   (list "-s" "--max-time" "10" "-X" method
         "-H" (format "Authorization: Bot %s" agent-shell-bridge-discord-bot-token)
         "-H" "Content-Type: application/json")
   (when body (list "-d" (json-encode body)))
   (list (concat agent-shell-bridge-discord--api-base path))))

;; Reactions and status swaps share Discord's tight per-channel reaction
;; rate limit.  Fired concurrently they 429 each other -- an ack or a
;; status-removal silently vanishes.  So every PUT/DELETE goes through one
;; FIFO worker that sends a single request at a time and, on a 429, re-sends
;; after the server-specified `retry_after'.  The queue is PERSISTED to disk:
;; reactions still pending when Emacs closes are re-sent on the next start,
;; so a resumed session never wrongly rejects an already-handled message
;; whose ack had not yet landed.  GET/POST/PATCH stay synchronous (their
;; caller needs the result) and are not queued.

(defcustom agent-shell-bridge-discord-queue-file
  (expand-file-name "agent-shell-bridge-discord-queue.eld" user-emacs-directory)
  "File the pending reaction/status queue is persisted to across restarts."
  :type 'file
  :group 'agent-shell-bridge)

(defvar agent-shell-bridge-discord--rest-queue nil
  "Pending async requests, each (METHOD PATH BODY ATTEMPTS).")

(defvar agent-shell-bridge-discord--rest-current nil
  "The request in flight (METHOD PATH BODY ATTEMPTS), or nil when idle.")

(defconst agent-shell-bridge-discord--rest-max-attempts 6
  "Give up on a rate-limited request after this many tries.")

(defun agent-shell-bridge-discord--rest-pending ()
  "All not-yet-confirmed requests: the in-flight one plus the queue."
  (append (and agent-shell-bridge-discord--rest-current
               (list agent-shell-bridge-discord--rest-current))
          agent-shell-bridge-discord--rest-queue))

(defun agent-shell-bridge-discord--rest-persist ()
  "Write the pending requests to `agent-shell-bridge-discord-queue-file'."
  (ignore-errors
    (with-temp-file agent-shell-bridge-discord-queue-file
      (let ((print-length nil) (print-level nil))
        (prin1 (agent-shell-bridge-discord--rest-pending) (current-buffer))))))

(defun agent-shell-bridge-discord--rest-load ()
  "Re-enqueue requests persisted by a previous session and resume sending."
  (when (file-exists-p agent-shell-bridge-discord-queue-file)
    (let ((saved (ignore-errors
                   (with-temp-buffer
                     (insert-file-contents agent-shell-bridge-discord-queue-file)
                     (read (current-buffer))))))
      (when (and saved (listp saved))
        (agent-shell-bridge--log "rest: resuming %d persisted request(s)"
                                 (length saved))
        (setq agent-shell-bridge-discord--rest-queue
              (append saved agent-shell-bridge-discord--rest-queue))
        (agent-shell-bridge-discord--rest-pump)))))

(defun agent-shell-bridge-discord--rest-message-id (req)
  "The message-id a reaction REQUEST (METHOD PATH ...) targets, or nil."
  (let ((path (nth 1 req)))
    (when (and path (string-match "/messages/\\([0-9]+\\)/reactions/" path))
      (match-string 1 path))))

(defun agent-shell-bridge-discord--pending-reaction-message-ids ()
  "Message-ids that still have a queued (unconfirmed) reaction."
  (delq nil (mapcar #'agent-shell-bridge-discord--rest-message-id
                    (agent-shell-bridge-discord--rest-pending))))

(defun agent-shell-bridge-discord--rest-enqueue (method path body)
  "Queue an async METHOD PATH BODY request and kick the worker."
  (setq agent-shell-bridge-discord--rest-queue
        (append agent-shell-bridge-discord--rest-queue
                (list (list method path body 0))))
  (agent-shell-bridge-discord--rest-persist)
  (agent-shell-bridge-discord--rest-pump))

(defun agent-shell-bridge-discord--rest-advance ()
  "Finish the in-flight request and start the next queued one."
  (setq agent-shell-bridge-discord--rest-current nil)
  (agent-shell-bridge-discord--rest-persist)
  (agent-shell-bridge-discord--rest-pump))

(defun agent-shell-bridge-discord--rest-pump ()
  "If idle, send the next queued request one at a time."
  (when (and (not agent-shell-bridge-discord--rest-current)
             agent-shell-bridge-discord--rest-queue)
    (setq agent-shell-bridge-discord--rest-current
          (pop agent-shell-bridge-discord--rest-queue))
    (agent-shell-bridge-discord--rest-persist)
    (pcase-let ((`(,method ,path ,body ,attempts)
                 agent-shell-bridge-discord--rest-current))
      (let ((buf (generate-new-buffer " *asb-discord-rest*"))
            (args (agent-shell-bridge-discord--rest-args method path body)))
        (agent-shell-bridge--log "rest: %s %s (async attempt %d)"
                                 method path (1+ attempts))
        ;; NB: `:command' must receive the list itself -- never `apply' the
        ;; args, or curl's flags become make-process keywords and it never fires.
        (condition-case err
            (make-process
             :name "asb-discord-rest" :noquery t :buffer buf
             :command (cons "curl" args)
             :sentinel
             (lambda (proc event)
               (when (memq (process-status proc) '(exit signal))
                 (agent-shell-bridge-discord--rest-complete
                  buf (string-trim event)))))
          (error
           (agent-shell-bridge--log "rest: %s %s make-process FAILED: %S"
                                    method path err)
           (ignore-errors (kill-buffer buf))
           (agent-shell-bridge-discord--rest-advance)))))))

(defun agent-shell-bridge-discord--rest-complete (buf event)
  "Handle completion of the in-flight request; retry on 429, else advance."
  (pcase-let ((`(,method ,path ,body ,attempts)
               agent-shell-bridge-discord--rest-current))
    (let* ((out (if (buffer-live-p buf)
                    (with-current-buffer buf (buffer-string)) ""))
           (resp (ignore-errors (json-parse-string out :object-type 'alist)))
           (retry (and (listp resp) (alist-get 'retry_after resp))))
      (agent-shell-bridge--log "rest: %s %s -> %s body=%S" method path event
                               (substring out 0 (min 160 (length out))))
      (ignore-errors (kill-buffer buf))
      (cond
       ((and retry (< (1+ attempts) agent-shell-bridge-discord--rest-max-attempts))
        (agent-shell-bridge--log "rest: %s %s rate-limited; retry in %ss (attempt %d)"
                                 method path retry (1+ attempts))
        (run-at-time
         (+ (if (numberp retry) retry 1) 0.1) nil
         (lambda ()
           ;; Re-send this exact request ahead of newer ones so a status
           ;; DELETE/PUT swap keeps its order.
           (push (list method path body (1+ attempts))
                 agent-shell-bridge-discord--rest-queue)
           (agent-shell-bridge-discord--rest-advance))))
       (t
        (when (and (listp resp) (alist-get 'code resp) (alist-get 'message resp))
          (message "agent-shell-bridge: Discord %s %s failed: %s"
                   method path (alist-get 'message resp)))
        (agent-shell-bridge-discord--rest-advance))))))

(defun agent-shell-bridge-discord--rest-request (method path body)
  "Perform a Discord REST request: METHOD PATH with BODY alist (or nil).
Reactions and status swaps (PUT/DELETE) are queued (persisted) and sent one
at a time with 429 retry, so Emacs never blocks and no reaction is dropped
-- even across a restart.  GET/POST/PATCH run synchronously and return the
decoded JSON response (or nil), since their caller needs the result."
  (if (member method '("PUT" "DELETE"))
      (progn (agent-shell-bridge-discord--rest-enqueue method path body) nil)
    (let* ((args (agent-shell-bridge-discord--rest-args method path body))
           (out (with-output-to-string
                  (with-current-buffer standard-output
                    (apply #'call-process "curl" nil t nil args))))
           (resp (ignore-errors (json-parse-string out :object-type 'alist))))
      (agent-shell-bridge--log "rest: %s %s -> body=%S" method path
                               (substring out 0 (min 160 (length out))))
      resp)))

(defvar agent-shell-bridge-discord--rest-fn
  #'agent-shell-bridge-discord--rest-request
  "Function of (METHOD PATH BODY) performing a REST call.  Rebound in tests.")

(defun agent-shell-bridge-discord--rest (method path &optional body)
  (funcall agent-shell-bridge-discord--rest-fn method path body))

(defun agent-shell-bridge-discord--rest-async (method path body)
  "Fire METHOD PATH with BODY (alist or nil) without waiting; return nil.
Keeps Emacs responsive -- used for ordinary message posts and edits, whose
response we do not need back."
  (ignore-errors
    (make-process
     :name "asb-discord-rest" :noquery t :buffer nil :sentinel #'ignore
     :command (cons "curl" (agent-shell-bridge-discord--rest-args method path body))))
  nil)

;;;; Reactions

(defconst agent-shell-bridge-discord--mark-consumed "✅")
(defconst agent-shell-bridge-discord--mark-rejected "❌")

(defun agent-shell-bridge-discord--react (channel-id message-id emoji)
  "Add EMOJI as the bot's reaction to MESSAGE-ID in CHANNEL-ID."
  (agent-shell-bridge--log "react: %s on channel=%s message=%s"
                           emoji channel-id message-id)
  (agent-shell-bridge-discord--rest
   "PUT"
   (format "/channels/%s/messages/%s/reactions/%s/@me"
           channel-id message-id (url-hexify-string emoji))))

(defun agent-shell-bridge-discord--mark (channel-id message-id consumed)
  "Mark MESSAGE-ID consumed (✅) when CONSUMED, else rejected (❌)."
  (agent-shell-bridge-discord--react
   channel-id message-id
   (if consumed agent-shell-bridge-discord--mark-consumed
     agent-shell-bridge-discord--mark-rejected)))

;;;; Rendering

;; Discord can't collapse/expand, so we mirror agent-shell's *summary*:
;; the agent's reply and the user's prompt are shown plainly; all the
;; turn's background work (thinking, running commands, reading/editing
;; files) folds into ONE small subtext line -- "Thought, ran a command" --
;; that is edited in place as work happens (see the activity aggregator
;; below).  This flattening is Discord-specific and lossy on purpose; the
;; core still forwards the full structured stream, so a richer provider
;; can consume every thinking chunk and tool call instead of discarding
;; them.

(defun agent-shell-bridge-discord--header (message)
  "Role header line for MESSAGE (agent/user/permission/system only)."
  (pcase (plist-get message :role)
    ('agent "🤖 **Agent >**")
    ('user "🧑 **User >**")
    ('permission "⚠️ **Permission Required >**")
    (_ "ℹ️ **System >**")))

(defun agent-shell-bridge-discord--flatten (message &optional max-len)
  "Flatten a foreground MESSAGE (agent/user/permission/system) to a string.
An `activity' message renders as Discord subtext (small grey).  Thinking
and tool messages are folded into the activity summary, not flattened
here, and return nil."
  (let* ((max-len (or max-len agent-shell-bridge-discord-max-length))
         (role (plist-get message :role))
         (text (string-trim (agent-shell-bridge-message-text message))))
    (pcase role
      ((or 'thinking 'tool) nil)
      ('activity
       (unless (string-empty-p text) (concat "-# " text)))
      ('permission
       (concat (agent-shell-bridge-discord--header message) "\n"
               (if (string-empty-p text) "The agent requests permission." text)
               "\n-# React ✅ to allow · ❌ to deny"))
      (_
       (let* ((header (agent-shell-bridge-discord--header message))
              (marker agent-shell-bridge-discord--truncation-marker)
              (budget (- max-len (length header)
                         agent-shell-bridge-discord--body-overhead))
              (body text))
         (when (> (length body) budget)
           (setq body (concat (substring body 0 (max 0 (- budget (length marker))))
                              marker)))
         (concat header "\n" body))))))

(defalias 'agent-shell-bridge-discord--render #'agent-shell-bridge-discord--flatten
  "Return the Discord content string for a message, or nil to suppress.")

;;;; Activity aggregator (one evolving "Thought, ran a command" subtext)

;; A turn's thinking + tool calls collapse into a single subtext line we
;; post once and then EDIT in place (the bot edits its own message via
;; PATCH .../messages/{id}), exactly like agent-shell's collapsed header.
;; Phrasing is lifted from agent-shell's tool-call-kind table.  Turn
;; boundaries arrive via `set-status' (t = new turn, nil = turn done).

(defvar agent-shell-bridge-discord--post-fn)   ; defined in Bot outbound, below
(defvar agent-shell-bridge-discord--edit-fn)

(defconst agent-shell-bridge-discord--tool-phrases
  '(("execute" . (:past "ran" :present "running" :singular "command" :plural "commands"))
    ("read"    . (:past "read" :present "reading" :singular "file" :plural "files"))
    ("edit"    . (:past "edited" :present "editing" :singular "file" :plural "files"))
    ("delete"  . (:past "deleted" :present "deleting" :singular "file" :plural "files"))
    ("move"    . (:past "moved" :present "moving" :singular "file" :plural "files"))
    ("search"  . (:past "ran" :present "running" :singular "search" :plural "searches"))
    ("fetch"   . (:past "fetched" :present "fetching" :singular "resource" :plural "resources")))
  "Per-kind phrasing for the activity summary, mirroring agent-shell.")

(defconst agent-shell-bridge-discord--tool-phrase-default
  '(:past "ran" :present "running" :singular "tool call" :plural "tool calls"))

(defvar-local agent-shell-bridge-discord--act-id nil
  "Remote id of this turn's activity message, if posted.")
(defvar-local agent-shell-bridge-discord--act-thought nil)
(defvar-local agent-shell-bridge-discord--act-thinking nil)
(defvar-local agent-shell-bridge-discord--act-active nil
  "Kind string of the tool running right now, or nil.")
(defvar-local agent-shell-bridge-discord--act-counts nil
  "Alist of tool-kind string -> count this turn.")
(defvar-local agent-shell-bridge-discord--act-order nil
  "Tool kinds in first-seen order this turn.")
(defvar-local agent-shell-bridge-discord--act-seen nil
  "Alist of tool-call-id -> kind, to count each tool once.")
(defvar-local agent-shell-bridge-discord--act-rendered nil
  "Last summary string sent, to skip no-op edits.")

(defun agent-shell-bridge-discord--tool-phrase (kind count present)
  "Lowercase phrase for COUNT tools of KIND, present tense when PRESENT."
  (let ((p (or (assoc-default kind agent-shell-bridge-discord--tool-phrases)
               agent-shell-bridge-discord--tool-phrase-default)))
    (format "%s %s %s"
            (plist-get p (if present :present :past))
            (if (= count 1) "a" (number-to-string count))
            (plist-get p (if (= count 1) :singular :plural)))))

(defun agent-shell-bridge-discord--act-summary ()
  "Assemble this turn's agent-shell-style summary, or nil."
  (let ((clauses nil))
    (when agent-shell-bridge-discord--act-thought
      (push (if agent-shell-bridge-discord--act-thinking "Thinking" "Thought") clauses))
    (dolist (kind agent-shell-bridge-discord--act-order)
      (push (agent-shell-bridge-discord--tool-phrase
             kind (alist-get kind agent-shell-bridge-discord--act-counts 0 nil #'equal)
             (equal kind agent-shell-bridge-discord--act-active))
            clauses))
    (setq clauses (nreverse clauses))
    (when clauses
      (let ((first (car clauses)) (rest (mapcar #'downcase (cdr clauses))))
        (setq first (concat (upcase (substring first 0 1)) (substring first 1)))
        (mapconcat #'identity (cons first rest) ", ")))))

(defun agent-shell-bridge-discord--act-touch ()
  "Post or edit this turn's activity subtext if the summary changed."
  (let ((summary (agent-shell-bridge-discord--act-summary)))
    (when (and summary (not (equal summary agent-shell-bridge-discord--act-rendered)))
      (setq agent-shell-bridge-discord--act-rendered summary)
      ;; Discord subtext (`-#') swallows one trailing newline, so the plain
      ;; separator leaves no blank line after the Thought line -- add an
      ;; extra newline to compensate.
      (let ((content (agent-shell-bridge-discord--separated (concat "-# " summary "\n")))
            (thread (agent-shell-bridge-discord--post-channel)))
        (if agent-shell-bridge-discord--act-id
            (funcall agent-shell-bridge-discord--edit-fn
                     thread agent-shell-bridge-discord--act-id content)
          (setq agent-shell-bridge-discord--act-id
                (funcall agent-shell-bridge-discord--post-fn thread content)))))))

(defun agent-shell-bridge-discord--act-note-thinking ()
  (setq agent-shell-bridge-discord--act-thought t
        agent-shell-bridge-discord--act-thinking t
        agent-shell-bridge-discord--act-active nil)
  (agent-shell-bridge-discord--act-touch))

(defun agent-shell-bridge-discord--act-note-tool (message)
  (let* ((meta (plist-get (car (plist-get message :parts)) :meta))
         (id (plist-get meta :tool-call-id))
         (kind (or (plist-get meta :kind) "other"))
         (status (plist-get message :status)))
    (setq agent-shell-bridge-discord--act-thinking nil)
    (pcase status
      ('pending
       (unless (assoc id agent-shell-bridge-discord--act-seen)
         (push (cons id kind) agent-shell-bridge-discord--act-seen)
         (unless (member kind agent-shell-bridge-discord--act-order)
           (setq agent-shell-bridge-discord--act-order
                 (append agent-shell-bridge-discord--act-order (list kind))))
         (cl-incf (alist-get kind agent-shell-bridge-discord--act-counts 0 nil #'equal)))
       (setq agent-shell-bridge-discord--act-active kind)
       (agent-shell-bridge-discord--act-touch))
      ((or 'success 'error)
       (when (equal agent-shell-bridge-discord--act-active
                    (cdr (assoc id agent-shell-bridge-discord--act-seen)))
         (setq agent-shell-bridge-discord--act-active nil)
         (agent-shell-bridge-discord--act-touch))))))

(defun agent-shell-bridge-discord--act-reset ()
  "Clear activity state so the next turn starts a fresh summary."
  (setq agent-shell-bridge-discord--act-id nil
        agent-shell-bridge-discord--act-thought nil
        agent-shell-bridge-discord--act-thinking nil
        agent-shell-bridge-discord--act-active nil
        agent-shell-bridge-discord--act-counts nil
        agent-shell-bridge-discord--act-order nil
        agent-shell-bridge-discord--act-seen nil
        agent-shell-bridge-discord--act-rendered nil))

(defun agent-shell-bridge-discord--act-finalize ()
  "Settle the summary to past tense at turn end, then reset."
  (setq agent-shell-bridge-discord--act-thinking nil
        agent-shell-bridge-discord--act-active nil)
  (agent-shell-bridge-discord--act-touch)
  (agent-shell-bridge-discord--act-reset))

;;;; Bot outbound operations

(defun agent-shell-bridge-discord--bot-post-sync (thread content)
  "POST CONTENT to THREAD synchronously; return the created message id."
  (alist-get 'id (agent-shell-bridge-discord--rest
                  "POST" (format "/channels/%s/messages" thread)
                  `((content . ,content)))))

(defun agent-shell-bridge-discord--bot-post-async (thread content)
  "Fire-and-forget POST of CONTENT to THREAD."
  (agent-shell-bridge-discord--rest-async
   "POST" (format "/channels/%s/messages" thread)
   `((content . ,content))))

(defun agent-shell-bridge-discord--bot-edit-async (thread id content)
  "Fire-and-forget PATCH of message ID in THREAD to CONTENT."
  (agent-shell-bridge-discord--rest-async
   "PATCH" (format "/channels/%s/messages/%s" thread id)
   `((content . ,content))))

(defun agent-shell-bridge-discord--bot-upload-async (thread name data)
  "Fire-and-forget multipart upload of DATA as file NAME to THREAD."
  (let ((tmp (make-temp-file "asb-discord-" nil ".txt" data)))
    (condition-case _
        (make-process
         :name "asb-discord-upload" :noquery t :buffer nil
         :sentinel (lambda (_p _e) (ignore-errors (delete-file tmp)))
         :command (list "curl" "-s" "-X" "POST"
                        "-H" (format "Authorization: Bot %s"
                                     agent-shell-bridge-discord-bot-token)
                        "-F" (format "files[0]=@%s;filename=%s;type=text/plain" tmp name)
                        (concat agent-shell-bridge-discord--api-base
                                (format "/channels/%s/messages" thread))))
      (error (ignore-errors (delete-file tmp)))))
  nil)

;; Outbound operations are indirected through these vars so tests can
;; capture payloads without touching the network; production uses the bot
;; REST implementations above.
(defvar agent-shell-bridge-discord--post-fn
  #'agent-shell-bridge-discord--bot-post-sync
  "Function (THREAD CONTENT) -> message-id, posting synchronously.
Used when the id is needed back (activity first post, permission).")

(defvar agent-shell-bridge-discord--post-async-fn
  #'agent-shell-bridge-discord--bot-post-async
  "Function (THREAD CONTENT) -> nil, posting without waiting.")

(defvar agent-shell-bridge-discord--edit-fn
  #'agent-shell-bridge-discord--bot-edit-async
  "Function (THREAD MESSAGE-ID CONTENT) -> nil, editing without waiting.")

(defvar agent-shell-bridge-discord--upload-fn
  #'agent-shell-bridge-discord--bot-upload-async
  "Function (THREAD NAME DATA) -> nil, uploading a file attachment.")

(defvar agent-shell-bridge-discord--react-fn
  #'agent-shell-bridge-discord--react
  "Function (THREAD MESSAGE-ID EMOJI), reacting via the bot.")

;;;; Targeting

(defun agent-shell-bridge-discord--session-thread ()
  "The current buffer's forum thread id, if any."
  (let ((h (and (boundp 'agent-shell-bridge--session-handle)
                agent-shell-bridge--session-handle)))
    (and (stringp h) h)))

(defun agent-shell-bridge-discord--post-channel ()
  "The channel/thread id this buffer's messages post to.
The session's forum post when one exists, else the configured channel."
  (or (agent-shell-bridge-discord--session-thread)
      agent-shell-bridge-discord-channel-id))

(defun agent-shell-bridge-discord--post-permission (thread content)
  "Post a permission CONTENT to THREAD synchronously, then add tappable ✅/❌.
Returns the message id so the reaction can be correlated to the request."
  (let ((id (funcall agent-shell-bridge-discord--post-fn thread content)))
    (when (and id agent-shell-bridge-discord--react-fn)
      (funcall agent-shell-bridge-discord--react-fn thread id "✅")
      (funcall agent-shell-bridge-discord--react-fn thread id "❌"))
    id))

(defun agent-shell-bridge-discord--send (message)
  "Handle MESSAGE for the bot.
Thinking and tool messages fold into this turn's activity summary; a
message with a file part uploads as an attachment (e.g. /transcript); a
permission posts synchronously and gets tappable ✅/❌ reactions; the
agent reply, user prompt and command replies post as normal messages.
Posts under the session's forum post when one exists."
  (unless agent-shell-bridge-discord-bot-token
    (error "agent-shell-bridge-discord-bot-token is not set"))
  (agent-shell-bridge--log "send: role=%s thread=%s"
                           (plist-get message :role)
                           (agent-shell-bridge-discord--post-channel))
  (pcase (plist-get message :role)
    ('thinking (agent-shell-bridge-discord--act-note-thinking) nil)
    ('tool (agent-shell-bridge-discord--act-note-tool message) nil)
    (_
     (let ((thread (agent-shell-bridge-discord--post-channel)))
       (if-let* ((file (agent-shell-bridge-message-file message)))
           (funcall agent-shell-bridge-discord--upload-fn thread (car file) (cdr file))
         (when-let* ((content (agent-shell-bridge-discord--render message)))
           (let ((content (agent-shell-bridge-discord--separated content)))
             (if (eq (plist-get message :role) 'permission)
                 (agent-shell-bridge-discord--post-permission thread content)
               (funcall agent-shell-bridge-discord--post-async-fn thread content)))))))))

;;;; Forum: one post per session

(defun agent-shell-bridge-discord--create-thread (title)
  "Create a forum post titled TITLE via the bot; return its thread id, or nil."
  (let* ((name (substring title 0 (min (length title) 100)))
         (resp (agent-shell-bridge-discord--rest
                "POST" (format "/channels/%s/threads"
                               agent-shell-bridge-discord-channel-id)
                `((name . ,name)
                  (message . ((content . "🧵 Session started")))))))
    (alist-get 'id resp)))

(defun agent-shell-bridge-discord--start-session (meta)
  "Open a forum post per session when forum mode is on; else a flat handle."
  (if agent-shell-bridge-discord-forum-p
      (or (agent-shell-bridge-discord--create-thread
           (or (plist-get meta :title) (plist-get meta :name)
               "agent-shell session"))
          (progn (message "agent-shell-bridge: forum post creation failed")
                 'discord))
    'discord))

(provide 'agent-shell-bridge-discord)
;;; agent-shell-bridge-discord.el ends here
