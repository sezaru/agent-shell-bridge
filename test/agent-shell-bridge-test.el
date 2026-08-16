;;; agent-shell-bridge-test.el --- Tests for the bridge seam -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the structured message model, the normalizer, and the
;; echo provider dispatch.  No agent-shell dependency: the normalizer
;; operates on raw ACP `update' alists constructed here.

;;; Code:

(require 'ert)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-echo)

;;;; Fixtures — captured ACP session updates

(defun asb-test--thought-update (text)
  `((sessionUpdate . "agent_thought_chunk")
    (content . ((type . "text") (text . ,text)))))

(defun asb-test--agent-update (text)
  `((sessionUpdate . "agent_message_chunk")
    (content . ((type . "text") (text . ,text)))))

(defun asb-test--tool-call-update (id command title)
  `((sessionUpdate . "tool_call")
    (toolCallId . ,id)
    (title . ,title)
    (rawInput . ((command . ,command)))))

(defun asb-test--tool-call-completed (id output)
  `((sessionUpdate . "tool_call_update")
    (toolCallId . ,id)
    (status . "completed")
    (content . [((type . "content")
                 (content . ((type . "text") (text . ,output))))])))

;;;; Task 0.2 — normalizer

(ert-deftest asb-normalize-thought-is-collapsible-thinking ()
  (let ((m (agent-shell-bridge--normalize-update
            (asb-test--thought-update "pondering"))))
    (should (eq (plist-get m :role) 'thinking))
    (should (eq (plist-get m :status) 'streaming))
    (should (plist-get m :collapsible))
    (should (equal (agent-shell-bridge-message-text m) "pondering"))))

(ert-deftest asb-normalize-agent-message-is-streaming-text ()
  (let ((m (agent-shell-bridge--normalize-update
            (asb-test--agent-update "final answer"))))
    (should (eq (plist-get m :role) 'agent))
    (should (eq (plist-get m :status) 'streaming))
    (should (null (plist-get m :collapsible)))
    (should (equal (agent-shell-bridge-message-text m) "final answer"))))

(ert-deftest asb-normalize-tool-call-has-tool-call-part-and-status ()
  (let* ((m (agent-shell-bridge--normalize-update
             (asb-test--tool-call-update "t1" "ls -la" "Run")))
         (part (car (plist-get m :parts))))
    (should (eq (plist-get m :role) 'tool))
    (should (eq (plist-get m :status) 'pending))
    (should (equal (plist-get m :id) "t1"))
    (should (eq (plist-get part :kind) 'tool-call))
    (should (equal (plist-get part :content) "ls -la"))))

(ert-deftest asb-normalize-tool-call-update-maps-completed-to-success ()
  (let ((m (agent-shell-bridge--normalize-update
            (asb-test--tool-call-completed "t1" "done"))))
    (should (eq (plist-get m :role) 'tool))
    (should (eq (plist-get m :status) 'success))
    (should (equal (agent-shell-bridge-message-text m) "done"))))

(ert-deftest asb-normalize-unknown-update-is-nil ()
  (should (null (agent-shell-bridge--normalize-update
                 '((sessionUpdate . "usage_update"))))))

;;;; Task 0.3 — echo provider + end-to-end dispatch

(defmacro asb-test--with-echo (&rest body)
  "Run BODY in a temp buffer with the echo provider active and reset."
  `(with-temp-buffer
     (agent-shell-bridge-echo-register)
     (agent-shell-bridge-echo-reset)
     (setq-local agent-shell-bridge-mode t)
     ,@body))

(defun asb-test--echo-lines ()
  (with-current-buffer (agent-shell-bridge-echo--buffer)
    (split-string (string-trim (buffer-string)) "\n" t)))

(ert-deftest asb-echo-renders-one-line-per-message ()
  (asb-test--with-echo
   (agent-shell-bridge--feed
    (agent-shell-bridge--normalize-update (asb-test--agent-update "hi")))
   (agent-shell-bridge--flush-stream)
   (let ((lines (asb-test--echo-lines)))
     (should (= (length lines) 1))
     (should (string-match-p "\\[agent/complete\\]" (car lines)))
     (should (string-match-p "hi" (car lines))))))

