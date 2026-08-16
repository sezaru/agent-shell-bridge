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
             :role 'agent :status 'complete
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content big))))
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

(ert-deftest asb-discord-flatten-tool-success-suppressed ()
  ;; A finished tool's output is not dumped to Discord (it lives in Emacs).
  (should (null (agent-shell-bridge-discord--flatten
                 (agent-shell-bridge-make-message
                  :role 'tool :status 'success
                  :parts (list (agent-shell-bridge-make-part
                                :kind 'tool-call :content "line1\nline2")))))))

(ert-deftest asb-discord-flatten-tool-pending-compact-command ()
  (let ((out (agent-shell-bridge-discord--flatten
              (agent-shell-bridge-make-message
               :role 'tool :status 'pending
               :parts (list (agent-shell-bridge-make-part
                             :kind 'tool-call :content "rg -n foo\n  bar"))))))
    (should (string-match-p "`rg -n foo bar`" out))   ; one-lined, not fenced
    (should-not (string-match-p "||" out))))

(ert-deftest asb-discord-flatten-agent-not-collapsed ()
  (let ((out (agent-shell-bridge-discord--flatten
              (agent-shell-bridge-make-message
               :role 'agent :status 'complete
               :parts (list (agent-shell-bridge-make-part
                             :kind 'text :content "the answer"))))))
    (should-not (string-match-p "||" out))
    (should (string-match-p "the answer" out))))

(ert-deftest asb-discord-flatten-tool-error-shows-output ()
  ;; A failure is echoed tersely on one line so it is visible remotely.
  (let ((err (agent-shell-bridge-discord--flatten
              (agent-shell-bridge-make-message
               :role 'tool :status 'error
               :parts (list (agent-shell-bridge-make-part
                             :kind 'tool-call :content "boom\nkaboom"))))))
    (should (string-prefix-p "❌" err))
    (should (string-match-p "boom kaboom" err))   ; one-lined
    (should-not (string-match-p "\n" err))))

(ert-deftest asb-discord-flatten-thinking-stays-compact ()
  ;; Long thinking is truncated so the spoiler stays a small bar.
  (let* ((big (make-string 5000 ?z))
         (out (agent-shell-bridge-discord--flatten
               (agent-shell-bridge-make-message
                :role 'thinking :status 'complete :collapsible t
                :parts (list (agent-shell-bridge-make-part
                              :kind 'text :content big))))))
    (should (<= (length out)
                (+ 20 agent-shell-bridge-discord-thinking-limit)))))

;;;; send routing (no network)

(ert-deftest asb-discord-send-posts-flattened-payload-async ()
  ;; Ordinary messages fire async (no id needed) so Enter stays snappy.
  (let* ((captured nil) (sync-called nil)
         (agent-shell-bridge-discord-webhook-url "https://example.test/hook")
         (agent-shell-bridge-discord--post-async-fn
          (lambda (url content) (setq captured (list url content))))
         (agent-shell-bridge-discord--post-fn
          (lambda (&rest _) (setq sync-called t))))
    (agent-shell-bridge-discord--send
     (agent-shell-bridge-make-message
      :role 'agent :status 'complete
      :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))
    (should (null sync-called))
    (should (equal (nth 0 captured) "https://example.test/hook?wait=true"))
    (should (equal (nth 1 captured) "🤖 **Agent**\nhi"))))

(ert-deftest asb-discord-send-permission-is-sync-with-id ()
  ;; Permission posts synchronously and returns its id (for reaction correlation).
  (let* ((agent-shell-bridge-discord-webhook-url "https://hook")
         (agent-shell-bridge-discord--post-async-fn
          (lambda (&rest _) (error "permission must not fire async")))
         (agent-shell-bridge-discord--post-fn (lambda (_u _c) "perm-9")))
    (should (equal (agent-shell-bridge-discord--send
                    (agent-shell-bridge-make-message
                     :role 'permission :status 'pending
                     :parts (list (agent-shell-bridge-make-part
                                   :kind 'text :content "rm -rf /"))))
                   "perm-9"))))

(ert-deftest asb-discord-send-suppressed-message-posts-nothing ()
  (let* ((posted nil)
         (agent-shell-bridge-discord-webhook-url "https://hook")
         (agent-shell-bridge-discord--post-async-fn (lambda (&rest _) (setq posted t)))
         (agent-shell-bridge-discord--post-fn (lambda (&rest _) (setq posted t))))
    (should (null (agent-shell-bridge-discord--send
                   (agent-shell-bridge-make-message
                    :role 'tool :status 'success
                    :parts (list (agent-shell-bridge-make-part
                                  :kind 'tool-call :content "output"))))))
    (should (null posted))))

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
         (agent-shell-bridge-discord--post-async-fn
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
         (agent-shell-bridge-discord--post-async-fn
          (lambda (u _content) (setq url u))))
    ;; no session handle bound -> post to channel root
    (agent-shell-bridge-discord--send
     (agent-shell-bridge-make-message
      :role 'agent :status 'complete
      :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))
    (should (equal url "https://hook?wait=true"))))

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
