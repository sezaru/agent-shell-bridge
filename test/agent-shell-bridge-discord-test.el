;;; agent-shell-bridge-discord-test.el --- Discord provider tests -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the Discord webhook provider: the foreground flattener,
;; the background activity aggregator (verb table + in-place editing), and
;; `send' payload routing (no network).

;;; Code:

(require 'ert)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-discord)

;;;; Flattener (foreground: agent/user/permission/activity)

(ert-deftest asb-discord-flatten-truncates-to-cap ()
  (let* ((big (make-string 3000 ?x))
         (m (agent-shell-bridge-make-message
             :role 'agent :status 'complete
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content big))))
         (out (agent-shell-bridge-discord--flatten m)))
    (should (<= (length out) agent-shell-bridge-discord-max-length))
    (should (string-match-p "truncated" out))))

(ert-deftest asb-discord-flatten-short-message-untouched ()
  (let* ((m (agent-shell-bridge-make-message
             :role 'agent :status 'complete
             :parts (list (agent-shell-bridge-make-part
                           :kind 'text :content "hello world"))))
         (out (agent-shell-bridge-discord--flatten m)))
    (should (equal out "🤖 **Agent**\nhello world"))))

(ert-deftest asb-discord-flatten-agent-not-collapsed ()
  (let ((out (agent-shell-bridge-discord--flatten
              (agent-shell-bridge-make-message
               :role 'agent :status 'complete
               :parts (list (agent-shell-bridge-make-part
                             :kind 'text :content "the answer"))))))
    (should-not (string-match-p "||" out))
    (should (string-match-p "the answer" out))))

(ert-deftest asb-discord-flatten-activity-is-subtext ()
  (should (equal (agent-shell-bridge-discord--flatten
                  (agent-shell-bridge-make-message
                   :role 'activity :status 'streaming
                   :parts (list (agent-shell-bridge-make-part
                                 :kind 'text :content "Thought, ran a command"))))
                 "-# Thought, ran a command")))

(ert-deftest asb-discord-flatten-background-roles-are-nil ()
  ;; thinking/tool never render as foreground -- they fold into activity.
  (dolist (role '(thinking tool))
    (should (null (agent-shell-bridge-discord--flatten
                   (agent-shell-bridge-make-message
                    :role role :status 'pending
                    :parts (list (agent-shell-bridge-make-part
                                  :kind 'text :content "x"))))))))

;;;; Activity aggregator (verb table + summary)

(defun asb-test--tool-msg (id kind status)
  (agent-shell-bridge-make-message
   :role 'tool :status status
   :parts (list (agent-shell-bridge-make-part
                 :kind 'tool-call :content ""
                 :meta (list :tool-call-id id :kind kind)))))

(ert-deftest asb-discord-tool-phrase-mirrors-agent-shell ()
  (should (equal (agent-shell-bridge-discord--tool-phrase "execute" 1 nil) "ran a command"))
  (should (equal (agent-shell-bridge-discord--tool-phrase "execute" 2 nil) "ran 2 commands"))
  (should (equal (agent-shell-bridge-discord--tool-phrase "execute" 1 t) "running a command"))
  (should (equal (agent-shell-bridge-discord--tool-phrase "read" 2 nil) "read 2 files"))
  (should (equal (agent-shell-bridge-discord--tool-phrase "edit" 1 nil) "edited a file")))

(ert-deftest asb-discord-activity-summary-thought-then-command ()
  (with-temp-buffer
    (let* ((posts nil) (edits nil)
           (agent-shell-bridge-discord-webhook-url "https://hook")
           (agent-shell-bridge-discord--post-fn
            (lambda (_u c) (push c posts) "act-1"))
           (agent-shell-bridge-discord--edit-fn
            (lambda (_u c) (push c edits) nil)))
      ;; thinking -> "Thinking" (first post, sync, gets id)
      (agent-shell-bridge-discord--act-note-thinking)
      (should (equal (car posts) "-# Thinking"))
      ;; a command starts -> edit to present tense
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "t1" "execute" 'pending))
      (should (equal (car edits) "-# Thought, running a command"))
      ;; command finishes -> past tense
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "t1" "execute" 'success))
      (should (equal (car edits) "-# Thought, ran a command"))
      ;; only one post (the rest are edits of the same message)
      (should (= (length posts) 1)))))

(ert-deftest asb-discord-activity-counts-multiple-and-groups ()
  (with-temp-buffer
    (let* ((last nil)
           (agent-shell-bridge-discord-webhook-url "https://hook")
           (agent-shell-bridge-discord--post-fn (lambda (_u c) (setq last c) "id"))
           (agent-shell-bridge-discord--edit-fn (lambda (_u c) (setq last c) nil)))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "a" "execute" 'pending))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "a" "execute" 'success))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "b" "execute" 'pending))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "b" "execute" 'success))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "c" "read" 'pending))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "c" "read" 'success))
      (should (equal last "-# Ran 2 commands, read a file")))))

(ert-deftest asb-discord-activity-finalize-then-reset ()
  (with-temp-buffer
    (let ((agent-shell-bridge-discord-webhook-url "https://hook")
          (agent-shell-bridge-discord--post-fn (lambda (_u _c) "id"))
          (agent-shell-bridge-discord--edit-fn (lambda (_u _c) nil)))
      (agent-shell-bridge-discord--act-note-thinking)
      (should agent-shell-bridge-discord--act-id)
      (agent-shell-bridge-discord--act-finalize)
      (should (null agent-shell-bridge-discord--act-id))
      (should (null agent-shell-bridge-discord--act-thought))
      (should (null agent-shell-bridge-discord--act-order)))))

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

(ert-deftest asb-discord-send-thinking-folds-into-activity ()
  ;; A thinking message posts the activity subtext, not a normal message.
  (with-temp-buffer
    (let* ((posts nil)
           (agent-shell-bridge-discord-webhook-url "https://hook")
           (agent-shell-bridge-discord--post-fn (lambda (_u c) (push c posts) "id"))
           (agent-shell-bridge-discord--post-async-fn
            (lambda (&rest _) (error "thinking must not post a normal message"))))
      (agent-shell-bridge-discord--send
       (agent-shell-bridge-make-message
        :role 'thinking :status 'complete
        :parts (list (agent-shell-bridge-make-part :kind 'text :content "hmm"))))
      (should (equal posts '("-# Thinking"))))))

(ert-deftest asb-discord-send-file-part-uploads ()
  ;; A message carrying a file part (e.g. /transcript) uploads as an attachment.
  (let* ((captured nil)
         (agent-shell-bridge-discord-webhook-url "https://hook")
         (agent-shell-bridge-discord--upload-fn
          (lambda (url name data) (setq captured (list url name data)))))
    (agent-shell-bridge-discord--send
     (agent-shell-bridge-make-message
      :role 'system :status 'complete
      :parts (list (agent-shell-bridge-make-part
                    :kind 'file :content "transcript body"
                    :meta (list :filename "transcript.md")))))
    (should (equal (nth 1 captured) "transcript.md"))
    (should (equal (nth 2 captured) "transcript body"))))

(ert-deftest asb-discord-permission-adds-tappable-reactions ()
  (with-temp-buffer
    (let* ((reacts nil)
           (agent-shell-bridge-discord-webhook-url "https://hook")
           (agent-shell-bridge-discord--post-fn (lambda (_u _c) "perm-1"))
           (agent-shell-bridge-discord--react-fn
            (lambda (_t id emoji) (push (cons id emoji) reacts))))
      (setq-local agent-shell-bridge--session-handle "thread-1")
      (should (equal (agent-shell-bridge-discord--send
                      (agent-shell-bridge-make-message
                       :role 'permission :status 'pending
                       :parts (list (agent-shell-bridge-make-part
                                     :kind 'text :content "rm -rf /"))))
                     "perm-1"))
      (should (equal (reverse reacts) '(("perm-1" . "✅") ("perm-1" . "❌")))))))

(ert-deftest asb-discord-permission-flatten-has-tap-hint ()
  (let ((out (agent-shell-bridge-discord--flatten
              (agent-shell-bridge-make-message
               :role 'permission :status 'pending
               :parts (list (agent-shell-bridge-make-part
                             :kind 'text :content "rm -rf /"))))))
    (should (string-match-p "Permission Required" out))
    (should (string-match-p "rm -rf /" out))
    (should (string-match-p "✅ to allow" out))))

(ert-deftest asb-discord-edit-url-threads-and-targets-message ()
  (let ((agent-shell-bridge-discord-webhook-url "https://hook"))
    (should (equal (agent-shell-bridge-discord--edit-url "m-1")
                   "https://hook/messages/m-1"))
    (with-temp-buffer
      (setq-local agent-shell-bridge--session-handle "thread-7")
      (should (equal (agent-shell-bridge-discord--edit-url "m-1")
                     "https://hook/messages/m-1?thread_id=thread-7")))))

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
