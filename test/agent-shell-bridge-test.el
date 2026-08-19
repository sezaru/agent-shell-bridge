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

(defun asb-test--tool-call-notif (id cmd)
  `((method . "session/update")
    (params . ((update . ((sessionUpdate . "tool_call")
                          (toolCallId . ,id)
                          (rawInput . ((command . ,cmd)))))))))

(ert-deftest asb-advice-mirrors-nothing-until-session-started ()
  "Replayed / pre-prompt notifications must not reach the provider."
  (let* ((sends 0)
         (provider (agent-shell-bridge-provider-create
                    :name 'cap3 :can-edit nil
                    :start-session (lambda (_) "t")
                    :send (lambda (_m) (cl-incf sends) nil)
                    :edit #'ignore :delete #'ignore :on-inbound #'ignore
                    :on-control #'ignore :stop #'ignore)))
    (agent-shell-bridge-register-provider provider)
    (agent-shell-bridge-set-provider 'cap3)
    (with-temp-buffer
      (setq-local agent-shell-bridge-mode t)
      ;; session not started yet -> dropped
      (agent-shell-bridge--on-notification
       #'ignore
       :state (list (cons :buffer (current-buffer)))
       :acp-notification (asb-test--tool-call-notif "t1" "ls"))
      (should (= sends 0))
      ;; once started, it flows
      (setq agent-shell-bridge--session-started t)
      (agent-shell-bridge--on-notification
       #'ignore
       :state (list (cons :buffer (current-buffer)))
       :acp-notification (asb-test--tool-call-notif "t2" "pwd"))
      (should (= sends 1)))))

(ert-deftest asb-send-command-titles-session-and-mirrors-prompt ()
  "First prompt opens the session titled by it and posts as a user message."
  (let* ((sends nil) (started nil)
         (provider (agent-shell-bridge-provider-create
                    :name 'cap :can-edit nil
                    :start-session (lambda (meta) (setq started meta) "thread-1")
                    :send (lambda (m) (push m sends) nil)
                    :edit #'ignore :delete #'ignore
                    :on-inbound #'ignore :on-control #'ignore :stop #'ignore)))
    (agent-shell-bridge-register-provider provider)
    (agent-shell-bridge-set-provider 'cap)
    (with-temp-buffer
      (setq-local agent-shell-bridge-mode t)
      (agent-shell-bridge--on-send-command #'ignore :prompt "Refactor the parser")
      ;; a second prompt must NOT re-open the session
      (setq started nil)
      (agent-shell-bridge--on-send-command #'ignore :prompt "now the AST")
      (should (null started))
      (should (equal agent-shell-bridge--session-handle "thread-1")))
    (setq sends (reverse sends))
    (should (equal (plist-get (nth 0 sends) :role) 'user))
    (should (equal (agent-shell-bridge-message-text (nth 0 sends))
                   "Refactor the parser"))
    (should (equal (agent-shell-bridge-message-text (nth 1 sends)) "now the AST"))))

(ert-deftest asb-session-link-round-trips ()
  (let ((agent-shell-bridge-session-file
         (make-temp-file "asb-sessions" nil ".eld")))
    (unwind-protect
        (progn
          (agent-shell-bridge-register-provider
           (agent-shell-bridge-provider-create :name 'discord :start-session #'ignore
            :send #'ignore :edit #'ignore :delete #'ignore :on-inbound #'ignore
            :on-control #'ignore :stop #'ignore))
          (agent-shell-bridge-set-provider 'discord)
          (agent-shell-bridge--save-handle "sid-1" "thread-1")
          (should (equal (agent-shell-bridge--load-handle "sid-1") "thread-1"))
          (should (null (agent-shell-bridge--load-handle "sid-2"))))
      (delete-file agent-shell-bridge-session-file))))

(ert-deftest asb-ensure-session-reuses-persisted-post-on-resume ()
  (let ((agent-shell-bridge-session-file
         (make-temp-file "asb-sessions" nil ".eld"))
        (created 0))
    (unwind-protect
        (let ((provider (agent-shell-bridge-provider-create
                         :name 'discord
                         :start-session (lambda (_m) (cl-incf created) "new-thread")
                         :send #'ignore :edit #'ignore :delete #'ignore
                         :on-inbound #'ignore :on-control #'ignore :stop #'ignore)))
          (agent-shell-bridge-register-provider provider)
          (agent-shell-bridge-set-provider 'discord)
          ;; first run: no link yet -> create + persist
          (with-temp-buffer
            (setq-local agent-shell--state '((:session . ((:id . "sid-9")))))
            (agent-shell-bridge--ensure-session "Title")
            (should (= created 1))
            (should (equal agent-shell-bridge--session-handle "new-thread")))
          ;; resume (fresh buffer, same session id): reuse, do NOT create
          (with-temp-buffer
            (setq-local agent-shell--state '((:session . ((:id . "sid-9")))))
            (agent-shell-bridge--ensure-session "Title")
            (should (= created 1))
            (should (equal agent-shell-bridge--session-handle "new-thread"))))
      (delete-file agent-shell-bridge-session-file))))

(ert-deftest asb-relink-registers-resumed-session-without-a-prompt ()
  "On resume, the persisted post is re-registered so inbound routes early."
  (let ((agent-shell-bridge-session-file (make-temp-file "asb-sessions" nil ".eld"))
        (relinked nil))
    (unwind-protect
        (let ((provider (agent-shell-bridge-provider-create
                         :name 'discord :start-session (lambda (_) (error "must not create"))
                         :send #'ignore :edit #'ignore :delete #'ignore
                         :on-inbound #'ignore :on-control #'ignore :stop #'ignore))
              (agent-shell-bridge--relink-functions
               (list (lambda (h) (setq relinked h)))))
          (agent-shell-bridge-register-provider provider)
          (agent-shell-bridge-set-provider 'discord)
          (agent-shell-bridge--save-handle "sid-7" "thread-7")
          (with-temp-buffer
            (setq-local agent-shell--state '((:session . ((:id . "sid-7")))))
            (should (agent-shell-bridge--try-relink))
            (should agent-shell-bridge--session-started)
            (should (equal agent-shell-bridge--session-handle "thread-7"))
            (should (equal (gethash "thread-7" agent-shell-bridge--session->buffer)
                           (current-buffer)))
            (should (equal relinked "thread-7"))
            (remhash "thread-7" agent-shell-bridge--session->buffer)))
      (delete-file agent-shell-bridge-session-file))))

(ert-deftest asb-relink-waits-when-session-id-absent ()
  "Relink defers (returns nil) until the resumed session id is available."
  (let ((agent-shell-bridge-session-file (make-temp-file "asb-sessions" nil ".eld")))
    (unwind-protect
        (with-temp-buffer
          ;; no agent-shell--state yet -> session id unknown -> not resolved
          (should (null (agent-shell-bridge--try-relink)))
          (should (null agent-shell-bridge--session-started)))
      (delete-file agent-shell-bridge-session-file))))

(ert-deftest asb-relink-new-session-resolves-without-registering ()
  "A known session with no saved post is a new session: resolve, don't link."
  (let ((agent-shell-bridge-session-file (make-temp-file "asb-sessions" nil ".eld")))
    (unwind-protect
        (let ((provider (agent-shell-bridge-provider-create
                         :name 'discord :start-session #'ignore :send #'ignore
                         :edit #'ignore :delete #'ignore :on-inbound #'ignore
                         :on-control #'ignore :stop #'ignore)))
          (agent-shell-bridge-register-provider provider)
          (agent-shell-bridge-set-provider 'discord)
          (with-temp-buffer
            (setq-local agent-shell--state '((:session . ((:id . "brand-new")))))
            (should (agent-shell-bridge--try-relink))       ; resolved
            (should (null agent-shell-bridge--session-started))   ; but not started
            (should (null agent-shell-bridge--session-handle))))
      (delete-file agent-shell-bridge-session-file))))

(ert-deftest asb-send-command-uses-first-prompt-as-title ()
  (let* ((started nil)
         (provider (agent-shell-bridge-provider-create
                    :name 'cap2 :can-edit nil
                    :start-session (lambda (meta) (setq started meta) "t")
                    :send #'ignore :edit #'ignore :delete #'ignore
                    :on-inbound #'ignore :on-control #'ignore :stop #'ignore)))
    (agent-shell-bridge-register-provider provider)
    (agent-shell-bridge-set-provider 'cap2)
    (with-temp-buffer
      (setq-local agent-shell-bridge-mode t)
      (agent-shell-bridge--on-send-command #'ignore :prompt "Build the thing"))
    (should (equal (plist-get started :title) "Build the thing"))))

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

(ert-deftest asb-teardown-session-closes-just-this-buffer ()
  "Killing one bridged buffer calls the provider's `close-session' for its
handle and unregisters it, without touching other sessions."
  (let* ((closed nil)
         (provider (agent-shell-bridge-provider-create
                    :name 'stub
                    :start-session (lambda (&rest _) "h1")
                    :send (lambda (&rest _) "1")
                    :edit (lambda (&rest _) nil)
                    :delete (lambda (&rest _) nil)
                    :on-inbound (lambda (_) nil)
                    :on-control (lambda (_) nil)
                    :close-session (lambda (h) (push h closed))
                    :stop (lambda () nil))))
    (agent-shell-bridge-register-provider provider)
    (agent-shell-bridge-set-provider 'stub)
    (clrhash agent-shell-bridge--session->buffer)
    (puthash "h1" (current-buffer) agent-shell-bridge--session->buffer)
    (puthash "h2" 'other agent-shell-bridge--session->buffer)
    (setq-local agent-shell-bridge--session-handle "h1")
    (setq-local agent-shell-bridge--session-started t)
    (agent-shell-bridge--teardown-session)
    (should (equal closed '("h1")))
    (should (null (gethash "h1" agent-shell-bridge--session->buffer)))
    (should (eq (gethash "h2" agent-shell-bridge--session->buffer) 'other))
    (should (null agent-shell-bridge--session-handle))
    ;; Idempotent: a second teardown (no handle) closes nothing more.
    (agent-shell-bridge--teardown-session)
    (should (equal closed '("h1")))))

(ert-deftest asb-agent-shell-start-advice-gates-resume ()
  "The `agent-shell--start' advice blocks a denied resume before it opens, and
lets everything else through: granted resume, no-session-id, un-mirrored id."
  (let* ((claimed nil)
         (verdict 'granted)
         (provider (agent-shell-bridge-provider-create
                    :name 'stub
                    :start-session (lambda (&rest _) "h")
                    :send (lambda (&rest _) "1")
                    :edit (lambda (&rest _) nil)
                    :delete (lambda (&rest _) nil)
                    :on-inbound (lambda (_) nil)
                    :on-control (lambda (_) nil)
                    :claim-session (lambda (h) (push h claimed) verdict)
                    :stop (lambda () nil)))
         (agent-shell-bridge-session-file
          (make-temp-file "asb-links" nil ".eld"))
         (called nil)
         (orig (lambda (&rest _) (setq called t) 'started)))
    (unwind-protect
        (progn
          (agent-shell-bridge-register-provider provider)
          (agent-shell-bridge-set-provider 'stub)
          (agent-shell-bridge--save-handle "sid" "h-sid")
          ;; granted: claim runs, original proceeds.
          (should (eq (agent-shell-bridge--on-agent-shell-start orig :session-id "sid")
                      'started))
          (should called)
          (should (equal claimed '("h-sid")))
          ;; denied: user-error before the buffer opens; original NOT called.
          (setq verdict 'denied called nil claimed nil)
          (should-error (agent-shell-bridge--on-agent-shell-start orig :session-id "sid")
                        :type 'user-error)
          (should-not called)
          (should (equal claimed '("h-sid")))
          ;; fresh start (no session-id): no claim, proceeds.
          (setq verdict 'denied called nil claimed nil)
          (agent-shell-bridge--on-agent-shell-start orig :config 'x)
          (should called)
          (should (null claimed))
          ;; resume of a session we never mirrored (no saved handle): no claim.
          (setq called nil claimed nil)
          (agent-shell-bridge--on-agent-shell-start orig :session-id "unknown")
          (should called)
          (should (null claimed)))
      (ignore-errors (delete-file agent-shell-bridge-session-file)))))

(provide 'agent-shell-bridge-test)
;;; agent-shell-bridge-test.el ends here
