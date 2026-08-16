;;; agent-shell-bridge-provider.el --- Provider protocol for the bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A provider is a struct of function slots.  Every message that crosses
;; the seam is *structured* (see `agent-shell-bridge-make-message'); a
;; provider decides how faithfully to render it.  Discord flattens to
;; text; the own-app provider passes structure through untouched.

;;; Code:

(require 'cl-lib)

(cl-defstruct (agent-shell-bridge-provider
               (:constructor agent-shell-bridge-provider-create)
               (:copier nil))
  "A transport provider.  Each slot below is a function unless noted."
  name
  ;; non-nil if `edit' actually mutates a delivered message.  When nil, the
  ;; core buffers streaming chunks and emits one complete message on flush
  ;; instead of send-then-edit (a webhook cannot edit).
  can-edit
  ;; (session-meta) -> session-handle
  start-session
  ;; (message) -> remote-msg-id
  send
  ;; (remote-msg-id message) -> nil
  edit
  ;; (remote-msg-id) -> nil
  delete
  ;; (callback): callback receives (:text STR :session HANDLE)
  on-inbound
  ;; (callback): callback receives (:action SYM :target ID :session HANDLE)
  on-control
  ;; () -> nil
  stop)

(defvar agent-shell-bridge--providers (make-hash-table :test 'eq)
  "Registry mapping provider name (symbol) -> provider struct.")

(defvar agent-shell-bridge--active-provider nil
  "The provider currently used to mirror sessions.")

(defun agent-shell-bridge-register-provider (provider)
  "Register PROVIDER under its name; return it."
  (puthash (agent-shell-bridge-provider-name provider) provider
           agent-shell-bridge--providers)
  provider)

(defun agent-shell-bridge-set-provider (name)
  "Make the provider registered as NAME the active one."
  (let ((provider (gethash name agent-shell-bridge--providers)))
    (unless provider
      (error "No agent-shell-bridge provider named %s" name))
    (setq agent-shell-bridge--active-provider provider)))

(defun agent-shell-bridge-active-provider ()
  "Return the active provider, or nil."
  agent-shell-bridge--active-provider)

(provide 'agent-shell-bridge-provider)
;;; agent-shell-bridge-provider.el ends here
