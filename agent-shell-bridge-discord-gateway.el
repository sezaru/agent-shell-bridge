;;; agent-shell-bridge-discord-gateway.el --- Two-way Discord provider -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The gateway (bot) Discord provider: full two-way parity.  Outbound is
;; the REST API (so messages have ids we can edit / react to); inbound is
;; the Gateway websocket.  MESSAGE_CREATE in the session channel injects a
;; prompt; reactions map to the transport-neutral control vocabulary
;; (approve/deny/expand/collapse/full/hide/interrupt).
;;
;; The pure pieces -- opcode/payload builders, the event dispatch router,
;; reaction mapping, inbound routing, REST body construction -- are unit
;; tested.  The live connect/heartbeat loop needs a bot token and is
;; guarded behind `websocket'; it is exercised by manual verification, not
;; ERT.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'map)
(require 'url-util)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-provider)
(require 'agent-shell-bridge-discord)
(require 'websocket nil t)

;;;; Config

;; The bot token, channel id and REST transport live in
;; `agent-shell-bridge-discord' (the outbound half); this file is the
;; inbound half and reuses them.

(defcustom agent-shell-bridge-discord-guild-id nil
  "Discord server (guild) id, used to enumerate active forum posts."
  :type '(choice (const nil) string)
  :group 'agent-shell-bridge)

(defconst agent-shell-bridge-discord--gateway-url
  "wss://gateway.discord.gg/?v=10&encoding=json")

;;;; Gateway opcodes and intents

(defconst agent-shell-bridge-discord--op-dispatch 0)
(defconst agent-shell-bridge-discord--op-heartbeat 1)
(defconst agent-shell-bridge-discord--op-identify 2)
(defconst agent-shell-bridge-discord--op-resume 6)
(defconst agent-shell-bridge-discord--op-reconnect 7)
(defconst agent-shell-bridge-discord--op-invalid-session 9)
(defconst agent-shell-bridge-discord--op-hello 10)
(defconst agent-shell-bridge-discord--op-heartbeat-ack 11)

;; GUILD_MESSAGES(512) + GUILD_MESSAGE_REACTIONS(1024) + DIRECT_MESSAGES(4096)
;; + DIRECT_MESSAGE_REACTIONS(8192) + MESSAGE_CONTENT(32768) = 46592.
;; MESSAGE_CONTENT is a privileged intent; enable it in the dev portal.
(defconst agent-shell-bridge-discord--intents 46592
  "Gateway intents: guild+DM messages, reactions, and message content.")

;;;; Payload builders

(defun agent-shell-bridge-discord--identify-payload (token intents)
  "Build an IDENTIFY payload for TOKEN with INTENTS."
  `((op . ,agent-shell-bridge-discord--op-identify)
    (d . ((token . ,token)
          (intents . ,intents)
          (properties . ((os . "linux")
                         (browser . "agent-shell-bridge")
                         (device . "agent-shell-bridge")))))))

(defun agent-shell-bridge-discord--heartbeat-payload (seq)
  "Build a HEARTBEAT payload acknowledging sequence SEQ (may be nil)."
  `((op . ,agent-shell-bridge-discord--op-heartbeat)
    (d . ,seq)))

(defun agent-shell-bridge-discord--resume-payload (token session-id seq)
  "Build a RESUME payload for TOKEN, SESSION-ID at SEQ."
  `((op . ,agent-shell-bridge-discord--op-resume)
    (d . ((token . ,token)
          (session_id . ,session-id)
          (seq . ,seq)))))

;;;; Reaction -> control action

(defun agent-shell-bridge-discord--reaction-action (emoji)
  "Map a reaction EMOJI name to a transport-neutral control action, or nil."
  (pcase emoji
    ("✅" 'approve)
    ("❌" 'deny)
    ("👀" 'expand)
    ("🔽" 'collapse)
    ("📄" 'full)
    ("🙈" 'hide)
    ("🛑" 'interrupt)
    (_ nil)))

;;;; Gateway session state

(cl-defstruct (agent-shell-bridge-discord-gateway
               (:constructor agent-shell-bridge-discord-gateway-create)
               (:copier nil))
  token intents socket
  (seq nil) (session-id nil) (bot-user-id nil) (heartbeat-interval nil)
  (resume-url nil) on-inbound on-control)

;;;; Inbound / reaction routing (pure)

(defun agent-shell-bridge-discord--route-message-create (gw d)
  "Route a MESSAGE_CREATE payload D through GW's inbound callback.
Ignores the bot's own messages and empty content."
  (let* ((author (alist-get 'author d))
         (author-id (alist-get 'id author))
         (is-bot (eq (alist-get 'bot author) t))
         (content (alist-get 'content d))
         (channel (alist-get 'channel_id d))
         (cb (agent-shell-bridge-discord-gateway-on-inbound gw)))
    (when (and cb content (not (string-empty-p content))
               (not is-bot)
               (not (equal author-id
                           (agent-shell-bridge-discord-gateway-bot-user-id gw))))
      ;; Live message: the core decides (inject / refuse / command); mark the
      ;; message per that result so a later cold reconnect won't mistake a
      ;; handled message for offline backlog.
      (let ((result (funcall cb (list :text content :session channel))))
        (agent-shell-bridge-discord--mark-result
         channel (alist-get 'id d) result)))))

(defun agent-shell-bridge-discord--route-reaction (gw d)
  "Route a MESSAGE_REACTION_ADD/REMOVE payload D through GW's control callback."
  (let* ((emoji (alist-get 'name (alist-get 'emoji d)))
         (action (agent-shell-bridge-discord--reaction-action emoji))
         (msg-id (alist-get 'message_id d))
         (cb (agent-shell-bridge-discord-gateway-on-control gw)))
    ;; Ignore the bot's own marker reactions (✅/❌ it adds to user messages)
    ;; -- only a human's reaction is a control.
    (when (and cb action
               (not (equal (alist-get 'user_id d)
                           (agent-shell-bridge-discord-gateway-bot-user-id gw))))
      (funcall cb (list :action action :target msg-id
                        :session (alist-get 'channel_id d))))))

;;;; Event dispatch router (pure)

(defun agent-shell-bridge-discord--on-gateway-event (gw event)
  "Advance GW state from a decoded gateway EVENT.
Return a keyword describing the event so the live loop can react:
`:hello', `:dispatch', `:reconnect', `:invalid-session', or `:other'."
  (let ((op (alist-get 'op event))
        (seq (alist-get 's event))
        (type (alist-get 't event))
        (d (alist-get 'd event)))
    (when seq (setf (agent-shell-bridge-discord-gateway-seq gw) seq))
    (cond
     ((eql op agent-shell-bridge-discord--op-hello)
      (setf (agent-shell-bridge-discord-gateway-heartbeat-interval gw)
            (alist-get 'heartbeat_interval d))
      :hello)
     ((eql op agent-shell-bridge-discord--op-reconnect) :reconnect)
     ((eql op agent-shell-bridge-discord--op-invalid-session) :invalid-session)
     ((eql op agent-shell-bridge-discord--op-dispatch)
      (pcase type
        ("READY"
         (setf (agent-shell-bridge-discord-gateway-session-id gw)
               (alist-get 'session_id d)
               (agent-shell-bridge-discord-gateway-bot-user-id gw)
               (alist-get 'id (alist-get 'user d))
               (agent-shell-bridge-discord-gateway-resume-url gw)
               (alist-get 'resume_gateway_url d)))
        ("MESSAGE_CREATE"
         (agent-shell-bridge-discord--route-message-create gw d))
        ((or "MESSAGE_REACTION_ADD" "MESSAGE_REACTION_REMOVE")
         (agent-shell-bridge-discord--route-reaction gw d)))
      :dispatch)
     (t :other))))

;;;; REST send/edit/delete (the pure gateway provider posts to the channel root)

(defun agent-shell-bridge-discord-gateway--send (message)
  "POST flattened MESSAGE to the session channel; return the message id."
  (let* ((path (format "/channels/%s/messages"
                       agent-shell-bridge-discord-channel-id))
         (resp (agent-shell-bridge-discord--rest
                "POST" path
                `((content . ,(agent-shell-bridge-discord--flatten message))))))
    (alist-get 'id resp)))

(defun agent-shell-bridge-discord-gateway--edit (remote-id message)
  "Edit REMOTE-ID to the flattened MESSAGE via REST."
  (agent-shell-bridge-discord--rest
   "PATCH"
   (format "/channels/%s/messages/%s"
           agent-shell-bridge-discord-channel-id remote-id)
   `((content . ,(agent-shell-bridge-discord--flatten message)))))

(defun agent-shell-bridge-discord-gateway--delete (remote-id)
  "Delete REMOTE-ID via REST."
  (agent-shell-bridge-discord--rest
   "DELETE"
   (format "/channels/%s/messages/%s"
           agent-shell-bridge-discord-channel-id remote-id)))

;;;; Reaction markers: ✅ consumed, ❌ rejected
;; The `--react'/`--mark' primitives and their constants live in
;; `agent-shell-bridge-discord'; the policy on top of them is here.

(defun agent-shell-bridge-discord--bot-marked-p (message)
  "Non-nil if the bot already reacted ✅/❌ to MESSAGE."
  (seq-some (lambda (r)
              (and (eq (alist-get 'me r) t)
                   (member (alist-get 'name (alist-get 'emoji r))
                           (list agent-shell-bridge-discord--mark-consumed
                                 agent-shell-bridge-discord--mark-rejected))))
            (append (alist-get 'reactions message) nil)))

(defun agent-shell-bridge-discord--unprocessed-user-messages (messages)
  "Return the user-authored MESSAGES the bot has not yet marked.
These are the backlog typed while Emacs was offline -- to be rejected."
  (seq-filter
   (lambda (m)
     (and (not (eq (alist-get 'bot (alist-get 'author m)) t))
          (not (agent-shell-bridge-discord--bot-marked-p m))))
   (append messages nil)))

(defconst agent-shell-bridge-discord--command-mark "🛑")
(defconst agent-shell-bridge-discord--handled-mark "💬")

(defconst agent-shell-bridge-discord--reason-emoji
  '((busy . "⏳") (offline . "💤") (no-session . "❓"))
  "Maps a refusal reason to the emoji added alongside ❌.")

(defun agent-shell-bridge-discord--unreact (channel-id message-id emoji)
  "Remove the bot's EMOJI reaction from MESSAGE-ID in CHANNEL-ID."
  (agent-shell-bridge-discord--rest
   "DELETE"
   (format "/channels/%s/messages/%s/reactions/%s/@me"
           channel-id message-id (url-hexify-string emoji))))

(defun agent-shell-bridge-discord--mark-result (channel-id message-id result)
  "React to MESSAGE-ID per the dispatch RESULT plist."
  (pcase (plist-get result :status)
    ('ignore nil)                       ; not our post: leave no trace
    ('consumed (agent-shell-bridge-discord--mark channel-id message-id t))
    ('command (agent-shell-bridge-discord--react
               channel-id message-id
               (if (eq (plist-get result :action) 'interrupt)
                   agent-shell-bridge-discord--command-mark
                 agent-shell-bridge-discord--handled-mark)))
    ('refused
     (agent-shell-bridge-discord--mark channel-id message-id nil)
     (when-let* ((e (alist-get (plist-get result :reason)
                               agent-shell-bridge-discord--reason-emoji)))
       (agent-shell-bridge-discord--react channel-id message-id e)))))

;;;; Per-session running indicator (🟢 running / 💤 idle on the post)

(defconst agent-shell-bridge-discord--status-running "⚙️")
(defconst agent-shell-bridge-discord--status-idle "💤")

(defun agent-shell-bridge-discord--set-status (thread-id running)
  "Show RUNNING on the forum post THREAD-ID (starter message id == thread id)."
  (let ((on (if running agent-shell-bridge-discord--status-running
              agent-shell-bridge-discord--status-idle))
        (off (if running agent-shell-bridge-discord--status-idle
               agent-shell-bridge-discord--status-running)))
    (agent-shell-bridge-discord--unreact thread-id thread-id off)
    (agent-shell-bridge-discord--react thread-id thread-id on)))

(defun agent-shell-bridge-discord--reject-stale (channel-id)
  "Reject (❌) every unprocessed user message in CHANNEL-ID; return them.
Run on a cold reconnect: the client was offline, so these were never
consumed and must not be injected into a conversation that moved on."
  (let* ((resp (agent-shell-bridge-discord--rest
                "GET" (format "/channels/%s/messages?limit=50" channel-id)))
         (stale (agent-shell-bridge-discord--unprocessed-user-messages resp)))
    (dolist (m stale)
      (agent-shell-bridge-discord--mark channel-id (alist-get 'id m) nil))
    stale))

(defun agent-shell-bridge-discord--reject-relinked-backlog (handle)
  "Reject offline backlog in a just-relinked forum post HANDLE.
Runs on resume: messages typed into the post while Emacs was closed were
never processed, so they get ❌ (the same treatment as the cold-reconnect
sweep) instead of silently lingering unacknowledged."
  (when (stringp handle)
    (ignore-errors (agent-shell-bridge-discord--reject-stale handle))))

(defun agent-shell-bridge-discord--sweep-forum ()
  "Reject unprocessed backlog in this instance's OWN posts only.
Restricted to owned threads so a shared bot never touches another
instance's or session's posts."
  (dolist (thread (hash-table-keys agent-shell-bridge--session->buffer))
    (when (stringp thread)
      (ignore-errors (agent-shell-bridge-discord--reject-stale thread)))))

;;;; Live connection (guarded; not unit tested)

(defvar agent-shell-bridge-discord--gw nil
  "The active gateway session struct.")
(defvar agent-shell-bridge-discord--heartbeat-timer nil)
(defvar agent-shell-bridge-discord--swept nil
  "Non-nil once the offline-backlog sweep ran this Emacs session.")
(defvar agent-shell-bridge-discord--stopping nil
  "Non-nil while intentionally stopping, to suppress auto-reconnect.")

(defun agent-shell-bridge-discord--schedule-reconnect ()
  "Reconnect the gateway after a short delay unless we are stopping."
  (unless agent-shell-bridge-discord--stopping
    (run-at-time 5 nil
                 (lambda ()
                   (ignore-errors (agent-shell-bridge-discord-gateway-connect))))))

(defun agent-shell-bridge-discord--gw-send-json (gw payload)
  (websocket-send-text (agent-shell-bridge-discord-gateway-socket gw)
                       (json-encode payload)))

(defun agent-shell-bridge-discord--start-heartbeat (gw)
  (when agent-shell-bridge-discord--heartbeat-timer
    (cancel-timer agent-shell-bridge-discord--heartbeat-timer))
  (let ((secs (/ (agent-shell-bridge-discord-gateway-heartbeat-interval gw)
                 1000.0)))
    (setq agent-shell-bridge-discord--heartbeat-timer
          (run-at-time secs secs
                       (lambda ()
                         (agent-shell-bridge-discord--gw-send-json
                          gw (agent-shell-bridge-discord--heartbeat-payload
                              (agent-shell-bridge-discord-gateway-seq gw))))))))

(defun agent-shell-bridge-discord--gw-on-message (gw _ws frame)
  (let ((event (ignore-errors
                 (json-parse-string (websocket-frame-text frame)
                                    :object-type 'alist))))
    (when event
      (pcase (agent-shell-bridge-discord--on-gateway-event gw event)
        (:hello
         (agent-shell-bridge-discord--start-heartbeat gw)
         (agent-shell-bridge-discord--gw-send-json
          gw (agent-shell-bridge-discord--identify-payload
              (agent-shell-bridge-discord-gateway-token gw)
              (agent-shell-bridge-discord-gateway-intents gw))))
        (:dispatch
         ;; First READY of this Emacs session: reject anything typed while
         ;; the bot was offline before we started listening live.
         (when (and (equal (alist-get 't event) "READY")
                    (not agent-shell-bridge-discord--swept))
           (setq agent-shell-bridge-discord--swept t)
           (ignore-errors (agent-shell-bridge-discord--sweep-forum))))
        (:reconnect (agent-shell-bridge-discord-gateway-connect))
        (:invalid-session (agent-shell-bridge-discord-gateway-connect))))))

(defun agent-shell-bridge-discord-gateway-connect ()
  "Open the Discord gateway websocket.  Requires `websocket'."
  (unless (featurep 'websocket)
    (error "The `websocket' package is required for the gateway provider"))
  (unless agent-shell-bridge-discord-bot-token
    (error "agent-shell-bridge-discord-bot-token is not set"))
  (setq agent-shell-bridge-discord--stopping nil)
  (let ((gw (or agent-shell-bridge-discord--gw
                (setq agent-shell-bridge-discord--gw
                      (agent-shell-bridge-discord-gateway-create
                       :token agent-shell-bridge-discord-bot-token
                       :intents agent-shell-bridge-discord--intents)))))
    (setf (agent-shell-bridge-discord-gateway-socket gw)
          (websocket-open
           agent-shell-bridge-discord--gateway-url
           :on-message (lambda (ws frame)
                         (agent-shell-bridge-discord--gw-on-message gw ws frame))
           :on-close (lambda (_ws)
                       (when agent-shell-bridge-discord--heartbeat-timer
                         (cancel-timer agent-shell-bridge-discord--heartbeat-timer)
                         (setq agent-shell-bridge-discord--heartbeat-timer nil))
                       (message "agent-shell-bridge: Discord gateway closed%s"
                                (if agent-shell-bridge-discord--stopping ""
                                  " (check the Message Content intent); reconnecting in 5s"))
                       (agent-shell-bridge-discord--schedule-reconnect))
           :on-error (lambda (_ws type err)
                       (message "agent-shell-bridge: Discord gateway error: %s %S"
                                type err))))
    gw))

(defun agent-shell-bridge-discord-gateway--stop ()
  (setq agent-shell-bridge-discord--stopping t)
  (when agent-shell-bridge-discord--heartbeat-timer
    (cancel-timer agent-shell-bridge-discord--heartbeat-timer)
    (setq agent-shell-bridge-discord--heartbeat-timer nil))
  (when (and agent-shell-bridge-discord--gw
             (agent-shell-bridge-discord-gateway-socket
              agent-shell-bridge-discord--gw))
    (websocket-close (agent-shell-bridge-discord-gateway-socket
                      agent-shell-bridge-discord--gw)))
  (setq agent-shell-bridge-discord--gw nil))

;;;; Provider

(defun agent-shell-bridge-discord-gateway-provider ()
  "Return the two-way Discord gateway provider."
  (agent-shell-bridge-provider-create
   :name 'discord-gateway
   :can-edit t
   :start-session (lambda (_meta)
                    (agent-shell-bridge-discord-gateway-connect)
                    'discord-gateway)
   :send #'agent-shell-bridge-discord-gateway--send
   :edit #'agent-shell-bridge-discord-gateway--edit
   :delete #'agent-shell-bridge-discord-gateway--delete
   :on-inbound (lambda (cb)
                 (when agent-shell-bridge-discord--gw
                   (setf (agent-shell-bridge-discord-gateway-on-inbound
                          agent-shell-bridge-discord--gw)
                         cb)))
   :on-control (lambda (cb)
                 (when agent-shell-bridge-discord--gw
                   (setf (agent-shell-bridge-discord-gateway-on-control
                          agent-shell-bridge-discord--gw)
                         cb)))
   :stop #'agent-shell-bridge-discord-gateway--stop))

;;;###autoload
(defun agent-shell-bridge-discord-gateway-register ()
  "Register and select the two-way Discord gateway provider."
  (interactive)
  (agent-shell-bridge-register-provider
   (agent-shell-bridge-discord-gateway-provider))
  (agent-shell-bridge-set-provider 'discord-gateway))

;;;; Hybrid provider: bot REST out (forum posts) + gateway in (listen/react)

(defun agent-shell-bridge-discord--store-inbound (cb)
  (when agent-shell-bridge-discord--gw
    (setf (agent-shell-bridge-discord-gateway-on-inbound
           agent-shell-bridge-discord--gw) cb)))

(defun agent-shell-bridge-discord--store-control (cb)
  (when agent-shell-bridge-discord--gw
    (setf (agent-shell-bridge-discord-gateway-on-control
           agent-shell-bridge-discord--gw) cb)))

(defun agent-shell-bridge-discord-provider ()
  "Return the hybrid Discord provider: bot REST output, gateway listener."
  (agent-shell-bridge-provider-create
   :name 'discord
   :can-edit nil                        ; buffer + post once on turn complete
   :start-session #'agent-shell-bridge-discord--start-session
   :send #'agent-shell-bridge-discord--send
   :edit #'ignore
   :delete #'ignore
   :on-inbound #'agent-shell-bridge-discord--store-inbound
   :on-control #'agent-shell-bridge-discord--store-control
   :set-status (lambda (handle running)
                 ;; Turn boundary: a new turn resets the activity summary, a
                 ;; finished turn settles it to past tense.  Runs in the
                 ;; agent-shell buffer, so its buffer-local state is in scope.
                 (if running
                     (agent-shell-bridge-discord--act-reset)
                   (agent-shell-bridge-discord--act-finalize))
                 (when (stringp handle)
                   (agent-shell-bridge-discord--set-status handle running)))
   :stop #'agent-shell-bridge-discord-gateway--stop))

;;;###autoload
(defun agent-shell-bridge-discord-register ()
  "Register + select the hybrid provider and connect the bot listener."
  (interactive)
  (agent-shell-bridge-register-provider (agent-shell-bridge-discord-provider))
  (agent-shell-bridge-set-provider 'discord)
  ;; On resume, reject whatever was typed into the post while we were closed.
  (add-hook 'agent-shell-bridge--relink-functions
            #'agent-shell-bridge-discord--reject-relinked-backlog)
  (when (and agent-shell-bridge-discord-bot-token (featurep 'websocket))
    (ignore-errors (agent-shell-bridge-discord-gateway-connect))))

(provide 'agent-shell-bridge-discord-gateway)
;;; agent-shell-bridge-discord-gateway.el ends here
