;;; agent-shell-bridge.el --- Mirror agent-shell to a remote surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Eduardo Barreto Alexandre
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Core of the bridge: capture an `agent-shell' session (ACP session
;; notifications + permission requests), normalize each update into a
;; structured message, and dispatch to the active provider.  Streaming
;; agent/thought chunks coalesce into a single message that is edited in
;; place until a turn boundary flushes it.
;;
;; The capture layer is harvested from ElleNajt/agent-shell-to-go with
;; every transport (Slack) reference removed: all sends now go through
;; the provider seam.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'agent-shell-bridge-provider)

;;;; Structured message model

(cl-defun agent-shell-bridge-make-part (&key kind content meta)
  "Build a message part.
KIND is one of `text', `code', `diff', `tool-call', `image'.
CONTENT is the payload; META is an optional plist of extras."
  (list :kind kind :content content :meta meta))

(cl-defun agent-shell-bridge-make-message (&key id role status collapsible parts session)
  "Build a structured bridge message.
ROLE is `agent', `user', `tool', `thinking', `permission' or `system'.
STATUS is `streaming', `complete', `success', `error' or `pending'.
COLLAPSIBLE marks default-collapsed content (thinking).  PARTS is a
list of `agent-shell-bridge-make-part' plists.  ID correlates edits;
SESSION is the provider session handle."
  (list :id id :role role :status status :collapsible collapsible
        :parts parts :session session))

(defun agent-shell-bridge-message-text (message)
  "Concatenate the text content of every part in MESSAGE."
  (mapconcat (lambda (part)
               (let ((c (plist-get part :content)))
                 (if (stringp c) c "")))
             (plist-get message :parts)
             ""))

;;;; Normalizer: ACP session update -> structured message

(defun agent-shell-bridge--content-text (content)
  "Text of an ACP CONTENT block (a text content block or plain string)."
  (cond
   ((stringp content) content)
   ((null content) nil)
   (t (or (alist-get 'text content)
          (alist-get 'text (alist-get 'content content))))))

(defun agent-shell-bridge--tool-output (update)
  "Best-effort textual output of a tool_call_update UPDATE."
  (let* ((content (alist-get 'content update))
         (items (cond ((vectorp content) (append content nil))
                      ((listp content) content)
                      (t nil)))
         (joined (and items
                      (mapconcat
                       (lambda (item)
                         (or (alist-get 'text (alist-get 'content item))
                             (alist-get 'text item)
                             ""))
                       items "\n"))))
    (or (alist-get 'rawOutput update)
        (alist-get 'output update)
        (and joined (> (length joined) 0) joined))))

(defun agent-shell-bridge--normalize-update (update)
  "Map an ACP session UPDATE alist to a structured message, or nil.

UPDATE is the value of (params update) in an ACP session notification."
  (pcase (alist-get 'sessionUpdate update)
    ("agent_message_chunk"
     (agent-shell-bridge-make-message
      :role 'agent :status 'streaming
      :parts (list (agent-shell-bridge-make-part
                    :kind 'text
                    :content (agent-shell-bridge--content-text
                              (alist-get 'content update))))))
    ("agent_thought_chunk"
     (agent-shell-bridge-make-message
      :role 'thinking :status 'streaming :collapsible t
      :parts (list (agent-shell-bridge-make-part
                    :kind 'text
                    :content (agent-shell-bridge--content-text
                              (alist-get 'content update))))))
    ("user_message_chunk"
     (agent-shell-bridge-make-message
      :role 'user :status 'complete
      :parts (list (agent-shell-bridge-make-part
                    :kind 'text
                    :content (agent-shell-bridge--content-text
                              (alist-get 'content update))))))
    ("tool_call"
     (let* ((id (alist-get 'toolCallId update))
            (title (alist-get 'title update))
            (raw (alist-get 'rawInput update))
            (command (alist-get 'command raw)))
       (agent-shell-bridge-make-message
        :id id :role 'tool :status 'pending
        :parts (list (agent-shell-bridge-make-part
                      :kind 'tool-call
                      :content (or command title "")
                      :meta (list :tool-call-id id :title title
                                  :command command
                                  :raw-input raw
                                  :content (alist-get 'content update)))))))
    ("tool_call_update"
     (let* ((id (alist-get 'toolCallId update))
            (status (alist-get 'status update))
            (output (agent-shell-bridge--tool-output update)))
       (agent-shell-bridge-make-message
        :id id :role 'tool
        :status (pcase status
                  ("completed" 'success)
                  ("failed" 'error)
                  (_ 'streaming))
        :parts (list (agent-shell-bridge-make-part
                      :kind 'tool-call
                      :content (or output "")
                      :meta (list :tool-call-id id :status status))))))
    (_ nil)))

(defun agent-shell-bridge--normalize-permission (request)
  "Map an ACP permission REQUEST alist to a `permission' message."
  (let* ((params (alist-get 'params request))
         (tool-call (alist-get 'toolCall params))
         (title (alist-get 'title tool-call))
         (raw (alist-get 'rawInput tool-call))
         (command (alist-get 'command raw)))
    (agent-shell-bridge-make-message
     :id (alist-get 'id request)
     :role 'permission :status 'pending
     :parts (list (agent-shell-bridge-make-part
                   :kind 'text
                   :content (or command title "Permission required")
                   :meta (list :options (alist-get 'options params)
                               :request-id (alist-get 'id request)))))))

;;;; Provider dispatch

(defun agent-shell-bridge--require-provider ()
  "Return the active provider or signal if none is set."
  (or (agent-shell-bridge-active-provider)
      (error "No active agent-shell-bridge provider")))

(defun agent-shell-bridge--send (message)
  "Send MESSAGE via the active provider; return its remote id."
  (funcall (agent-shell-bridge-provider-send
            (agent-shell-bridge--require-provider))
           message))

(defun agent-shell-bridge--edit (remote-id message)
  "Edit REMOTE-ID to MESSAGE via the active provider."
  (funcall (agent-shell-bridge-provider-edit
            (agent-shell-bridge--require-provider))
           remote-id message))

;;;; Streaming accumulator (buffer-local session state)

(defvar-local agent-shell-bridge--stream-id nil
  "Remote id of the open streaming message, if any.")
(defvar-local agent-shell-bridge--stream-role nil
  "Role of the open streaming message.")
(defvar-local agent-shell-bridge--stream-text nil
  "Accumulated text of the open streaming message.")

(defun agent-shell-bridge--flush-stream ()
  "Mark the open streaming message complete and clear stream state."
  (when agent-shell-bridge--stream-id
    (agent-shell-bridge--edit
     agent-shell-bridge--stream-id
     (agent-shell-bridge-make-message
      :id agent-shell-bridge--stream-id
      :role agent-shell-bridge--stream-role
      :status 'complete
      :collapsible (eq agent-shell-bridge--stream-role 'thinking)
      :parts (list (agent-shell-bridge-make-part
                    :kind 'text :content agent-shell-bridge--stream-text)))))
  (setq agent-shell-bridge--stream-id nil
        agent-shell-bridge--stream-role nil
        agent-shell-bridge--stream-text nil))

(defun agent-shell-bridge--feed (message)
  "Dispatch MESSAGE, coalescing consecutive streaming chunks in place."
  (let ((role (plist-get message :role))
        (status (plist-get message :status)))
    (cond
     ;; Streaming agent/thought chunk: coalesce.
     ((and (eq status 'streaming) (memq role '(agent thinking)))
      (let ((text (agent-shell-bridge-message-text message)))
        (if (and agent-shell-bridge--stream-id
                 (eq agent-shell-bridge--stream-role role))
            (progn
              (setq agent-shell-bridge--stream-text
                    (concat agent-shell-bridge--stream-text text))
              (agent-shell-bridge--edit
               agent-shell-bridge--stream-id
               (agent-shell-bridge-make-message
                :id agent-shell-bridge--stream-id :role role :status 'streaming
                :collapsible (eq role 'thinking)
                :parts (list (agent-shell-bridge-make-part
                              :kind 'text
                              :content agent-shell-bridge--stream-text)))))
          (agent-shell-bridge--flush-stream)
          (setq agent-shell-bridge--stream-role role
                agent-shell-bridge--stream-text text
                agent-shell-bridge--stream-id
                (agent-shell-bridge--send
                 (agent-shell-bridge-make-message
                  :role role :status 'streaming
                  :collapsible (eq role 'thinking)
                  :parts (list (agent-shell-bridge-make-part
                                :kind 'text :content text))))))))
     ;; Anything else: flush the open stream first, then send discretely.
     (t
      (agent-shell-bridge--flush-stream)
      (agent-shell-bridge--send message)))))

;;;; Inbound injection and control (remote -> agent-shell)

(defvar agent-shell-bridge--session->buffer (make-hash-table :test 'equal)
  "Map a provider session-handle to its agent-shell buffer.")

(defvar-local agent-shell-bridge--session-handle nil
  "This buffer's provider session handle.")

(defvar-local agent-shell-bridge--from-remote nil
  "Non-nil while injecting a remote prompt, to avoid echo loops.")

(defun agent-shell-bridge--active-buffers ()
  "Buffers with `agent-shell-bridge-mode' enabled."
  (seq-filter (lambda (b) (buffer-local-value 'agent-shell-bridge-mode b))
              (buffer-list)))

(defun agent-shell-bridge--buffer-for-session (session)
  "Resolve SESSION handle to a buffer, falling back to the sole bridged one."
  (or (gethash session agent-shell-bridge--session->buffer)
      (car (agent-shell-bridge--active-buffers))))

(defun agent-shell-bridge-inject (text &optional buffer)
  "Inject TEXT as a prompt into BUFFER (an `agent-shell' buffer).
Queues when the shell is busy."
  (with-current-buffer (or buffer (current-buffer))
    (when (derived-mode-p 'agent-shell-mode)
      (if (and (fboundp 'shell-maker-busy) (shell-maker-busy))
          (when (fboundp 'agent-shell--enqueue-request)
            (agent-shell--enqueue-request :prompt text))
        (setq agent-shell-bridge--from-remote t)
        (save-excursion (goto-char (point-max)) (insert text))
        (goto-char (point-max))
        (when (fboundp 'shell-maker-submit)
          (call-interactively #'shell-maker-submit))))))

(defun agent-shell-bridge--dispatch-inbound (event)
  "Handle an inbound EVENT (:text :session) by injecting into its buffer."
  (let ((buffer (agent-shell-bridge--buffer-for-session
                 (plist-get event :session))))
    (when (buffer-live-p buffer)
      (agent-shell-bridge-inject (plist-get event :text) buffer))))

;;; Permission requests mirrored to the remote await a control action.

(defvar agent-shell-bridge--pending-permissions nil
  "Alist of remote-msg-id -> (:request-id :buffer :options).")

(defun agent-shell-bridge--find-option-id (options action)
  "Return the ACP option id in OPTIONS matching ACTION (approve/always/deny)."
  (cl-loop for opt in (append options nil)
           for id = (or (alist-get 'optionId opt) (alist-get 'id opt))
           for kind = (alist-get 'kind opt)
           when (pcase action
                  ('approve (member kind '("allow" "accept" "allow_once")))
                  ('always  (member kind '("always" "alwaysAllow" "allow_always")))
                  ('deny    (member kind '("deny" "reject" "reject_once"))))
           return id))

(defun agent-shell-bridge--resolve-permission (remote-id action)
  "Resolve the pending permission for REMOTE-ID with ACTION."
  (when-let* ((entry (assoc remote-id agent-shell-bridge--pending-permissions))
              (info (cdr entry))
              (buffer (plist-get info :buffer)))
    (when (and (buffer-live-p buffer)
               (fboundp 'agent-shell--send-permission-response))
      (when-let* ((option-id (agent-shell-bridge--find-option-id
                              (plist-get info :options) action)))
        (with-current-buffer buffer
          (let ((state (bound-and-true-p agent-shell--state)))
            (agent-shell--send-permission-response
             :client (alist-get :client state)
             :request-id (plist-get info :request-id)
             :option-id option-id
             :state state)))
        (setq agent-shell-bridge--pending-permissions
              (assoc-delete-all remote-id
                                agent-shell-bridge--pending-permissions))))))

(defun agent-shell-bridge-handle-control (event)
  "Handle a remote control EVENT (:action :target :session).
Approve/deny resolve permissions; interrupt stops the agent.  Expansion
actions (expand/collapse/full/hide) are provider-side concerns."
  (let ((action (plist-get event :action))
        (target (plist-get event :target)))
    (pcase action
      ((or 'approve 'deny)
       (agent-shell-bridge--resolve-permission target action))
      ('interrupt
       (dolist (b (agent-shell-bridge--active-buffers))
         (with-current-buffer b
           (when (fboundp 'agent-shell-interrupt)
             (ignore-errors (agent-shell-interrupt t)))))))))

;;;; Capture layer (advice around agent-shell internals)

(defun agent-shell-bridge--on-notification (orig-fn &rest args)
  "Around-advice for `agent-shell--on-notification'.
Normalize the session update and feed it to the active provider.
ORIG-FN and ARGS are the advised call."
  (let* ((state (plist-get args :state))
         (buffer (alist-get :buffer state)))
    (when (and buffer (buffer-live-p buffer)
               (buffer-local-value 'agent-shell-bridge-mode buffer))
      (let* ((notification (plist-get args :acp-notification))
             (update (map-nested-elt notification '(params update)))
             (message (and update (agent-shell-bridge--normalize-update update))))
        (when message
          (with-current-buffer buffer
            (agent-shell-bridge--feed message))))))
  (apply orig-fn args))

(defun agent-shell-bridge--on-request (orig-fn &rest args)
  "Around-advice for `agent-shell--on-request'.
Mirror permission requests to the active provider.
ORIG-FN and ARGS are the advised call."
  (let* ((state (plist-get args :state))
         (request (plist-get args :acp-request))
         (buffer (and state (alist-get :buffer state))))
    (when (and buffer (buffer-live-p buffer)
               (buffer-local-value 'agent-shell-bridge-mode buffer)
               (equal (alist-get 'method request) "session/request_permission"))
      (with-current-buffer buffer
        (agent-shell-bridge--flush-stream)
        (let ((remote-id (agent-shell-bridge--send
                          (agent-shell-bridge--normalize-permission request))))
          (when remote-id
            (push (cons remote-id
                        (list :request-id (alist-get 'id request)
                              :buffer buffer
                              :options (alist-get 'options
                                                  (alist-get 'params request))))
                  agent-shell-bridge--pending-permissions))))))
  (apply orig-fn args))

;;;; Minor mode

(defvar agent-shell-bridge--advice-installed nil)

(defun agent-shell-bridge--install-advice ()
  "Install capture advice once."
  (unless agent-shell-bridge--advice-installed
    (advice-add 'agent-shell--on-notification :around
                #'agent-shell-bridge--on-notification)
    (advice-add 'agent-shell--on-request :around
                #'agent-shell-bridge--on-request)
    (setq agent-shell-bridge--advice-installed t)))

;;;###autoload
(define-minor-mode agent-shell-bridge-mode
  "Mirror this agent-shell buffer to the active bridge provider."
  :lighter " Bridge"
  (when agent-shell-bridge-mode
    (agent-shell-bridge--require-provider)
    (agent-shell-bridge--install-advice)
    (let* ((provider (agent-shell-bridge-active-provider))
           (handle (funcall (agent-shell-bridge-provider-start-session provider)
                            (list :name (buffer-name)))))
      (setq agent-shell-bridge--session-handle handle)
      (when handle
        (puthash handle (current-buffer) agent-shell-bridge--session->buffer))
      (funcall (agent-shell-bridge-provider-on-inbound provider)
               #'agent-shell-bridge--dispatch-inbound)
      (funcall (agent-shell-bridge-provider-on-control provider)
               #'agent-shell-bridge-handle-control))))

(provide 'agent-shell-bridge)
;;; agent-shell-bridge.el ends here
