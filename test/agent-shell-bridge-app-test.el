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

(ert-deftest asb-app-inbound-new-session ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "new-session") (prompt . "fix the auth test") (cwd . "/home/me/p"))
     #'ignore #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'new))
    (should (equal (plist-get got :prompt) "fix the auth test"))
    (should (equal (plist-get got :cwd) "/home/me/p"))))

(ert-deftest asb-app-inbound-resume-session ()
  (let (got)
    (agent-shell-bridge-app--handle
     '((t . "resume-session") (session . "sess-123"))
     #'ignore #'ignore (lambda (ev) (setq got ev)))
    (should (eq (plist-get got :action) 'resume))
    (should (equal (plist-get got :session) "sess-123"))))

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

(ert-deftest asb-app-close-session-sends-close-and-drops-handle ()
  "Closing one handle emits a single `session-close' and forgets just it."
  (let* ((sock (make-temp-name
                (expand-file-name "asb-test-" temporary-file-directory)))
         (agent-shell-bridge-app-socket sock)
         (lines nil) (server nil)
         (agent-shell-bridge-app--proc nil)
         (agent-shell-bridge-app--rx "")
         (agent-shell-bridge-app--outbox nil)
         (agent-shell-bridge-app--inflight nil)
         (agent-shell-bridge-app--was-live nil)
         (agent-shell-bridge-app--cid 0)
         (agent-shell-bridge-app--handles '("a" "b"))
         (agent-shell-bridge-app--titles '(("a" . "A") ("b" . "B")))
         (agent-shell-bridge-app--last-handle "b"))
    (setq server
          (make-network-process
           :name "asb-stub-close" :server t :family 'local :service sock
           :filter (lambda (_p chunk)
                     (dolist (l (split-string chunk "\n" t))
                       (push (json-read-from-string l) lines)))))
    (unwind-protect
        (progn
          (agent-shell-bridge-app--close-session "b")
          (asb-app-test--drain)
          (let ((close (seq-find (lambda (l) (equal (alist-get 't l) "session-close"))
                                 lines)))
            (should close)
            (should (equal (alist-get 'session close) "b")))
          (should (equal agent-shell-bridge-app--handles '("a")))
          (should (null (alist-get "b" agent-shell-bridge-app--titles nil nil #'equal)))
          ;; last-handle fell back to a surviving session, not the closed one.
          (should (equal agent-shell-bridge-app--last-handle "a"))
          ;; closing an unknown handle is a no-op (no extra line).
          (let ((n (length lines)))
            (agent-shell-bridge-app--close-session "zzz")
            (asb-app-test--drain 0.1)
            (should (= (length lines) n))))
      (ignore-errors (delete-process server))
      (agent-shell-bridge-app--disconnect)
      (ignore-errors (delete-file sock)))))

(ert-deftest asb-app-ensure-proc-spawns-daemon-on-connect-failure ()
  "A failed connect spawns the daemon: setsid sh -c 'exec <bin> run ...'."
  (let* ((agent-shell-bridge-app-socket
          (make-temp-name (expand-file-name "asb-nodaemon-" temporary-file-directory)))
         (agent-shell-bridge-app-binary "/opt/asb/asb-sidecar")
         (agent-shell-bridge-app--proc nil)
         (agent-shell-bridge-app--spawn-cooldown nil)
         (captured nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq captured (plist-get args :command)) 'fake)))
      ;; No server is listening on the socket, so connect fails and we spawn.
      (should (null (agent-shell-bridge-app--ensure-proc)))
      (should (equal (nth 0 captured) "setsid"))
      (should (equal (nth 1 captured) "sh"))
      (should (equal (nth 2 captured) "-c"))
      (should (string-match-p "exec /opt/asb/asb-sidecar run" (nth 3 captured)))
      ;; Cooldown now set: a second failed connect does NOT re-spawn.
      (setq captured nil)
      (should (null (agent-shell-bridge-app--ensure-proc)))
      (should (null captured)))))

(ert-deftest asb-app-claim-session-granted-then-denied ()
  "A synchronous claim returns `granted'/`denied' from the daemon's reply."
  (let* ((sock (make-temp-name
                (expand-file-name "asb-claim-" temporary-file-directory)))
         (agent-shell-bridge-app-socket sock)
         (agent-shell-bridge-app--proc nil)
         (agent-shell-bridge-app--rx "")
         (agent-shell-bridge-app--claim-cid 0)
         (agent-shell-bridge-app--claim-results nil)
         (agent-shell-bridge-app-claim-timeout 1.0)
         (grant t) (server nil))
    (setq server
          (make-network-process
           :name "asb-claim-stub" :server t :family 'local :service sock
           :filter (lambda (proc chunk)
                     (dolist (l (split-string chunk "\n" t))
                       (let ((cid (alist-get 'cid (json-read-from-string l))))
                         (process-send-string
                          proc (format "{\"t\":\"claim-result\",\"cid\":%d,\"granted\":%s}\n"
                                       cid (if grant "true" "false"))))))))
    (unwind-protect
        (progn
          (should (eq (agent-shell-bridge-app--claim-session "h") 'granted))
          (setq grant nil)
          (should (eq (agent-shell-bridge-app--claim-session "h") 'denied)))
      (ignore-errors (delete-process server))
      (agent-shell-bridge-app--disconnect)
      (ignore-errors (delete-file sock)))))

(ert-deftest asb-app-claim-session-unavailable-without-daemon ()
  "No daemon answering -> `unavailable', so the caller fails open (never hangs)."
  (let* ((agent-shell-bridge-app-socket
          (make-temp-name (expand-file-name "asb-noclaim-" temporary-file-directory)))
         (agent-shell-bridge-app--proc nil)
         (agent-shell-bridge-app--rx "")
         ;; Suppress the lazy daemon spawn so the test has no side effects.
         (agent-shell-bridge-app--spawn-cooldown t)
         (agent-shell-bridge-app--claim-cid 0)
         (agent-shell-bridge-app-claim-timeout 0.3))
    (should (eq (agent-shell-bridge-app--claim-session "h") 'unavailable))))

;;;; Task 24 — per-session ordinal (dedup key), seed + replay reset

(ert-deftest asb-app-ordinal-live-sequence ()
  "With no replay, a session's ordinals are a plain 1,2,3."
  (let ((agent-shell-bridge-app--ordinals (make-hash-table :test 'equal))
        (agent-shell-bridge-app--replaying (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'agent-shell-bridge-app--session-loading-p)
               (lambda (_h) nil)))
      (should (= 1 (agent-shell-bridge-app--next-ord "h")))
      (should (= 2 (agent-shell-bridge-app--next-ord "h")))
      (should (= 3 (agent-shell-bridge-app--next-ord "h"))))))

(ert-deftest asb-app-session-hw-seeds-untouched-counter-only ()
  "`session-hw' seeds a still-0 counter; a later hw never rewinds progress."
  (let ((agent-shell-bridge-app--ordinals (make-hash-table :test 'equal))
        (agent-shell-bridge-app--replaying (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'agent-shell-bridge-app--session-loading-p)
               (lambda (_h) nil)))
      ;; daemon reports high-water 5 -> resume-without-replay continues at 6
      (agent-shell-bridge-app--handle '((t . "session-hw") (session . "h") (hw . 5))
                                      nil nil)
      (should (= 6 (agent-shell-bridge-app--next-ord "h")))
      (should (= 7 (agent-shell-bridge-app--next-ord "h")))
      ;; a stray/duplicate hw must NOT clobber the advanced counter
      (agent-shell-bridge-app--handle '((t . "session-hw") (session . "h") (hw . 99))
                                      nil nil)
      (should (= 8 (agent-shell-bridge-app--next-ord "h"))))))

(ert-deftest asb-app-replay-reproduces-ordinals-then-heals-and-continues ()
  "The whole #24 flow: seed high-water 3, a session/load replay resets and
reproduces 1,2,3 (daemon dedups), a divergence-tail phrase gets 4 (appended),
then live continues at 5."
  (let ((agent-shell-bridge-app--ordinals (make-hash-table :test 'equal))
        (agent-shell-bridge-app--replaying (make-hash-table :test 'equal))
        (loading nil))
    (cl-letf (((symbol-function 'agent-shell-bridge-app--session-loading-p)
               (lambda (_h) loading)))
      (agent-shell-bridge-app--handle '((t . "session-hw") (session . "h") (hw . 3))
                                      nil nil)
      (setq loading t)                  ; session/load replay begins
      (should (= 1 (agent-shell-bridge-app--next-ord "h")))
      (should (= 2 (agent-shell-bridge-app--next-ord "h")))
      (should (= 3 (agent-shell-bridge-app--next-ord "h")))
      (should (= 4 (agent-shell-bridge-app--next-ord "h")))  ; divergence tail
      (setq loading nil)                ; replay ends
      (should (= 5 (agent-shell-bridge-app--next-ord "h"))))))

(ert-deftest asb-app-on-relink-registers-resumed-session ()
  "The relink hook sends `session-open' (registering a resumed session) only
when the app provider is active."
  (let* ((sock (make-temp-name
                (expand-file-name "asb-relink-" temporary-file-directory)))
         (agent-shell-bridge-app-socket sock)
         (lines nil) (server nil)
         (agent-shell-bridge-app--proc nil)
         (agent-shell-bridge-app--rx "")
         (agent-shell-bridge-app--outbox nil)
         (agent-shell-bridge-app--inflight nil)
         (agent-shell-bridge-app--was-live nil)
         (agent-shell-bridge-app--cid 0)
         (agent-shell-bridge-app--handles nil)
         (agent-shell-bridge-app--titles '(("h" . "Resumed"))))
    (agent-shell-bridge-register-provider (agent-shell-bridge-app-provider))
    (agent-shell-bridge-set-provider 'app)
    (setq server
          (make-network-process
           :name "asb-relink-stub" :server t :family 'local :service sock
           :filter (lambda (_p chunk)
                     (dolist (l (split-string chunk "\n" t))
                       (push (json-read-from-string l) lines)))))
    (unwind-protect
        (progn
          (agent-shell-bridge-app--on-relink "h")
          (asb-app-test--drain)
          (should (member "h" agent-shell-bridge-app--handles))
          (let ((open (seq-find (lambda (l) (equal (alist-get 't l) "session-open"))
                                lines)))
            (should open)
            (should (equal (alist-get 'session open) "h"))
            (should (equal (alist-get 'title open) "Resumed"))))
      (ignore-errors (delete-process server))
      (agent-shell-bridge-app--disconnect)
      (ignore-errors (delete-file sock)))))

(provide 'agent-shell-bridge-app-test)
;;; agent-shell-bridge-app-test.el ends here
