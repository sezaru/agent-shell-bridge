;;; agent-shell-bridge-app-test.el --- Tests for the app provider -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the asb-sidecar provider: payload/line encoding, the
;; semantic permission mapping, inbound decode, and a unix-socket
;; loopback against a stub server.

;;; Code:

(require 'ert)
(require 'json)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-app)

;;;; Task 1 — payload encoding

(ert-deftest asb-app-encode-agent ()
  (let ((p (agent-shell-bridge-app--payload
            (agent-shell-bridge-make-message
             :role 'agent :status 'complete
             :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))))
    (should (equal (alist-get 'type p) "agent_message"))
    (should (equal (alist-get 'text p) "hi"))))

(ert-deftest asb-app-encode-thinking ()
  (let ((p (agent-shell-bridge-app--payload
            (agent-shell-bridge-make-message
             :role 'thinking :status 'streaming
             :parts (list (agent-shell-bridge-make-part :kind 'text :content "hmm"))))))
    (should (equal (alist-get 'type p) "thought"))))

(ert-deftest asb-app-encode-user ()
  (let ((p (agent-shell-bridge-app--payload
            (agent-shell-bridge-make-message
             :role 'user :status 'complete
             :parts (list (agent-shell-bridge-make-part :kind 'text :content "go"))))))
    (should (equal (alist-get 'type p) "user_message"))))

(ert-deftest asb-app-encode-tool-call ()
  (let* ((m (agent-shell-bridge-make-message
             :id "t1" :role 'tool :status 'pending
             :parts (list (agent-shell-bridge-make-part
                           :kind 'tool-call :content "cargo test"
                           :meta (list :tool-call-id "t1" :title "run tests"
                                       :kind "execute" :command "cargo test")))))
         (p (agent-shell-bridge-app--payload m)))
    (should (equal (alist-get 'type p) "tool_call"))
    (should (equal (alist-get 'id p) "t1"))
    (should (equal (alist-get 'kind p) "command"))
    (should (equal (alist-get 'command p) "cargo test"))
    (should (equal (alist-get 'status p) "pending"))))

(ert-deftest asb-app-encode-tool-update-failed ()
  (let* ((m (agent-shell-bridge-make-message
             :id "t1" :role 'tool :status 'error
             :parts (list (agent-shell-bridge-make-part
                           :kind 'tool-call :content "boom"
                           :meta (list :tool-call-id "t1" :status "failed")))))
         (p (agent-shell-bridge-app--payload m)))
    (should (equal (alist-get 'type p) "tool_call_update"))
    (should (equal (alist-get 'status p) "failed"))))

;;;; Task 2 — line encoding + permission mapping

(ert-deftest asb-app-status-line ()
  (should (equal (json-read-from-string
                  (agent-shell-bridge-app--line
                   (list (cons 't "status") (cons 'session "s") (cons 'state "running"))))
                 '((t . "status") (session . "s") (state . "running")))))

(ert-deftest asb-app-permission-options-semantic ()
  (let* ((opts (vector '((optionId . "a") (kind . "allow_once") (name . "Allow"))
                       '((optionId . "d") (kind . "reject_once") (name . "Deny"))))
         (m (agent-shell-bridge-make-message
             :role 'permission :status 'pending
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content "rm -rf /"
                           :meta (list :options opts :request-id 7)))))
         (obj (agent-shell-bridge-app--permission-object m "9"))
         (options (append (alist-get 'options obj) nil)))
    (should (equal (alist-get 'id obj) "9"))
    (should (equal (alist-get 'command obj) "rm -rf /"))
    (should (member '((id . "approve") (label . "Allow")) options))
    (should (member '((id . "deny") (label . "Deny")) options))))

(ert-deftest asb-app-permission-options-deduped ()
  (let* ((opts (vector '((optionId . "a") (kind . "allow") (name . "Allow"))
                       '((optionId . "b") (kind . "allow_once") (name . "Allow once"))))
         (m (agent-shell-bridge-make-message
             :role 'permission :status 'pending
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content "x"
                           :meta (list :options opts)))))
         (obj (agent-shell-bridge-app--permission-object m "1"))
         (options (append (alist-get 'options obj) nil)))
    (should (= 1 (cl-count "approve" options
                           :key (lambda (o) (alist-get 'id o)) :test #'equal)))))

;;;; Task 3 — inbound decode

(ert-deftest asb-app-inbound-inject ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "inject") (session . "s") (text . "go"))
     (lambda (ev) (setq got ev)) #'ignore)
    (should (equal (plist-get got :text) "go"))
    (should (equal (plist-get got :session) "s"))))

(ert-deftest asb-app-inbound-command-becomes-slash ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "command") (session . "s") (name . "model") (arg . "opus"))
     (lambda (ev) (setq got ev)) #'ignore)
    (should (equal (plist-get got :text) "/model opus"))))

(ert-deftest asb-app-inbound-command-no-arg ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "command") (session . "s") (name . "interrupt") (arg . nil))
     (lambda (ev) (setq got ev)) #'ignore)
    (should (equal (plist-get got :text) "/interrupt"))))

(ert-deftest asb-app-inbound-permission-response ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "permission-response") (session . "s") (id . "9") (option . "approve"))
     #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'approve))
    (should (equal (plist-get got :target) "9"))))

(ert-deftest asb-app-inbound-always-degrades-to-approve ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "permission-response") (session . "s") (id . "9") (option . "always"))
     #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'approve))))

(ert-deftest asb-app-inbound-interrupt ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "interrupt") (session . "s"))
     #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'interrupt))))

;;;; Task 4/5 — socket loopback

(defun asb-app-test--drain (&optional secs)
  (let ((deadline (+ (float-time) (or secs 0.5))))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05))))

(ert-deftest asb-app-loopback-send-and-receive ()
  (let* ((sock (make-temp-name
                (expand-file-name "asb-test-" temporary-file-directory)))
         (agent-shell-bridge-app-socket sock)
         (lines nil) (server nil) (client-conn nil)
         (agent-shell-bridge-app--proc nil)
         (agent-shell-bridge-app--rx "")
         (agent-shell-bridge-app--inbound-cb nil)
         (agent-shell-bridge-app--control-cb nil))
    (setq server
          (make-network-process
           :name "asb-stub" :server t :family 'local :service sock
           :filter (lambda (proc chunk)
                     (setq client-conn proc)
                     (dolist (l (split-string chunk "\n" t))
                       (push (json-read-from-string l) lines)))))
    (unwind-protect
        (progn
          (should (agent-shell-bridge-app--send-emacs-in
                   (list (cons 't "session-open") (cons 'session "s")
                         (cons 'title "demo"))))
          (asb-app-test--drain)
          (should (equal (alist-get 'session (car (last lines))) "s"))
          ;; split-frame inbound: one line delivered in two chunks decodes once.
          (let (got)
            (setq agent-shell-bridge-app--inbound-cb (lambda (ev) (setq got ev)))
            (process-send-string client-conn "{\"t\":\"inject\",\"session")
            (asb-app-test--drain 0.2)
            (should (null got))
            (process-send-string client-conn "\":\"s\",\"text\":\"go\"}\n")
            (asb-app-test--drain)
            (should (equal (plist-get got :text) "go"))))
      (ignore-errors (delete-process server))
      (agent-shell-bridge-app--disconnect)
      (ignore-errors (delete-file sock)))))

(ert-deftest asb-app-provider-drives-socket ()
  (let* ((sock (make-temp-name
                (expand-file-name "asb-test-" temporary-file-directory)))
         (agent-shell-bridge-app-socket sock)
         (lines nil) (server nil)
         (agent-shell-bridge-app--proc nil)
         (agent-shell-bridge-app--rx "")
         (agent-shell-bridge-app--counter 0)
         (agent-shell-bridge-app--handles nil)
         (agent-shell-bridge-app--last-handle nil))
    (setq server
          (make-network-process
           :name "asb-stub2" :server t :family 'local :service sock
           :filter (lambda (_proc chunk)
                     (dolist (l (split-string chunk "\n" t))
                       (push (json-read-from-string l) lines)))))
    (unwind-protect
        (let ((provider (agent-shell-bridge-app-provider)))
          (agent-shell-bridge-register-provider provider)
          (agent-shell-bridge-set-provider 'app)
          (let ((handle (funcall (agent-shell-bridge-provider-start-session provider)
                                 (list :title "demo"))))
            (funcall (agent-shell-bridge-provider-send provider)
                     (agent-shell-bridge-make-message
                      :session handle :role 'agent :status 'complete
                      :parts (list (agent-shell-bridge-make-part
                                    :kind 'text :content "the answer is 42"))))
            (funcall (agent-shell-bridge-provider-set-status provider) handle nil)
            (asb-app-test--drain)
            (let* ((by (lambda (tag) (seq-find (lambda (l) (equal (alist-get 't l) tag))
                                               lines)))
                   (open (funcall by "session-open"))
                   (msg (funcall by "msg"))
                   (status (funcall by "status")))
              (should open)
              (should (equal (alist-get 'session open) handle))
              (should msg)
              (should (equal (alist-get 'type (alist-get 'payload msg)) "agent_message"))
              (should (equal (alist-get 'text (alist-get 'payload msg)) "the answer is 42"))
              (should (equal (alist-get 'state status) "idle")))
            ;; permission goes out as a permission line, send returns the remote-id.
            (let* ((opts (vector '((optionId . "a") (kind . "allow_once") (name . "Allow"))))
                   (rid (funcall (agent-shell-bridge-provider-send provider)
                                 (agent-shell-bridge-make-message
                                  :session handle :role 'permission :status 'pending
                                  :parts (list (agent-shell-bridge-make-part
                                                :kind 'text :content "danger"
                                                :meta (list :options opts)))))))
              (asb-app-test--drain)
              (should (stringp rid))
              (let ((perm (seq-find (lambda (l) (equal (alist-get 't l) "permission")) lines)))
                (should perm)
                (should (equal (alist-get 'id perm) rid))
                (should (equal (alist-get 'command perm) "danger"))))))
      (ignore-errors (delete-process server))
      (agent-shell-bridge-app--disconnect)
      (ignore-errors (delete-file sock)))))

(provide 'agent-shell-bridge-app-test)
;;; agent-shell-bridge-app-test.el ends here
