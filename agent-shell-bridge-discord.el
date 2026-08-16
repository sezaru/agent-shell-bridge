;;; agent-shell-bridge-discord.el --- Discord provider for the bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Discord provider.  This file ships the read-only *webhook* variant: a
;; single HTTPS POST per message, no bot/gateway/intents, mobile push out
;; of the box.  `edit'/`delete'/`on-inbound'/`on-control' are no-ops here
;; (a webhook cannot edit or receive) -- the gateway variant adds those.
;;
;; The flattener collapses a structured message to a single Discord
;; message: role header, fenced tool/code/diff bodies, thinking wrapped in
;; a spoiler (Discord's closest analogue to agent-shell's collapsed
;; thinking), and hard truncation to the 2000-char cap.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-provider)

(defcustom agent-shell-bridge-discord-webhook-url nil
  "Discord webhook URL to POST mirrored messages to.
Read from the environment/authinfo; never hard-code a secret here."
  :type '(choice (const nil) string)
  :group 'agent-shell-bridge)

(defcustom agent-shell-bridge-discord-forum-p nil
  "When non-nil, treat the webhook's channel as a forum channel.
Each session opens one forum post (via `thread_name'); all of its messages
thread under that post via `?thread_id='.  Requires the webhook to live on
a forum/media channel -- a plain text channel cannot create threads from a
webhook."
  :type 'boolean
  :group 'agent-shell-bridge)

(defconst agent-shell-bridge-discord-max-length 2000
  "Discord's per-message character cap.")

(defconst agent-shell-bridge-discord--truncation-marker "\n… **[truncated]**"
  "Appended when a flattened message overflows the cap.")

(defconst agent-shell-bridge-discord--body-overhead 40
  "Chars reserved for header, spoiler/code wrappers, marker and newlines.")

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
    ('agent "🤖 **Agent**")
    ('user "🧑 **User**")
    ('permission "⚠️ **Permission Required**")
    (_ "ℹ️ **System**")))

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
;; post once and then EDIT in place (webhook messages are editable via
;; PATCH .../messages/{id}), exactly like agent-shell's collapsed header.
;; Phrasing is lifted from agent-shell's tool-call-kind table.  Turn
;; boundaries arrive via `set-status' (t = new turn, nil = turn done).

(defvar agent-shell-bridge-discord--post-fn)   ; defined in Transport, below
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
      (let ((content (concat "-# " summary))
            (url (agent-shell-bridge-discord--target-url)))
        (if agent-shell-bridge-discord--act-id
            (funcall agent-shell-bridge-discord--edit-fn
                     (agent-shell-bridge-discord--edit-url
                      agent-shell-bridge-discord--act-id)
                     content)
          (setq agent-shell-bridge-discord--act-id
                (funcall agent-shell-bridge-discord--post-fn url content)))))))

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

;;;; Transport

(defun agent-shell-bridge-discord--curl-post (url content)
  "POST CONTENT to webhook URL via curl; return the created message id."
  (let* ((json (json-encode `(("content" . ,content))))
         (out (with-output-to-string
                (with-current-buffer standard-output
                  (call-process "curl" nil t nil
                                "-s" "-X" "POST"
                                "-H" "Content-Type: application/json"
                                "-d" json url))))
         (data (ignore-errors (json-parse-string out :object-type 'alist))))
    (alist-get 'id data)))

(defvar agent-shell-bridge-discord--post-fn
  #'agent-shell-bridge-discord--curl-post
  "Function of (URL CONTENT) that POSTs and returns the message id.
Used only when the id is needed back (permission correlation).  Rebound
in tests.")

(defun agent-shell-bridge-discord--curl-post-async (url content)
  "Fire-and-forget POST of CONTENT to webhook URL; return nil immediately.
Keeps Emacs responsive -- the mirrored message id is not needed."
  (let ((json (json-encode `(("content" . ,content)))))
    (ignore-errors
      (make-process
       :name "asb-discord-post" :noquery t :buffer nil :sentinel #'ignore
       :command (list "curl" "-s" "-X" "POST"
                      "-H" "Content-Type: application/json"
                      "-d" json url))))
  nil)

