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

(defcustom agent-shell-bridge-discord-thinking-limit 600
  "Max chars of thinking shown (collapsed) before it is truncated.
Keeps the spoiler a small bar instead of a wall of grey."
  :type 'integer
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

;; Rendering mirrors agent-shell's collapsed layout so the channel stays
;; scannable instead of a wall of grey.  The agent's reply and the user's
;; prompt are shown plainly; a tool call is a single command line.  Its
;; output is kept -- short output inline in a plain code block, larger
;; output as a *file attachment* (Discord's one true collapse: a compact
;; card you click to expand), rather than a giant spoiler box.  Thinking is
;; one small inline spoiler.  Anything with no signal (an in-progress tool
;; update, an empty finished one) renders to nil and is not posted.
;;
;; `--render' is the entry point: it returns either a content string, an
;; attachment plist `(:file NAME :data DATA :caption CAP)', or nil.
;; `--flatten' handles only the string (text) roles and is what the gateway
;; REST path uses directly.

(defconst agent-shell-bridge-discord--inline-output-max 500
  "Tool output at or under this many chars/8 lines is shown inline.")

(defun agent-shell-bridge-discord--header (message)
  "Role header line for MESSAGE (agent/user/permission/system only)."
  (pcase (plist-get message :role)
    ('agent "🤖 **Agent**")
    ('user "🧑 **User**")
    ('permission "⚠️ **Permission Required**")
    (_ "ℹ️ **System**")))

(defun agent-shell-bridge-discord--spoiler (s)
  "Wrap S in a Discord spoiler (collapsed, click to reveal)."
  (concat "||" s "||"))

(defun agent-shell-bridge-discord--one-line (s)
  "Collapse whitespace in S to a compact single line."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " s)))

(defun agent-shell-bridge-discord--truncate (s limit)
  "Truncate S to LIMIT chars with an ellipsis."
  (if (> (length s) limit)
      (concat (substring s 0 (max 0 limit)) "…")
    s))

(defun agent-shell-bridge-discord--short-output-p (text)
  "Non-nil if TEXT is small enough to show inline rather than attach."
  (and (<= (length text) agent-shell-bridge-discord--inline-output-max)
       (<= (cl-count ?\n text) 8)))

(defun agent-shell-bridge-discord--tool-render (message)
  "Render a tool MESSAGE: a string, an attachment plist, or nil.
Pending shows the command; a finished call shows its output inline (small)
or as a file attachment (large); in-progress updates are dropped."
  (let ((status (plist-get message :status))
        (text (string-trim (agent-shell-bridge-message-text message))))
    (pcase status
      ('pending
       (unless (string-empty-p text)
         (format "🔧 `%s`" (agent-shell-bridge-discord--one-line text))))
      ((or 'success 'error 'failed)
       (let ((mark (if (memq status '(error failed)) "❌" "✅")))
         (cond
          ((string-empty-p text)
           (and (equal mark "❌") "❌ `(failed)`"))
          ((agent-shell-bridge-discord--short-output-p text)
           (format "%s\n```\n%s\n```" mark text))
          (t (list :file (if (equal mark "❌") "error.txt" "output.txt")
                   :data text :caption mark)))))
      ;; in-progress tool update: nothing to show yet.
      (_ nil))))

(defun agent-shell-bridge-discord--flatten (message &optional max-len)
  "Flatten a text-role MESSAGE to a Discord string, or nil.
Handles agent/user/permission/system (plain, truncated to MAX-LEN) and
thinking (a compact inline spoiler).  Tool messages are handled by
`--render'/`--tool-render' instead."
  (let* ((max-len (or max-len agent-shell-bridge-discord-max-length))
         (role (plist-get message :role))
         (text (string-trim (agent-shell-bridge-message-text message))))
    (pcase role
      ('thinking
       (unless (string-empty-p text)
         (concat "💭 "
                 (agent-shell-bridge-discord--spoiler
                  (agent-shell-bridge-discord--truncate
                   text agent-shell-bridge-discord-thinking-limit)))))
      ('tool (agent-shell-bridge-discord--tool-render message))
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
  "Return the Discord payload for a message: a string, an attachment plist
`(:file NAME :data DATA :caption CAP)', or nil to suppress.")

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

(defun agent-shell-bridge-discord--curl-upload-async (url caption name data)
  "Fire-and-forget multipart POST attaching DATA as file NAME to URL.
CAPTION is the message content shown beside the file card.  Returns nil."
  (let ((tmp (make-temp-file "asb-discord-" nil ".txt" data)))
    (condition-case _
        (make-process
         :name "asb-discord-upload" :noquery t :buffer nil
         :sentinel (lambda (_p _e) (ignore-errors (delete-file tmp)))
         :command (list "curl" "-s" "-X" "POST"
                        "-F" (format "payload_json=%s"
                                     (json-encode `(("content" . ,(or caption "")))))
                        "-F" (format "files[0]=@%s;filename=%s;type=text/plain"
                                     tmp name)
                        url))
      (error (ignore-errors (delete-file tmp)))))
  nil)

(defvar agent-shell-bridge-discord--upload-fn
  #'agent-shell-bridge-discord--curl-upload-async
  "Function of (URL CAPTION NAME DATA) uploading a file.  Rebound in tests.")

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

(defun agent-shell-bridge-discord--send (message)
  "Render MESSAGE and POST it to the configured webhook.
Renders to nil (not posted), an attachment plist (uploaded as a file
card, async), or a content string.  Permission strings post synchronously
\(their id correlates the ✅/❌ reaction); every other string fires async so
hitting Enter stays snappy.  Threads under the session's forum post."
  (unless agent-shell-bridge-discord-webhook-url
    (error "agent-shell-bridge-discord-webhook-url is not set"))
  (when-let* ((payload (agent-shell-bridge-discord--render message)))
    (let ((url (agent-shell-bridge-discord--target-url)))
      (pcase payload
        ((and (pred listp) (guard (plist-get payload :file)))
         (funcall agent-shell-bridge-discord--upload-fn
                  url (plist-get payload :caption)
                  (plist-get payload :file) (plist-get payload :data)))
        ((pred stringp)
         (if (eq (plist-get message :role) 'permission)
             (funcall agent-shell-bridge-discord--post-fn url payload)
           (funcall agent-shell-bridge-discord--post-async-fn url payload)))))))

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
