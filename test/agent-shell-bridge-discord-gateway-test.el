;;; agent-shell-bridge-discord-gateway-test.el --- Gateway tests -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the pure gateway pieces: payload builders, the event
;; dispatch router, reaction/inbound routing, and REST body construction
;; (via a stubbed transport).  No live websocket / network.

;;; Code:

(require 'ert)
(require 'agent-shell-bridge)
(require 'agent-shell-bridge-discord-gateway)

;;;; Payload builders

(ert-deftest asb-gw-identify-carries-token-and-intents ()
  (let ((p (agent-shell-bridge-discord--identify-payload "tok" 46592)))
    (should (eql (alist-get 'op p) agent-shell-bridge-discord--op-identify))
    (should (equal (alist-get 'token (alist-get 'd p)) "tok"))
    (should (eql (alist-get 'intents (alist-get 'd p)) 46592))))

(ert-deftest asb-gw-intents-include-message-content ()
  ;; MESSAGE_CONTENT is bit 15 (32768).
  (should (/= 0 (logand agent-shell-bridge-discord--intents 32768))))

(ert-deftest asb-gw-heartbeat-carries-seq ()
  (let ((p (agent-shell-bridge-discord--heartbeat-payload 42)))
    (should (eql (alist-get 'op p) agent-shell-bridge-discord--op-heartbeat))
    (should (eql (alist-get 'd p) 42))))

;;;; Reaction mapping

(ert-deftest asb-gw-reaction-maps-to-actions ()
  (should (eq (agent-shell-bridge-discord--reaction-action "✅") 'approve))
  (should (eq (agent-shell-bridge-discord--reaction-action "❌") 'deny))
  (should (eq (agent-shell-bridge-discord--reaction-action "👀") 'expand))
  (should (eq (agent-shell-bridge-discord--reaction-action "🛑") 'interrupt))
  (should (null (agent-shell-bridge-discord--reaction-action "🍕"))))

;;;; Dispatch router

(ert-deftest asb-gw-hello-records-heartbeat-interval ()
  (let ((gw (agent-shell-bridge-discord-gateway-create)))
    (should (eq :hello
                (agent-shell-bridge-discord--on-gateway-event
                 gw '((op . 10) (d . ((heartbeat_interval . 41250)))))))
    (should (eql (agent-shell-bridge-discord-gateway-heartbeat-interval gw)
                 41250))))

(ert-deftest asb-gw-dispatch-tracks-seq-and-ready ()
  (let ((gw (agent-shell-bridge-discord-gateway-create)))
    (agent-shell-bridge-discord--on-gateway-event
     gw '((op . 0) (s . 7) (t . "READY")
          (d . ((session_id . "sess-1")
                (resume_gateway_url . "wss://resume")
                (user . ((id . "bot-99")))))))
    (should (eql (agent-shell-bridge-discord-gateway-seq gw) 7))
    (should (equal (agent-shell-bridge-discord-gateway-session-id gw) "sess-1"))
    (should (equal (agent-shell-bridge-discord-gateway-bot-user-id gw) "bot-99"))))

(ert-deftest asb-gw-message-create-injects-user-text ()
  (let* ((got nil)
         (gw (agent-shell-bridge-discord-gateway-create
              :bot-user-id "bot-99"
              :on-inbound (lambda (ev) (setq got ev)))))
    (agent-shell-bridge-discord--on-gateway-event
     gw '((op . 0) (t . "MESSAGE_CREATE")
          (d . ((content . "do the thing")
                (channel_id . "chan-1")
                (author . ((id . "user-5")))))))
    (should (equal (plist-get got :text) "do the thing"))
    (should (equal (plist-get got :session) "chan-1"))))

(ert-deftest asb-gw-message-create-ignores-bot-self ()
  (let* ((got nil)
         (gw (agent-shell-bridge-discord-gateway-create
              :bot-user-id "bot-99"
              :on-inbound (lambda (ev) (setq got ev)))))
    (agent-shell-bridge-discord--on-gateway-event
     gw '((op . 0) (t . "MESSAGE_CREATE")
          (d . ((content . "echo from bot")
                (channel_id . "chan-1")
                (author . ((id . "bot-99")))))))
    (should (null got))))

(ert-deftest asb-gw-reaction-add-routes-control ()
  (let* ((got nil)
         (gw (agent-shell-bridge-discord-gateway-create
              :on-control (lambda (ev) (setq got ev)))))
    (agent-shell-bridge-discord--on-gateway-event
     gw '((op . 0) (t . "MESSAGE_REACTION_ADD")
          (d . ((message_id . "m-1")
                (channel_id . "chan-1")
                (emoji . ((name . "✅")))))))
    (should (eq (plist-get got :action) 'approve))
    (should (equal (plist-get got :target) "m-1"))))

;;;; REST send/edit (stubbed transport)

(ert-deftest asb-gw-send-posts-message-and-returns-id ()
  (let* ((calls nil)
         (agent-shell-bridge-discord-channel-id "chan-1")
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path body)
            (push (list method path body) calls)
            '((id . "posted-1")))))
    (let ((id (agent-shell-bridge-discord-gateway--send
               (agent-shell-bridge-make-message
                :role 'agent :status 'complete
                :parts (list (agent-shell-bridge-make-part
                              :kind 'text :content "hi"))))))
      (should (equal id "posted-1"))
      (let ((call (car calls)))
        (should (equal (nth 0 call) "POST"))
        (should (equal (nth 1 call) "/channels/chan-1/messages"))
        (should (equal (alist-get 'content (nth 2 call)) "🤖 **Agent**\nhi"))))))

(ert-deftest asb-gw-edit-patches-message ()
  (let* ((calls nil)
         (agent-shell-bridge-discord-channel-id "chan-1")
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path body) (push (list method path body) calls) nil)))
    (agent-shell-bridge-discord-gateway--edit
     "m-9" (agent-shell-bridge-make-message
            :role 'agent :status 'complete
            :parts (list (agent-shell-bridge-make-part :kind 'text :content "x"))))
    (let ((call (car calls)))
      (should (equal (nth 0 call) "PATCH"))
      (should (equal (nth 1 call) "/channels/chan-1/messages/m-9")))))

(provide 'agent-shell-bridge-discord-gateway-test)
;;; agent-shell-bridge-discord-gateway-test.el ends here
