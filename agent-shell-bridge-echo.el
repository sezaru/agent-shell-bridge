;;; agent-shell-bridge-echo.el --- Echo provider for the bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A reference provider that renders each structured message to a buffer,
;; one line per message.  `send' appends, `edit' replaces in place,
;; `delete' removes.  Used by the test suite and as the canonical example
;; of the provider protocol.

;;; Code:

(require 'cl-lib)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-provider)

(defvar agent-shell-bridge-echo-buffer-name "*agent-shell-bridge-echo*")

(defvar agent-shell-bridge-echo--entries nil
  "Ordered list of (ID . TEXT) currently rendered.")

(defvar agent-shell-bridge-echo--counter 0)

(defvar agent-shell-bridge-echo--inbound nil)
(defvar agent-shell-bridge-echo--control nil)

(defun agent-shell-bridge-echo--buffer ()
  (get-buffer-create agent-shell-bridge-echo-buffer-name))

(defun agent-shell-bridge-echo--line (message)
  "Render MESSAGE to a single display line."
  (format "[%s/%s]%s %s"
          (or (plist-get message :role) "?")
          (or (plist-get message :status) "?")
          (if (plist-get message :collapsible) " (collapsed)" "")
          (agent-shell-bridge-message-text message)))

(defun agent-shell-bridge-echo--render ()
  "Redraw the echo buffer from `agent-shell-bridge-echo--entries'."
  (with-current-buffer (agent-shell-bridge-echo--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dolist (entry (reverse agent-shell-bridge-echo--entries))
        (insert (cdr entry) "\n")))))

(defun agent-shell-bridge-echo--send (message)
  (let ((id (cl-incf agent-shell-bridge-echo--counter)))
    (push (cons id (agent-shell-bridge-echo--line message))
          agent-shell-bridge-echo--entries)
    (agent-shell-bridge-echo--render)
    id))

(defun agent-shell-bridge-echo--edit (remote-id message)
  (let ((entry (assoc remote-id agent-shell-bridge-echo--entries)))
    (when entry
      (setcdr entry (agent-shell-bridge-echo--line message))
      (agent-shell-bridge-echo--render))))

(defun agent-shell-bridge-echo--delete (remote-id)
  (setq agent-shell-bridge-echo--entries
        (assq-delete-all remote-id agent-shell-bridge-echo--entries))
  (agent-shell-bridge-echo--render))

(defun agent-shell-bridge-echo-reset ()
  "Clear echo state; convenient between tests."
  (setq agent-shell-bridge-echo--entries nil
        agent-shell-bridge-echo--counter 0
        agent-shell-bridge-echo--inbound nil
        agent-shell-bridge-echo--control nil)
  (agent-shell-bridge-echo--render))

(defun agent-shell-bridge-echo-emit-inbound (text &optional session)
  "Simulate an inbound TEXT from the remote (fires the inbound callback)."
  (when agent-shell-bridge-echo--inbound
    (funcall agent-shell-bridge-echo--inbound (list :text text :session session))))

(defun agent-shell-bridge-echo-emit-control (action &optional target session)
  "Simulate a remote control ACTION on TARGET (fires the control callback)."
  (when agent-shell-bridge-echo--control
    (funcall agent-shell-bridge-echo--control
             (list :action action :target target :session session))))

(defun agent-shell-bridge-echo-provider ()
  "Return a freshly-built echo provider."
  (agent-shell-bridge-provider-create
   :name 'echo
   :can-edit t
   :start-session (lambda (meta) (or (plist-get meta :name) 'echo-session))
   :send #'agent-shell-bridge-echo--send
   :edit #'agent-shell-bridge-echo--edit
   :delete #'agent-shell-bridge-echo--delete
   :on-inbound (lambda (cb) (setq agent-shell-bridge-echo--inbound cb))
   :on-control (lambda (cb) (setq agent-shell-bridge-echo--control cb))
   :stop #'agent-shell-bridge-echo-reset))

;;;###autoload
(defun agent-shell-bridge-echo-register ()
  "Register and select the echo provider."
  (interactive)
  (agent-shell-bridge-register-provider (agent-shell-bridge-echo-provider))
  (agent-shell-bridge-set-provider 'echo))

(provide 'agent-shell-bridge-echo)
;;; agent-shell-bridge-echo.el ends here
