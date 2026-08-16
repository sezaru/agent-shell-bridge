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

;;;; Slash commands (list/set model·thought·mode, transcript) + busy-refuse

(ert-deftest asb-parse-command-splits-name-and-arg ()
  (should (equal (agent-shell-bridge--parse-command "/model sonnet") '("/model" . "sonnet")))
  (should (equal (agent-shell-bridge--parse-command "  /MODEL  ") '("/model" . nil)))
  (should (equal (agent-shell-bridge--parse-command "/thought high") '("/thought" . "high")))
  (should (null (agent-shell-bridge--parse-command "hello there")))
  (should (null (agent-shell-bridge--parse-command "/nope-not-a-command")))
  (should (null (agent-shell-bridge--parse-command nil))))

(ert-deftest asb-match-option-by-id-or-name ()
  (let ((opts '(((:model-id . "claude-sonnet-5") (:name . "Sonnet"))
                ((:model-id . "gpt-5") (:name . "GPT-5")))))
    (should (equal (alist-get :model-id
                              (agent-shell-bridge--match-option "gpt-5" opts :model-id :name))
                   "gpt-5"))
    (should (equal (alist-get :model-id
                              (agent-shell-bridge--match-option "sonnet" opts :model-id :name))
                   "claude-sonnet-5"))
    (should (null (agent-shell-bridge--match-option "zzz" opts :model-id :name)))))

(ert-deftest asb-format-option-list-flags-current ()
  (let ((out (agent-shell-bridge--format-option-list
              "Model" '(((:model-id . "a") (:name . "A")) ((:model-id . "b") (:name . "B")))
              :model-id :name "b")))
    (should (string-match-p "▸ `b`" out))
    (should (string-match-p "• `a`" out))))

(defmacro asb-test--with-capture (sink &rest body)
  "Register a provider capturing each sent message via (funcall SINK m)."
  (declare (indent 1))
  `(progn
     (agent-shell-bridge-register-provider
      (agent-shell-bridge-provider-create
       :name 'cap :can-edit nil :start-session (lambda (_) "t")
       :send (lambda (m) (funcall ,sink m) nil)
       :edit #'ignore :delete #'ignore :on-inbound #'ignore
       :on-control #'ignore :stop #'ignore))
     (agent-shell-bridge-set-provider 'cap)
     ,@body))

(ert-deftest asb-config-command-lists-options ()
  (let ((texts nil))
    (asb-test--with-capture
        (lambda (m) (push (agent-shell-bridge-message-text m) texts))
      (with-temp-buffer
        (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                  ((symbol-function 'agent-shell--state) (lambda () 'st))
                  ((symbol-function 'agent-shell--get-available-models)
                   (lambda (_) '(((:model-id . "a") (:name . "A"))
                                 ((:model-id . "b") (:name . "B")))))
                  ((symbol-function 'agent-shell--current-model-id) (lambda (_) "b")))
          (agent-shell-bridge--cmd-model nil (current-buffer)))))
    (should (string-match-p "▸ `b`" (car texts)))))

(ert-deftest asb-config-command-sets-option ()
  (let ((texts nil) (set-id nil))
    (asb-test--with-capture
        (lambda (m) (push (agent-shell-bridge-message-text m) texts))
      (with-temp-buffer
        (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                  ((symbol-function 'agent-shell--state) (lambda () 'st))
                  ((symbol-function 'agent-shell--get-available-models)
                   (lambda (_) '(((:model-id . "gpt-5") (:name . "GPT-5")))))
                  ((symbol-function 'agent-shell--current-model-id) (lambda (_) "old"))
                  ((symbol-function 'agent-shell--config-option-set-model-id)
                   (lambda (&rest args)
                     (setq set-id (plist-get args :model-id))
                     (funcall (plist-get args :on-success)))))
          (agent-shell-bridge--cmd-model "gpt" (current-buffer)))))
    (should (equal set-id "gpt-5"))
    (should (string-match-p "✓ Model" (car texts)))))

(ert-deftest asb-cmd-transcript-attaches-buffer-text ()
  (let ((files nil))
    (asb-test--with-capture
        (lambda (m) (push (agent-shell-bridge-message-file m) files))
      (with-temp-buffer
        (insert "hello transcript")
        (agent-shell-bridge--cmd-transcript nil (current-buffer))))
    (should (equal (car (car files)) "transcript.md"))
    (should (equal (cdr (car files)) "hello transcript"))))

(ert-deftest asb-dispatch-inbound-runs-slash-command ()
  (let ((ran 'unset))
    (with-temp-buffer
      (puthash "s" (current-buffer) agent-shell-bridge--session->buffer)
      (let ((agent-shell-bridge-command-table
             (list (cons "/ping" (lambda (arg _buf) (setq ran (or arg 'noarg)))))))
        (let ((res (agent-shell-bridge--dispatch-inbound
                    (list :text "/ping hi" :session "s"))))
          (should (eq (plist-get res :status) 'command))
          (should (eq (plist-get res :action) 'command))
          (should (equal ran "hi"))))
      (remhash "s" agent-shell-bridge--session->buffer))))

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