(defvar agent-shell-bridge-discord--post-async-fn
  #'agent-shell-bridge-discord--curl-post-async
  "Function of (URL CONTENT) that POSTs without waiting.  Rebound in tests.")

(defun agent-shell-bridge-discord--curl-edit-async (url content)
  "Fire-and-forget PATCH setting CONTENT on the webhook message at URL."
  (let ((json (json-encode `(("content" . ,content)))))
    (ignore-errors
      (make-process
       :name "asb-discord-edit" :noquery t :buffer nil :sentinel #'ignore
       :command (list "curl" "-s" "-X" "PATCH"
                      "-H" "Content-Type: application/json"
                      "-d" json url))))
  nil)

(defvar agent-shell-bridge-discord--edit-fn
  #'agent-shell-bridge-discord--curl-edit-async
  "Function of (URL CONTENT) that PATCHes a webhook message.  Rebound in tests.")

(defun agent-shell-bridge-discord--curl-upload-async (url name data)
  "Fire-and-forget multipart POST attaching DATA as file NAME to URL."
  (let ((tmp (make-temp-file "asb-discord-" nil ".txt" data)))
    (condition-case _
        (make-process
         :name "asb-discord-upload" :noquery t :buffer nil
         :sentinel (lambda (_p _e) (ignore-errors (delete-file tmp)))
         :command (list "curl" "-s" "-X" "POST"
                        "-F" (format "files[0]=@%s;filename=%s;type=text/plain" tmp name)
                        url))
      (error (ignore-errors (delete-file tmp)))))
  nil)

(defvar agent-shell-bridge-discord--upload-fn
  #'agent-shell-bridge-discord--curl-upload-async
  "Function of (URL NAME DATA) uploading a file attachment.  Rebound in tests.")

(defvar agent-shell-bridge-discord--react-fn nil
  "Function of (THREAD-ID MESSAGE-ID EMOJI) reacting via the bot, or nil.
Set by the gateway so permission messages get tappable ✅/❌ affordances.")

(defun agent-shell-bridge-discord--with-wait (url)
  "Append the wait=true query param to URL so the POST returns the message."
  (concat url (if (string-search "?" url) "&" "?") "wait=true"))

(defun agent-shell-bridge-discord--session-thread ()
  "The current buffer's forum thread id, if any."
  (let ((h (and (boundp 'agent-shell-bridge--session-handle)
                agent-shell-bridge--session-handle)))
    (and (stringp h) h)))

(defun agent-shell-bridge-discord--target-url ()
  "The webhook URL for this buffer, threaded under its forum post if any."
  (let ((thread (agent-shell-bridge-discord--session-thread)))
    (agent-shell-bridge-discord--with-wait
     (if thread
         (format "%s?thread_id=%s" agent-shell-bridge-discord-webhook-url thread)
       agent-shell-bridge-discord-webhook-url))))

(defun agent-shell-bridge-discord--edit-url (id)
  "The webhook edit URL for message ID, threaded under the forum post."
  (let ((thread (agent-shell-bridge-discord--session-thread)))
    (concat agent-shell-bridge-discord-webhook-url "/messages/" id
            (if thread (format "?thread_id=%s" thread) ""))))

(defun agent-shell-bridge-discord--post-permission (url content)
  "Post a permission CONTENT to URL synchronously, then add tappable ✅/❌.
Returns the message id so the reaction can be correlated to the request."
  (let ((id (funcall agent-shell-bridge-discord--post-fn url content)))
    (when (and id agent-shell-bridge-discord--react-fn)
      (let ((thread (agent-shell-bridge-discord--session-thread)))
        (funcall agent-shell-bridge-discord--react-fn thread id "✅")
        (funcall agent-shell-bridge-discord--react-fn thread id "❌")))
    id))

(defun agent-shell-bridge-discord--send (message)
  "Handle MESSAGE for the webhook.
Thinking and tool messages fold into this turn's activity summary; a
message with a file part uploads as an attachment (e.g. /transcript); a
permission posts synchronously and gets tappable ✅/❌ reactions; the
agent reply, user prompt and command replies post as normal messages.
Threads under the session's forum post."
  (unless agent-shell-bridge-discord-webhook-url
    (error "agent-shell-bridge-discord-webhook-url is not set"))
  (pcase (plist-get message :role)
    ('thinking (agent-shell-bridge-discord--act-note-thinking) nil)
    ('tool (agent-shell-bridge-discord--act-note-tool message) nil)
    (_
     (if-let* ((file (agent-shell-bridge-message-file message)))
         (funcall agent-shell-bridge-discord--upload-fn
                  (agent-shell-bridge-discord--target-url) (car file) (cdr file))
       (when-let* ((content (agent-shell-bridge-discord--render message)))
         (let ((url (agent-shell-bridge-discord--target-url)))
           (if (eq (plist-get message :role) 'permission)
               (agent-shell-bridge-discord--post-permission url content)
             (funcall agent-shell-bridge-discord--post-async-fn url content))))))))

;;; Forum: one post per session

(defun agent-shell-bridge-discord--curl-create (url json)
  "POST JSON to URL and return the response body string."
  (with-output-to-string
    (with-current-buffer standard-output
      (call-process "curl" nil t nil
                    "-s" "-X" "POST"
                    "-H" "Content-Type: application/json"
                    "-d" json url))))

(defvar agent-shell-bridge-discord--create-fn
  #'agent-shell-bridge-discord--curl-create
  "Function of (URL JSON) returning the response body.  Rebound in tests.")

(defun agent-shell-bridge-discord--create-post (title)
  "Create a forum post titled TITLE; return its thread id, or nil on failure."
  (let* ((url (concat agent-shell-bridge-discord-webhook-url "?wait=true"))
         (name (substring title 0 (min (length title) 100)))
         (json (json-encode `(("thread_name" . ,name)
                              ("content" . "🧵 Session started"))))
         (resp (funcall agent-shell-bridge-discord--create-fn url json))
         (data (ignore-errors (json-parse-string resp :object-type 'alist))))
    ;; The forum starter message's channel_id is the new thread id.
    (or (alist-get 'channel_id data) (alist-get 'id data))))

(defun agent-shell-bridge-discord--start-session (meta)
  "Open a forum post per session when forum mode is on; else a flat handle."
  (if agent-shell-bridge-discord-forum-p
      (or (agent-shell-bridge-discord--create-post
           (or (plist-get meta :title) (plist-get meta :name)
               "agent-shell session"))
          (progn (message "agent-shell-bridge: forum post creation failed")
                 'discord-webhook))
    'discord-webhook))

(defun agent-shell-bridge-discord-webhook-provider ()
  "Return the read-only Discord webhook provider."
  (agent-shell-bridge-provider-create
   :name 'discord-webhook
   :can-edit nil                        ; a webhook cannot edit; buffer + send once
   :start-session #'agent-shell-bridge-discord--start-session
   :send #'agent-shell-bridge-discord--send
   :edit #'ignore
   :delete #'ignore
   :on-inbound #'ignore
   :on-control #'ignore
   :stop #'ignore))

;;;###autoload
(defun agent-shell-bridge-discord-webhook-register ()
  "Register and select the Discord webhook provider."
  (interactive)
  (agent-shell-bridge-register-provider
   (agent-shell-bridge-discord-webhook-provider))
  (agent-shell-bridge-set-provider 'discord-webhook))

(provide 'agent-shell-bridge-discord)
;;; agent-shell-bridge-discord.el ends here