(ert-deftest asb-echo-coalesces-streaming-chunks ()
  (asb-test--with-echo
   ;; Two agent chunks + a tool call + one more agent chunk.
   (agent-shell-bridge--feed
    (agent-shell-bridge--normalize-update (asb-test--agent-update "Hel")))
   (agent-shell-bridge--feed
    (agent-shell-bridge--normalize-update (asb-test--agent-update "lo")))
   (agent-shell-bridge--feed
    (agent-shell-bridge--normalize-update
     (asb-test--tool-call-update "t1" "ls" "Run")))
   (agent-shell-bridge--feed
    (agent-shell-bridge--normalize-update (asb-test--agent-update "Done")))
   (agent-shell-bridge--flush-stream)
   (let ((lines (asb-test--echo-lines)))
     ;; coalesced "Hello", the tool line, then "Done" => 3 lines
     (should (= (length lines) 3))
     (should (string-match-p "\\[agent/complete\\] Hello" (nth 0 lines)))
     (should (string-match-p "\\[tool/pending\\]" (nth 1 lines)))
     (should (string-match-p "\\[agent/complete\\] Done" (nth 2 lines))))))

(ert-deftest asb-non-editing-provider-buffers-and-sends-once-on-flush ()
  "A provider that cannot edit must get one complete send, never partials."
  (let* ((sends nil) (edits 0)
         (provider (agent-shell-bridge-provider-create
                    :name 'capture :can-edit nil
                    :start-session (lambda (_) 'capture)
                    :send (lambda (m) (push m sends) nil)
                    :edit (lambda (_id _m) (cl-incf edits))
                    :delete #'ignore :on-inbound #'ignore
                    :on-control #'ignore :stop #'ignore)))
    (agent-shell-bridge-register-provider provider)
    (agent-shell-bridge-set-provider 'capture)
    (with-temp-buffer
      (agent-shell-bridge--feed
       (agent-shell-bridge--normalize-update (asb-test--agent-update "Hel")))
      (agent-shell-bridge--feed
       (agent-shell-bridge--normalize-update (asb-test--agent-update "lo")))
      ;; nothing delivered yet: buffered, no send, no edit
      (should (null sends))
      (should (= edits 0))
      (agent-shell-bridge--flush-stream))
    (should (= (length sends) 1))
    (should (= edits 0))
    (should (eq (plist-get (car sends) :status) 'complete))
    (should (equal (agent-shell-bridge-message-text (car sends)) "Hello"))))

(ert-deftest asb-echo-edit-replaces-in-place ()
  (asb-test--with-echo
   (let ((id (agent-shell-bridge-echo--send
              (agent-shell-bridge-make-message
               :role 'agent :status 'streaming
               :parts (list (agent-shell-bridge-make-part :kind 'text :content "a"))))))
     (agent-shell-bridge-echo--edit
      id (agent-shell-bridge-make-message
          :role 'agent :status 'complete
          :parts (list (agent-shell-bridge-make-part :kind 'text :content "ab"))))
     (let ((lines (asb-test--echo-lines)))
       (should (= (length lines) 1))
       (should (string-match-p "\\[agent/complete\\] ab" (car lines)))))))

(ert-deftest asb-echo-inbound-and-control-callbacks-fire ()
  (asb-test--with-echo
   (let ((provider (agent-shell-bridge-active-provider))
         inbound control)
     (funcall (agent-shell-bridge-provider-on-inbound provider)
              (lambda (ev) (setq inbound ev)))
     (funcall (agent-shell-bridge-provider-on-control provider)
              (lambda (ev) (setq control ev)))
     (agent-shell-bridge-echo-emit-inbound "run this")
     (agent-shell-bridge-echo-emit-control 'approve "t1")
     (should (equal (plist-get inbound :text) "run this"))
     (should (eq (plist-get control :action) 'approve))
     (should (equal (plist-get control :target) "t1")))))

(provide 'agent-shell-bridge-test)
;;; agent-shell-bridge-test.el ends here
