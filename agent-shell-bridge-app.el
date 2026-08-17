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

(defvar agent-shell-bridge-app--proc nil
  "The live network process to the sidecar, or nil.")
(defvar agent-shell-bridge-app--rx ""
  "Partial inbound buffer for line framing.")
(defvar agent-shell-bridge-app--inbound-cb nil)
(defvar agent-shell-bridge-app--control-cb nil)
(defvar agent-shell-bridge-app--counter 0)
(defvar agent-shell-bridge-app--handles nil
  "Known session handles, for `session-close' on stop.")
(defvar agent-shell-bridge-app--last-handle nil
  "Most recent session handle, used when a message omits `:session'.")

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

(defun agent-shell-bridge-app--handle (obj inbound control)
  "Dispatch a decoded `EmacsOut' OBJ to INBOUND/CONTROL callbacks."
  (let ((session (alist-get 'session obj)))
    (pcase (alist-get 't obj)
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
         (funcall control (list :action 'interrupt :session session)))))))

;;;; Socket lifecycle + framing

(defun agent-shell-bridge-app--sentinel (_proc _event)
  (when (or (not agent-shell-bridge-app--proc)
            (not (process-live-p agent-shell-bridge-app--proc)))
    (setq agent-shell-bridge-app--proc nil
          agent-shell-bridge-app--rx "")))

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
             agent-shell-bridge-app--control-cb)
          (error (agent-shell-bridge--log "app: bad inbound line %S: %S" line err)))))))

(defun agent-shell-bridge-app--ensure-proc ()
  "Return a live process to the sidecar, connecting if needed, or nil."
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
       (setq agent-shell-bridge-app--proc nil))))
  agent-shell-bridge-app--proc)

(defun agent-shell-bridge-app--send-emacs-in (obj)
  "Send OBJ (an `EmacsIn' alist) as one ndjson line; nil on failure."
  (when-let* ((proc (agent-shell-bridge-app--ensure-proc)))
    (condition-case err
        (progn (process-send-string proc (agent-shell-bridge-app--line obj)) t)
      (error (agent-shell-bridge--log "app: send failed: %S" err) nil))))

(defun agent-shell-bridge-app--disconnect ()
  (when agent-shell-bridge-app--proc
    (ignore-errors (delete-process agent-shell-bridge-app--proc)))
  (setq agent-shell-bridge-app--proc nil
        agent-shell-bridge-app--rx ""))

;;;; Provider slots

(defun agent-shell-bridge-app--start-session (meta)
  "Open a sidecar session and return its handle."
  (let ((handle (or (ignore-errors (agent-shell-bridge--session-id))
                    (format "%d-%d" (emacs-pid)
                            (cl-incf agent-shell-bridge-app--counter)))))
    (setq agent-shell-bridge-app--last-handle handle)
    (cl-pushnew handle agent-shell-bridge-app--handles :test #'equal)
    (agent-shell-bridge-app--send-emacs-in
     (list (cons 't "session-open")
           (cons 'session handle)
           (cons 'title (or (plist-get meta :title) (plist-get meta :name) "session"))))
    handle))

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
               (cons 'seq 0) (cons 'turn 0) (cons 'payload payload))))
      (format "%d" (cl-incf agent-shell-bridge-app--counter)))))

(defun agent-shell-bridge-app--set-status (handle running)
  (agent-shell-bridge-app--send-emacs-in
   (list (cons 't "status") (cons 'session (or handle agent-shell-bridge-app--last-handle))
         (cons 'state (if running "running" "idle")))))

(defun agent-shell-bridge-app--stop ()
  (dolist (h agent-shell-bridge-app--handles)
    (agent-shell-bridge-app--send-emacs-in
     (list (cons 't "session-close") (cons 'session h))))
  (setq agent-shell-bridge-app--handles nil)
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
   :on-inbound (lambda (cb) (setq agent-shell-bridge-app--inbound-cb cb))
   :on-control (lambda (cb) (setq agent-shell-bridge-app--control-cb cb))
   :stop #'agent-shell-bridge-app--stop))

;;;###autoload
(defun agent-shell-bridge-app-register ()
  "Register and select the asb-sidecar (app) provider."
  (interactive)
  (agent-shell-bridge-register-provider (agent-shell-bridge-app-provider))
  (agent-shell-bridge-set-provider 'app))

(provide 'agent-shell-bridge-app)
;;; agent-shell-bridge-app.el ends here
