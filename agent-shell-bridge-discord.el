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

(defconst agent-shell-bridge-discord-max-length 2000
  "Discord's per-message character cap.")

(defconst agent-shell-bridge-discord--truncation-marker "\n… **[truncated]**"
  "Appended when a flattened message overflows the cap.")

(defconst agent-shell-bridge-discord--reserve 8
  "Safety margin (chars) kept free for fence balancing / multibyte drift.")

;;;; Flattening

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
    ('thinking "💭 **Thinking**")
    ('permission "⚠️ **Permission Required**")
    ('tool (format "%s **Tool**"
                   (agent-shell-bridge-discord--status-emoji
                    (plist-get message :status))))
    (_ "ℹ️ **System**")))

(defun agent-shell-bridge-discord--render-part (part)
  "Render a message PART to Discord markdown."
  (let ((content (or (plist-get part :content) "")))
    (pcase (plist-get part :kind)
      ('diff (format "```diff\n%s\n```" content))
      ((or 'code 'tool-call) (if (string-empty-p content)
                                 ""
                               (format "```\n%s\n```" content)))
      (_ content))))

(defun agent-shell-bridge-discord--body (message)
  "Concatenate rendered non-empty parts of MESSAGE."
  (mapconcat #'identity
             (seq-remove #'string-empty-p
                         (mapcar #'agent-shell-bridge-discord--render-part
                                 (plist-get message :parts)))
             "\n"))

(defun agent-shell-bridge-discord--balance-fences (s)
  "Append a closing code fence to S if it has an odd number of them."
  (let ((n 0) (start 0))
    (while (string-match "```" s start)
      (setq n (1+ n) start (match-end 0)))
    (if (cl-oddp n) (concat s "\n```") s)))

(defun agent-shell-bridge-discord--flatten (message &optional max-len)
  "Flatten MESSAGE to a single Discord message string of at most MAX-LEN chars.
Thinking / collapsible content is wrapped in a spoiler; overflow is hard
truncated with a marker."
  (let* ((max-len (or max-len agent-shell-bridge-discord-max-length))
         (header (agent-shell-bridge-discord--header message))
         (collapsible (or (plist-get message :collapsible)
                          (eq (plist-get message :role) 'thinking)))
         (body (agent-shell-bridge-discord--body message))
         (marker agent-shell-bridge-discord--truncation-marker)
         (wrap (if collapsible 4 0))       ; leading + trailing "||"
         (budget (- max-len (length header) 1 wrap
                    agent-shell-bridge-discord--reserve)))
    (when (> (length body) budget)
      (setq body (agent-shell-bridge-discord--balance-fences
                  (concat (substring body 0 (max 0 (- budget (length marker))))
                          marker))))
    (when collapsible
      (setq body (concat "||" body "||")))
    (concat header "\n" body)))

;;;; Transport

(defun agent-shell-bridge-discord--curl-post (url content)
  "POST CONTENT as a Discord message to webhook URL via curl."
  (let ((json (json-encode `(("content" . ,content)))))
    (call-process "curl" nil nil nil
                  "-s" "-X" "POST"
                  "-H" "Content-Type: application/json"
                  "-d" json url)))

(defvar agent-shell-bridge-discord--post-fn
  #'agent-shell-bridge-discord--curl-post
  "Function of (URL CONTENT) that performs the POST.  Rebound in tests.")

(defun agent-shell-bridge-discord--send (message)
  "Flatten MESSAGE and POST it to the configured webhook.  Returns nil."
  (unless agent-shell-bridge-discord-webhook-url
    (error "agent-shell-bridge-discord-webhook-url is not set"))
  (funcall agent-shell-bridge-discord--post-fn
           agent-shell-bridge-discord-webhook-url
           (agent-shell-bridge-discord--flatten message))
  nil)

(defun agent-shell-bridge-discord-webhook-provider ()
  "Return the read-only Discord webhook provider."
  (agent-shell-bridge-provider-create
   :name 'discord-webhook
   :start-session (lambda (_meta) 'discord-webhook)
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
