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

;;;; Flattening

;; Rendering mirrors agent-shell's collapsed layout so the channel stays
;; scannable: the agent's actual message and a compact tool header are shown
;; plainly, while thinking and tool output are collapsed behind spoilers
;; (Discord's closest analogue) -- click to expand.

(defun agent-shell-bridge-discord--status-emoji (status)
  (pcase status
    ('success "✅")
    ('error "❌")
    ('pending "⏳")
    ('streaming "⏳")
    (_ "🔧")))

(defun agent-shell-bridge-discord--header (message)
  "Role header line for MESSAGE."
  (pcase (plist-get message :role)
    ('agent "🤖 **Agent**")
    ('user "🧑 **User**")
    ('thinking "💭 **Thinking** *(expand)*")
    ('permission "⚠️ **Permission Required**")
    ('tool (format "%s **Tool**"
                   (agent-shell-bridge-discord--status-emoji
                    (plist-get message :status))))
    (_ "ℹ️ **System**")))

(defun agent-shell-bridge-discord--spoiler (s)
  "Wrap S in a Discord spoiler (collapsed, click to reveal)."
  (concat "||" s "||"))

(defun agent-shell-bridge-discord--one-line (s)
  "Collapse whitespace in S to a compact single line."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " s)))

(defun agent-shell-bridge-discord--render-body (message text)
  "Render TEXT of MESSAGE with per-role collapse rules."
  (let ((role (plist-get message :role))
        (status (plist-get message :status)))
    (cond
     ((string-empty-p (string-trim text)) "")
     ;; Thinking: collapse everything behind a spoiler.
     ((or (eq role 'thinking) (plist-get message :collapsible))
      (agent-shell-bridge-discord--spoiler text))
     ;; Tool: a starting call shows the command compactly; a finished call
     ;; collapses its (often large) output behind a spoiler.
     ((eq role 'tool)
      (if (eq status 'pending)
          (format "`%s`" (agent-shell-bridge-discord--one-line text))
        (agent-shell-bridge-discord--spoiler
         (format "```\n%s\n```" text))))
     ;; Agent / user / permission: the point of the message -- shown plainly.
     (t text))))

(defun agent-shell-bridge-discord--flatten (message &optional max-len)
  "Flatten MESSAGE to a single Discord message string of at most MAX-LEN chars.
Thinking and tool output collapse behind spoilers; overflow is hard
truncated with a marker before wrapping (so fences/spoilers stay balanced)."
  (let* ((max-len (or max-len agent-shell-bridge-discord-max-length))
         (header (agent-shell-bridge-discord--header message))
         (marker agent-shell-bridge-discord--truncation-marker)
         (budget (- max-len (length header)
                    agent-shell-bridge-discord--body-overhead))
         (text (agent-shell-bridge-message-text message)))
    (when (> (length text) budget)
      (setq text (concat (substring text 0 (max 0 (- budget (length marker))))
                         marker)))
    (concat header "\n"
            (agent-shell-bridge-discord--render-body message text))))

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
Rebound in tests.")

(defun agent-shell-bridge-discord--with-wait (url)
  "Append the wait=true query param to URL so the POST returns the message."
  (concat url (if (string-search "?" url) "&" "?") "wait=true"))

(defun agent-shell-bridge-discord--session-thread ()
  "The current buffer's forum thread id, if any."
  (let ((h (and (boundp 'agent-shell-bridge--session-handle)
                agent-shell-bridge--session-handle)))
    (and (stringp h) h)))

(defun agent-shell-bridge-discord--send (message)
  "Flatten MESSAGE and POST it to the configured webhook.  Returns nil.
When the session opened a forum post, thread the message under it."
  (unless agent-shell-bridge-discord-webhook-url
    (error "agent-shell-bridge-discord-webhook-url is not set"))
  (let* ((thread (agent-shell-bridge-discord--session-thread))
         (url (agent-shell-bridge-discord--with-wait
               (if thread
                   (format "%s?thread_id=%s"
                           agent-shell-bridge-discord-webhook-url thread)
                 agent-shell-bridge-discord-webhook-url))))
    (funcall agent-shell-bridge-discord--post-fn
             url (agent-shell-bridge-discord--flatten message))))

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
