;;; agent-shell-bridge-discord-test.el --- Discord provider tests -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the Discord bot provider's outbound half: the foreground
;; flattener, the background activity aggregator (verb table + in-place
;; editing), bot REST targeting (forum thread creation, per-thread posts),
;; and `send' routing.  No network -- the REST/seam functions are stubbed.

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
           (agent-shell-bridge-discord--post-fn
            (lambda (_thread c) (push c posts) "act-1"))
           (agent-shell-bridge-discord--edit-fn
            (lambda (_thread _id c) (push c edits) nil)))
      ;; thinking -> "Thinking" (first post, sync, gets id)
      (agent-shell-bridge-discord--act-note-thinking)
      (should (string-prefix-p "-# Thinking" (car posts)))
      ;; a command starts -> edit to present tense
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "t1" "execute" 'pending))
      (should (string-prefix-p "-# Thought, running a command" (car edits)))
      ;; command finishes -> past tense
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "t1" "execute" 'success))
      (should (string-prefix-p "-# Thought, ran a command" (car edits)))
      ;; only one post (the rest are edits of the same message)
      (should (= (length posts) 1)))))

(ert-deftest asb-discord-activity-counts-multiple-and-groups ()
  (with-temp-buffer
    (let* ((last nil)
           (agent-shell-bridge-discord--post-fn (lambda (_thread c) (setq last c) "id"))
           (agent-shell-bridge-discord--edit-fn (lambda (_thread _id c) (setq last c) nil)))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "a" "execute" 'pending))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "a" "execute" 'success))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "b" "execute" 'pending))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "b" "execute" 'success))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "c" "read" 'pending))
      (agent-shell-bridge-discord--act-note-tool (asb-test--tool-msg "c" "read" 'success))
      (should (string-prefix-p "-# Ran 2 commands, read a file" last)))))

(ert-deftest asb-discord-activity-finalize-then-reset ()
  (with-temp-buffer
    (let ((agent-shell-bridge-discord--post-fn (lambda (_thread _c) "id"))
          (agent-shell-bridge-discord--edit-fn (lambda (_thread _id _c) nil)))
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
         (agent-shell-bridge-discord-bot-token "TK")
         (agent-shell-bridge-discord-channel-id "chan-1")
         (agent-shell-bridge-discord--post-async-fn
          (lambda (thread content) (setq captured (list thread content))))
         (agent-shell-bridge-discord--post-fn
          (lambda (&rest _) (setq sync-called t))))
    (agent-shell-bridge-discord--send
     (agent-shell-bridge-make-message
      :role 'agent :status 'complete
      :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))
    (should (null sync-called))
    ;; no session handle -> posts to the configured channel
    (should (equal (nth 0 captured) "chan-1"))
    (should (string-prefix-p "🤖 **Agent**\nhi" (nth 1 captured)))
    ;; each message ends with the blank-line separator
    (should (string-suffix-p agent-shell-bridge-discord--separator (nth 1 captured)))))

(ert-deftest asb-discord-send-permission-is-sync-with-id ()
  ;; Permission posts synchronously and returns its id (for reaction correlation).
  (let* ((agent-shell-bridge-discord-bot-token "TK")
         (agent-shell-bridge-discord--react-fn #'ignore)
         (agent-shell-bridge-discord--post-async-fn
          (lambda (&rest _) (error "permission must not fire async")))
         (agent-shell-bridge-discord--post-fn (lambda (_thread _c) "perm-9")))
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
           (agent-shell-bridge-discord-bot-token "TK")
           (agent-shell-bridge-discord--post-fn (lambda (_thread c) (push c posts) "id"))
           (agent-shell-bridge-discord--post-async-fn
            (lambda (&rest _) (error "thinking must not post a normal message"))))
      (agent-shell-bridge-discord--send
       (agent-shell-bridge-make-message
        :role 'thinking :status 'complete
        :parts (list (agent-shell-bridge-make-part :kind 'text :content "hmm"))))
      (should (= (length posts) 1))
      (should (string-prefix-p "-# Thinking" (car posts))))))

;;;; Bot REST outbound

(ert-deftest asb-discord-async-http-uses-list-command ()
  "Every async HTTP fires make-process with :command a proper list of
strings -- guards the apply-spread class of bug that silently dropped bot
reactions -- and carries the bot Authorization header."
  (let ((captured nil)
        (agent-shell-bridge-discord-bot-token "TK"))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (push (plist-get args :command) captured) 'proc))
              ((symbol-function 'make-temp-file) (lambda (&rest _) "/tmp/asb-test-x")))
      (agent-shell-bridge-discord--bot-post-async "thread-1" "hi")
      (agent-shell-bridge-discord--bot-edit-async "thread-1" "m-1" "hi")
      (agent-shell-bridge-discord--bot-upload-async "thread-1" "t.md" "data"))
    (should (= (length captured) 3))
    (dolist (cmd captured)
      (should (listp cmd))
      (should (equal (car cmd) "curl"))
      (should (seq-every-p #'stringp cmd))
      (should (member "Authorization: Bot TK" cmd)))))

(ert-deftest asb-discord-bot-post-async-targets-thread ()
  (let ((cmd nil)
        (agent-shell-bridge-discord-bot-token "TK"))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq cmd (plist-get args :command)) 'proc)))
      (agent-shell-bridge-discord--bot-post-async "thread-9" "hi"))
    (should (member "POST" cmd))
    (should (seq-some (lambda (s)
                        (string-suffix-p "/channels/thread-9/messages" s))
                      cmd))))

(ert-deftest asb-discord-bot-edit-targets-thread-message ()
  (let ((cmd nil)
        (agent-shell-bridge-discord-bot-token "TK"))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq cmd (plist-get args :command)) 'proc)))
      (agent-shell-bridge-discord--bot-edit-async "thread-7" "m-1" "x"))
    (should (member "PATCH" cmd))
    (should (seq-some (lambda (s)
                        (string-suffix-p "/channels/thread-7/messages/m-1" s))
                      cmd))))

(ert-deftest asb-discord-bot-post-sync-returns-id-and-targets-thread ()
  (let* ((calls nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path body)
            (push (list method path body) calls)
            '((id . "posted-1")))))
    (let ((id (agent-shell-bridge-discord--bot-post-sync "thread-3" "hi")))
      (should (equal id "posted-1"))
      (let ((call (car calls)))
        (should (equal (nth 0 call) "POST"))
        (should (equal (nth 1 call) "/channels/thread-3/messages"))
        (should (equal (alist-get 'content (nth 2 call)) "hi"))))))

(ert-deftest asb-discord-send-file-part-uploads ()
  ;; A message carrying a file part (e.g. /transcript) uploads as an attachment.
  (let* ((captured nil)
         (agent-shell-bridge-discord-bot-token "TK")
         (agent-shell-bridge-discord-channel-id "chan-1")
         (agent-shell-bridge-discord--upload-fn
          (lambda (thread name data) (setq captured (list thread name data)))))
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
           (agent-shell-bridge-discord-bot-token "TK")
           (agent-shell-bridge-discord--post-fn (lambda (_thread _c) "perm-1"))
           (agent-shell-bridge-discord--react-fn
            (lambda (_thread id emoji) (push (cons id emoji) reacts))))
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

(ert-deftest asb-discord-send-errors-without-bot-token ()
  (let ((agent-shell-bridge-discord-bot-token nil))
    (should-error
     (agent-shell-bridge-discord--send
      (agent-shell-bridge-make-message
       :role 'agent :status 'complete
       :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi")))))))

;;;; Forum: per-session posts (bot thread creation)

(ert-deftest asb-discord-create-thread-posts-to-forum-and-returns-id ()
  (let* ((captured nil)
         (agent-shell-bridge-discord-channel-id "forum-42")
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path body)
            (setq captured (list method path body))
            '((id . "thread-1")))))
    (let ((id (agent-shell-bridge-discord--create-thread "Refactor the parser")))
      (should (equal id "thread-1"))
      (should (equal (nth 0 captured) "POST"))
      (should (equal (nth 1 captured) "/channels/forum-42/threads"))
      (should (equal (alist-get 'name (nth 2 captured)) "Refactor the parser"))
      ;; a starter message is required to open a forum thread
      (should (alist-get 'message (nth 2 captured))))))

(ert-deftest asb-discord-create-thread-truncates-title-to-100 ()
  (let* ((long (make-string 250 ?a))
         (agent-shell-bridge-discord-channel-id "forum-42")
         (seen nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (_m _p body) (setq seen body) '((id . "t")))))
    (agent-shell-bridge-discord--create-thread long)
    (should (<= (length (alist-get 'name seen)) 100))))

(ert-deftest asb-discord-send-threads-under-session-post ()
  (let* ((thread nil)
         (agent-shell-bridge-discord-bot-token "TK")
         (agent-shell-bridge-discord--post-async-fn
          (lambda (th _content) (setq thread th))))
    (with-temp-buffer
      (setq-local agent-shell-bridge--session-handle "thread-9")
      (agent-shell-bridge-discord--send
       (agent-shell-bridge-make-message
        :role 'agent :status 'complete
        :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi")))))
    (should (equal thread "thread-9"))))

(ert-deftest asb-discord-send-flat-without-session-handle ()
  (let* ((thread nil)
         (agent-shell-bridge-discord-bot-token "TK")
         (agent-shell-bridge-discord-channel-id "chan-root")
         (agent-shell-bridge-discord--post-async-fn
          (lambda (th _content) (setq thread th))))
    ;; no session handle bound -> post to the configured channel
    (agent-shell-bridge-discord--send
     (agent-shell-bridge-make-message
      :role 'agent :status 'complete
      :parts (list (agent-shell-bridge-make-part :kind 'text :content "hi"))))
    (should (equal thread "chan-root"))))

(ert-deftest asb-discord-start-session-flat-when-not-forum ()
  (let ((agent-shell-bridge-discord-forum-p nil))
    (should (eq (agent-shell-bridge-discord--start-session '(:name "x"))
                'discord))))

(ert-deftest asb-discord-start-session-creates-forum-post ()
  (let ((agent-shell-bridge-discord-forum-p t)
        (agent-shell-bridge-discord-channel-id "forum-42")
        (agent-shell-bridge-discord--rest-fn
         (lambda (_m _p _b) '((id . "thread-77")))))
    (should (equal (agent-shell-bridge-discord--start-session '(:title "hello"))
                   "thread-77"))))

(provide 'agent-shell-bridge-discord-test)
;;; agent-shell-bridge-discord-test.el ends here
