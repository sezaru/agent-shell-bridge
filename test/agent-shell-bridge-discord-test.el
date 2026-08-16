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
    (should (equal (nth 0 captured) "https://example.test/hook?wait=true"))
    (should (equal (nth 1 captured) "🤖 **Agent**\nhi"))))

(ert-deftest asb-discord-send-errors-without-webhook-url ()
  (let ((agent-shell-bridge-discord-webhook-url nil))
    (should-error
     (agent-shell-bridge-discord--send
      (agent-shell-bridge-make-message
       :role 'agent :status 'complete
       :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi")))))))

;;;; Forum: per-session posts

(ert-deftest asb-discord-create-post-uses-thread-name-and-returns-id ()
  (let* ((captured nil)
         (agent-shell-bridge-discord-webhook-url "https://hook")
         (agent-shell-bridge-discord--create-fn
          (lambda (url json)
            (setq captured (list url json))
            "{\"id\":\"msg-1\",\"channel_id\":\"thread-1\"}")))
    (let ((id (agent-shell-bridge-discord--create-post "Refactor the parser")))
      (should (equal id "thread-1"))
      (should (string-match-p "wait=true" (nth 0 captured)))
      (should (string-match-p "thread_name" (nth 1 captured)))
      (should (string-match-p "Refactor the parser" (nth 1 captured))))))

(ert-deftest asb-discord-create-post-truncates-title-to-100 ()
  (let* ((agent-shell-bridge-discord-webhook-url "https://hook")
         (long (make-string 250 ?a))
         (seen nil)
         (agent-shell-bridge-discord--create-fn
          (lambda (_url json) (setq seen json) "{\"channel_id\":\"t\"}")))
    (agent-shell-bridge-discord--create-post long)
    (let ((name (alist-get 'thread_name
                           (json-parse-string
                            (progn (string-match "{.*}" seen) (match-string 0 seen))
                            :object-type 'alist))))
      (should (<= (length name) 100)))))

(ert-deftest asb-discord-send-threads-under-session-post ()
  (let* ((url nil)
         (agent-shell-bridge-discord-webhook-url "https://hook")
         (agent-shell-bridge-discord--post-fn
          (lambda (u _content) (setq url u))))
    (with-temp-buffer
      (setq-local agent-shell-bridge--session-handle "thread-9")
      (agent-shell-bridge-discord--send
       (agent-shell-bridge-make-message
        :role 'agent :status 'complete
        :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi")))))
    (should (equal url "https://hook?thread_id=thread-9&wait=true"))))

(ert-deftest asb-discord-send-flat-without-session-handle ()
  (let* ((url nil)
         (agent-shell-bridge-discord-webhook-url "https://hook")
         (agent-shell-bridge-discord--post-fn
          (lambda (u _content) (setq url u))))
    ;; no session handle bound -> post to channel root
    (agent-shell-bridge-discord--send
     (agent-shell-bridge-make-message
      :role 'agent :status 'complete
      :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))
    (should (equal url "https://hook?wait=true"))))

(ert-deftest asb-discord-send-returns-message-id ()
  (let* ((agent-shell-bridge-discord-webhook-url "https://hook")
         (agent-shell-bridge-discord--post-fn
          (lambda (_u _c) "posted-42")))
    (should (equal (agent-shell-bridge-discord--send
                    (agent-shell-bridge-make-message
                     :role 'agent :status 'complete
                     :parts (list (agent-shell-bridge-make-part
                                   :kind 'text :content "hi"))))
                   "posted-42"))))

(ert-deftest asb-discord-start-session-flat-when-not-forum ()
  (let ((agent-shell-bridge-discord-forum-p nil))
    (should (eq (agent-shell-bridge-discord--start-session '(:name "x"))
                'discord-webhook))))

(ert-deftest asb-discord-provider-registers-and-activates ()
  (agent-shell-bridge-discord-webhook-register)
  (should (eq (agent-shell-bridge-provider-name
               (agent-shell-bridge-active-provider))
              'discord-webhook)))

(provide 'agent-shell-bridge-discord-test)
;;; agent-shell-bridge-discord-test.el ends here
