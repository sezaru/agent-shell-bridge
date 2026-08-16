;;; agent-shell-bridge-control-test.el --- Inbound + control tests -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the remote->agent-shell direction: option-id lookup,
;; permission resolution, and interrupt routing.  agent-shell functions
;; are stubbed via cl-letf (agent-shell is not loaded here).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-shell-bridge)

(defvar asb-test--acp-options
  '[((optionId . "opt-allow") (kind . "allow_once"))
    ((optionId . "opt-always") (kind . "allow_always"))
    ((optionId . "opt-deny") (kind . "reject_once"))]
  "A realistic ACP permission options vector.")

(ert-deftest asb-find-option-id-matches-kinds ()
  (should (equal (agent-shell-bridge--find-option-id asb-test--acp-options 'approve)
                 "opt-allow"))
  (should (equal (agent-shell-bridge--find-option-id asb-test--acp-options 'always)
                 "opt-always"))
  (should (equal (agent-shell-bridge--find-option-id asb-test--acp-options 'deny)
                 "opt-deny")))

(ert-deftest asb-resolve-permission-sends-response-and-clears ()
  (let ((agent-shell-bridge--pending-permissions nil)
        (sent nil))
    (with-temp-buffer
      (setq-local agent-shell--state '((:client . my-client)))
      (push (cons "remote-1"
                  (list :request-id "req-7"
                        :buffer (current-buffer)
                        :options asb-test--acp-options))
            agent-shell-bridge--pending-permissions)
      (cl-letf (((symbol-function 'agent-shell--send-permission-response)
                 (lambda (&rest args) (setq sent args))))
        (agent-shell-bridge--resolve-permission "remote-1" 'approve)))
    (should (equal (plist-get sent :request-id) "req-7"))
    (should (equal (plist-get sent :option-id) "opt-allow"))
    (should (equal (plist-get sent :client) 'my-client))
    ;; entry cleared after resolution
    (should (null (assoc "remote-1" agent-shell-bridge--pending-permissions)))))

(ert-deftest asb-handle-control-approve-resolves ()
  (let ((agent-shell-bridge--pending-permissions nil)
        (sent nil))
    (with-temp-buffer
      (setq-local agent-shell--state '((:client . c)))
      (push (cons "m-1" (list :request-id "r-1" :buffer (current-buffer)
                              :options asb-test--acp-options))
            agent-shell-bridge--pending-permissions)
      (cl-letf (((symbol-function 'agent-shell--send-permission-response)
                 (lambda (&rest args) (setq sent args))))
        (agent-shell-bridge-handle-control
         (list :action 'deny :target "m-1"))))
    (should (equal (plist-get sent :option-id) "opt-deny"))))

(ert-deftest asb-handle-control-interrupt-calls-agent-shell ()
  (let ((interrupted 0))
    (with-temp-buffer
      (puthash "s" (current-buffer) agent-shell-bridge--session->buffer)
      (cl-letf (((symbol-function 'agent-shell-interrupt)
                 (lambda (&rest _) (cl-incf interrupted))))
        (agent-shell-bridge-handle-control (list :action 'interrupt :session "s")))
      (remhash "s" agent-shell-bridge--session->buffer))
    (should (= interrupted 1))))

(ert-deftest asb-dispatch-inbound-injects-into-session-buffer ()
  (let ((injected nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (puthash "sess-x" buf agent-shell-bridge--session->buffer)
        (cl-letf (((symbol-function 'agent-shell-bridge-inject)
                   (lambda (text &optional _b) (setq injected text))))
          (agent-shell-bridge--dispatch-inbound
           (list :text "hello agent" :session "sess-x")))
        (remhash "sess-x" agent-shell-bridge--session->buffer)))
    (should (equal injected "hello agent"))))

;;;; Inbound commands + busy-refuse

(ert-deftest asb-inbound-command-parses-interrupt ()
  (should (eq (agent-shell-bridge--inbound-command "/interrupt") 'interrupt))
  (should (eq (agent-shell-bridge--inbound-command "  /STOP ") 'interrupt))
  (should (null (agent-shell-bridge--inbound-command "hello there")))
  (should (null (agent-shell-bridge--inbound-command nil))))

(ert-deftest asb-dispatch-inbound-command-interrupts-not-injects ()
  (let ((interrupted 0) (injected nil))
    (with-temp-buffer
      (puthash "s" (current-buffer) agent-shell-bridge--session->buffer)
      (cl-letf (((symbol-function 'agent-shell-interrupt)
                 (lambda (&rest _) (cl-incf interrupted)))
                ((symbol-function 'agent-shell-bridge-inject)
                 (lambda (&rest _) (setq injected t))))
        (let ((res (agent-shell-bridge--dispatch-inbound
                    (list :text "/interrupt" :session "s"))))
          (should (eq (plist-get res :status) 'command))
          (should (= interrupted 1))
          (should (null injected))))
      (remhash "s" agent-shell-bridge--session->buffer))))

(ert-deftest asb-dispatch-inbound-ignores-unowned-post ()
  (let ((injected nil))
    (cl-letf (((symbol-function 'agent-shell-bridge-inject)
               (lambda (&rest _) (setq injected t))))
      ;; session "nope" is not in the ownership map
      (let ((res (agent-shell-bridge--dispatch-inbound
                  (list :text "hi" :session "nope"))))
        (should (eq (plist-get res :status) 'ignore))
        (should (null injected))))))

(ert-deftest asb-dispatch-inbound-refuses-when-busy ()
  (let ((injected nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (puthash "s" buf agent-shell-bridge--session->buffer)
        (cl-letf (((symbol-function 'agent-shell-bridge--buffer-busy-p)
                   (lambda (_b) t))
                  ((symbol-function 'agent-shell-bridge-inject)
                   (lambda (&rest _) (setq injected t))))
          (let ((res (agent-shell-bridge--dispatch-inbound
                      (list :text "do X" :session "s"))))
            (should (eq (plist-get res :status) 'refused))
            (should (eq (plist-get res :reason) 'busy))
            (should (null injected))))
        (remhash "s" agent-shell-bridge--session->buffer)))))

(ert-deftest asb-dispatch-inbound-consumes-when-idle ()
  (let ((injected nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (puthash "s" buf agent-shell-bridge--session->buffer)
        (cl-letf (((symbol-function 'agent-shell-bridge--buffer-busy-p)
                   (lambda (_b) nil))
                  ((symbol-function 'agent-shell-bridge-inject)
                   (lambda (text &optional _b) (setq injected text))))
          (let ((res (agent-shell-bridge--dispatch-inbound
                      (list :text "do X" :session "s"))))
            (should (eq (plist-get res :status) 'consumed))
            (should (equal injected "do X"))))
        (remhash "s" agent-shell-bridge--session->buffer)))))

(provide 'agent-shell-bridge-control-test)
;;; agent-shell-bridge-control-test.el ends here
