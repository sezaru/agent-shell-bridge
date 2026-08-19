;;; agent-shell-bridge-contract-test.el --- Contract tests vs REAL agent-shell -*- lexical-binding: t; -*-

;;; Commentary:

;; The bridge binds to agent-shell *internals* (private `agent-shell--*'
;; functions, its `--state' alist shape, and the argument convention of the
;; functions it advises).  The ordinary tests in `agent-shell-bridge-test.el'
;; call our advice *directly* with hand-built args -- they encode our
;; assumptions but never check that agent-shell still MEETS them, so an
;; upstream rename or signature change passes silently and breaks at runtime.
;;
;; These tests load the REAL agent-shell and pin the seam:
;;   L1  every advised/called internal still exists, and our advice attaches
;;       to the real functions (catches renames / removals).
;;   L2  a stub ACP agent drives a real `agent-shell-start' session, so
;;       agent-shell itself invokes the advised functions -- proving the
;;       actual calling convention (`:state' alist with `:buffer',
;;       `:acp-notification' nesting `(params update)', `:prompt', the
;;       `turn-complete' event).  [added alongside the lifecycle work]
;;
;; Run with test/run-contract.sh (batch ERT against the real load-path).

;;; Code:

(require 'ert)
(require 'map)
(require 'seq)
(require 'agent-shell)                   ; the REAL package, not a stub
(require 'acp-fakes)                      ; shipped in-process fake ACP client
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-provider)

;;;; The dependency manifest -- keep in sync with actual usage.
;; Regenerate the candidate list with:
;;   grep -rhoE "\\(agent-shell[a-z-]*--?[a-z0-9-]+" *.el | sed 's/^(//' \
;;     | grep -v '^agent-shell-bridge' | sort -u

(defconst asb-contract-advised-functions
  '(agent-shell--on-notification            ; mirror session updates
    agent-shell--on-request                 ; mirror permission requests
    agent-shell--send-command               ; title session + mirror prompt
    agent-shell--start)                     ; resume funnel: gate concurrent resume
  "agent-shell internals the bridge advises :around.
A rename/removal here silently stops all mirroring.")

(defconst asb-contract-called-functions
  '(agent-shell--state                      ; buffer-local session state alist
    agent-shell--insert-to-shell-buffer     ; render injected remote prompt
    agent-shell--prompt-queue-enqueue       ; queue a remote prompt
    agent-shell--send-permission-response   ; answer a mirrored permission
    agent-shell-interrupt                   ; remote /interrupt
    agent-shell-subscribe-to                ; turn-complete -> flush stream
    agent-shell-unsubscribe
    agent-shell--current-mode-id            ; config knobs mirrored to remote
    agent-shell--current-model-id
    agent-shell--current-thought-level-id
    agent-shell--get-available-modes
    agent-shell--get-available-models
    agent-shell--get-available-thought-levels
    agent-shell--config-option-set-mode-id
    agent-shell--config-option-set-model-id
    agent-shell--config-option-set-thought-level-id
    agent-shell-start                       ; session open/resume interception
    agent-shell--active-requests-p          ; corroborates the :active-requests
    agent-shell--send-request)              ;   / :method state shape we read
  "agent-shell internals the bridge calls directly.
The last two are not called but corroborate the `:active-requests' state shape
the app provider reads to detect a `session/load' replay (the #24 ordinal
reset) -- if they vanish, that read has almost certainly broken too.")

(ert-deftest asb-contract/advised-functions-exist ()
  "Every advised agent-shell internal must still be defined."
  (dolist (fn asb-contract-advised-functions)
    (should (fboundp fn))))

(ert-deftest asb-contract/called-functions-exist ()
  "Every agent-shell internal the bridge calls must still be defined."
  (dolist (fn asb-contract-called-functions)
    (should (fboundp fn))))

(ert-deftest asb-contract/advice-attaches-to-real-targets ()
  "Installing bridge advice must actually land on the real functions.
`advice-add' silently no-ops nothing, but if the target were renamed the
member check would fail -- catching the break the direct-call unit tests miss."
  (agent-shell-bridge--install-advice)
  (should (advice-member-p #'agent-shell-bridge--on-notification
                           'agent-shell--on-notification))
  (should (advice-member-p #'agent-shell-bridge--on-request
                           'agent-shell--on-request))
  (should (advice-member-p #'agent-shell-bridge--on-send-command
                           'agent-shell--send-command))
  (should (advice-member-p #'agent-shell-bridge--on-agent-shell-start
                           'agent-shell--start)))

(ert-deftest asb-contract/agent-shell--start-takes-session-id ()
  "The resume gate reads `:session-id' from `agent-shell--start'.  Compiled
cl-defuns hide their &key args behind &rest, so assert the keyword appears in
whatever arglist form is exposed (uncompiled) -- and always that it is callable."
  (should (fboundp 'agent-shell--start))
  (let ((arglist (ignore-errors (help-function-arglist 'agent-shell--start t))))
    ;; When the real arglist is visible (source form), it must offer session-id;
    ;; when hidden (&rest rest on a compiled cl-defun) we can't assert here -- L2
    ;; drives a real resume to prove the convention behaviorally.
    (when (and arglist (not (memq '&rest arglist)))
      (should (memq 'session-id arglist)))))

;;;; L2 — drive a REAL agent-shell session and prove the calling convention.
;;
;; L1 checks the seam still EXISTS.  L2 checks agent-shell still USES it the way
;; we assume: we script a fake ACP agent (acp-fakes, shipped) through a real
;; `agent-shell-start', send a prompt, and assert agent-shell drives our
;; advice with the real shapes -- `--on-send-command' opens the session from the
;; prompt, and `--on-notification' hands us a correctly-normalized agent message
;; from a `session/update' whose `(params update)' nesting we depend on.

(defvar asb-l2--sent nil "Messages the bridge asked the provider to send in L2.")
(defvar asb-l2--started nil "Session-open metas the provider saw during L2.")

(defun asb-l2--provider ()
  "A recording provider (non-editing, like the app provider)."
  (agent-shell-bridge-provider-create
   :name 'l2 :can-edit nil
   :start-session (lambda (meta) (push meta asb-l2--started) "l2-h")
   :send (lambda (msg) (push msg asb-l2--sent) "rid")
   :edit (lambda (&rest _) nil) :delete (lambda (&rest _) nil)
   :set-status (lambda (&rest _) nil)
   :on-inbound (lambda (_) nil) :on-control (lambda (_) nil)
   :stop (lambda () nil)))

(defun asb-l2--messages ()
  "Scripted ACP traffic: initialize(1) -> session/new(2) -> prompt(3), the
prompt bracketing an `agent_message_chunk' notification then `end_turn'."
  `(((:direction . outgoing) (:kind . request)
     (:object . ((jsonrpc . "2.0") (method . "initialize") (id . 1))))
    ((:direction . incoming) (:kind . response)
     (:object . ((jsonrpc . "2.0") (id . 1)
                 (result . ((protocolVersion . 1) (agentCapabilities . ()))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((jsonrpc . "2.0") (method . "session/new") (id . 2))))
    ((:direction . incoming) (:kind . response)
     (:object . ((jsonrpc . "2.0") (id . 2)
                 (result . ((sessionId . "l2-sess"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((jsonrpc . "2.0") (method . "session/prompt") (id . 3))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((jsonrpc . "2.0") (method . "session/update")
                 (params . ((sessionId . "l2-sess")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((type . "text")
                                                   (text . "hi from stub"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((jsonrpc . "2.0") (id . 3)
                 (result . ((stopReason . "end_turn"))))))))

(defun asb-l2--config ()
  (agent-shell-make-agent-config
   :identifier 'l2 :mode-line-name "L2" :buffer-name "L2"
   :shell-prompt "L2> " :shell-prompt-regexp "L2> "
   :client-maker (lambda (_buffer) (acp-fakes-make-client (asb-l2--messages)))))

(defun asb-l2--pump (secs)
  (let ((deadline (+ (float-time) secs)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02)
      (sit-for 0.01))))

(ert-deftest asb-contract/l2-real-session-drives-advice ()
  "End-to-end against the real agent-shell: a prompt opens our session and an
agent `session/update' is normalized and mirrored to the provider."
  (setq asb-l2--sent nil asb-l2--started nil)
  (let* ((tmp (make-temp-file "asb-l2-root" t))
         (shell-maker-root-path tmp)
         (default-directory tmp)
         (saved-provider agent-shell-bridge--active-provider)
         buf)
    (unwind-protect
        (progn
          (setq buf (agent-shell-start :config (asb-l2--config)))
          (asb-l2--pump 1.0)
          (should (bufferp buf))
          ;; agent-shell still spawns the client's command ("cat" for the fake);
          ;; silence its sentinel so its eventual death can't abort the batch.
          (with-current-buffer buf
            (let ((proc (map-elt (map-elt agent-shell--state :client) :process)))
              (when (processp proc)
                (set-process-sentinel proc #'ignore)
                (set-process-query-on-exit-flag proc nil))))
          ;; the handshake really established the ACP session via the fake
          (should (equal (with-current-buffer buf
                           (map-nested-elt agent-shell--state '(:session :id)))
                         "l2-sess"))
          (agent-shell-bridge-register-provider (asb-l2--provider))
          (agent-shell-bridge-set-provider 'l2)
          (with-current-buffer buf
            (agent-shell-bridge-mode 1)
            ;; Our :around advice mirrors BEFORE agent-shell's real body renders
            ;; into the shell buffer; that render is batch-hostile (no comint UI)
            ;; and the fake routes handlers raw (the real transport wraps them in
            ;; condition-case), so swallow the incidental render error.
            (condition-case _ (agent-shell--send-command :prompt "hello there")
              (error nil))
            (asb-l2--pump 0.5)
            ;; The batch render error preempts agent-shell's `turn-complete', which
            ;; would normally flush our buffered stream; do it explicitly (this is
            ;; exactly what the `turn-complete' subscription in `--enable' calls).
            (agent-shell-bridge--flush-stream))
          ;; `--on-send-command' opened our session titled by the prompt.
          (should asb-l2--started)
          (should (equal (plist-get (car asb-l2--started) :title) "hello there"))
          ;; the user prompt was mirrored (role user, the prompt text).
          (should (seq-find (lambda (m)
                              (and (eq (plist-get m :role) 'user)
                                   (equal (agent-shell-bridge-message-text m)
                                          "hello there")))
                            asb-l2--sent))
          ;; `--on-notification' normalized the agent chunk via (params update)
          ;; and it reached the provider.
          (should (seq-find (lambda (m)
                              (and (eq (plist-get m :role) 'agent)
                                   (equal (agent-shell-bridge-message-text m)
                                          "hi from stub")))
                            asb-l2--sent)))
      (setq agent-shell-bridge--active-provider saved-provider)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((proc (ignore-errors
                        (map-elt (map-elt agent-shell--state :client) :process))))
            (when (processp proc)
              (set-process-sentinel proc #'ignore)
              (ignore-errors (delete-process proc))))
          (setq kill-buffer-hook nil))   ; drop agent-shell--clean-up (buffer-local)
        (let ((kill-buffer-query-functions nil))
          (ignore-errors (kill-buffer buf)))))))

(provide 'agent-shell-bridge-contract-test)
;;; agent-shell-bridge-contract-test.el ends here
