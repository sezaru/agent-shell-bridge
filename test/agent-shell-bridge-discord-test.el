;;; agent-shell-bridge-discord-test.el --- Discord provider tests -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the Discord webhook provider: the flattener (truncation,
;; spoiler collapse, headers) and `send' payload routing (no network).

;;; Code:

(require 'ert)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-discord)

;;;; Flattener

(ert-deftest asb-discord-flatten-truncates-to-cap ()
  (let* ((big (make-string 3000 ?x))
         (m (agent-shell-bridge-make-message
             :role 'tool :status 'success
             :parts (list (agent-shell-bridge-make-part
                           :kind 'tool-call :content big))))
         (out (agent-shell-bridge-discord--flatten m)))
    (should (<= (length out) agent-shell-bridge-discord-max-length))
    (should (string-match-p "truncated" out))))

(ert-deftest asb-discord-flatten-collapses-thinking-in-spoiler ()
  (let* ((m (agent-shell-bridge-make-message
             :role 'thinking :status 'complete :collapsible t
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content "secret plan"))))
         (out (agent-shell-bridge-discord--flatten m)))
    (should (string-prefix-p "💭" out))
    (should (string-match-p "||.*secret plan.*||" out))))

(ert-deftest asb-discord-flatten-short-message-untouched ()
  (let* ((m (agent-shell-bridge-make-message
             :role 'agent :status 'complete
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content "hello world"))))
         (out (agent-shell-bridge-discord--flatten m)))
    (should (equal out "🤖 **Agent**\nhello world"))))

(ert-deftest asb-discord-flatten-tool-status-emoji ()
  (let ((err (agent-shell-bridge-discord--flatten
              (agent-shell-bridge-make-message
               :role 'tool :status 'error
               :parts (list (agent-shell-bridge-make-part
                             :kind 'tool-call :content "boom"))))))
    (should (string-prefix-p "❌" err))))

(ert-deftest asb-discord-flatten-truncation-balances-fences ()
  ;; A fenced body cut mid-block must not leave a dangling opener.
  (let* ((big (make-string 3000 ?y))
         (m (agent-shell-bridge-make-message
             :role 'tool :status 'success
             :parts (list (agent-shell-bridge-make-part
                           :kind 'tool-call :content big))))
         (out (agent-shell-bridge-discord--flatten m))
         (n 0) (start 0))
    (while (string-match "```" out start)
      (setq n (1+ n) start (match-end 0)))
    (should (cl-evenp n))
    (should (<= (length out) agent-shell-bridge-discord-max-length))))

;;;; send routing (no network)

(ert-deftest asb-discord-send-posts-flattened-payload ()
  (let* ((captured nil)
         (agent-shell-bridge-discord-webhook-url "https://example.test/hook")
         (agent-shell-bridge-discord--post-fn
          (lambda (url content) (setq captured (list url content)))))
    (agent-shell-bridge-discord--send
     (agent-shell-bridge-make-message
      :role 'agent :status 'complete
      :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))
    (should (equal (nth 0 captured) "https://example.test/hook"))
    (should (equal (nth 1 captured) "🤖 **Agent**\nhi"))))

(ert-deftest asb-discord-send-errors-without-webhook-url ()
  (let ((agent-shell-bridge-discord-webhook-url nil))
    (should-error
     (agent-shell-bridge-discord--send
      (agent-shell-bridge-make-message
       :role 'agent :status 'complete
       :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi")))))))

(ert-deftest asb-discord-provider-registers-and-activates ()
  (agent-shell-bridge-discord-webhook-register)
  (should (eq (agent-shell-bridge-provider-name
               (agent-shell-bridge-active-provider))
              'discord-webhook)))

(provide 'agent-shell-bridge-discord-test)
;;; agent-shell-bridge-discord-test.el ends here
