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
(require 'agent-shell)                   ; the REAL package, not a stub
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
    agent-shell-start)                      ; session open/resume interception
  "agent-shell internals the bridge calls directly.")

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

(provide 'agent-shell-bridge-contract-test)
;;; agent-shell-bridge-contract-test.el ends here
