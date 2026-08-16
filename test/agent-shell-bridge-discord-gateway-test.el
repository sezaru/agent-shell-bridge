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
                (user_id . "human-1")
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

;;;; Reaction markers

(ert-deftest asb-gw-react-builds-put-reaction-path ()
  (let* ((calls nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (m p _b) (push (list m p) calls) nil)))
    (agent-shell-bridge-discord--react "chan-1" "msg-1" "✅")
    (let ((call (car calls)))
      (should (equal (nth 0 call) "PUT"))
      (should (string-prefix-p "/channels/chan-1/messages/msg-1/reactions/" (nth 1 call)))
      (should (string-suffix-p "/@me" (nth 1 call))))))

(ert-deftest asb-gw-mark-picks-consumed-or-rejected ()
  (let* ((emojis nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (_m p _b) (push p emojis) nil)))
    (agent-shell-bridge-discord--mark "c" "m" t)
    (agent-shell-bridge-discord--mark "c" "m" nil)
    (setq emojis (reverse emojis))       ; chronological
    (should (string-match-p (url-hexify-string "✅") (nth 0 emojis)))
    (should (string-match-p (url-hexify-string "❌") (nth 1 emojis)))))

(ert-deftest asb-gw-bot-marked-p-detects-own-reaction ()
  (should (agent-shell-bridge-discord--bot-marked-p
           '((reactions . [((me . t) (emoji . ((name . "✅"))))]))))
  (should-not (agent-shell-bridge-discord--bot-marked-p
               '((reactions . [((me . :false) (emoji . ((name . "👍"))))]))))
  (should-not (agent-shell-bridge-discord--bot-marked-p '())))

(ert-deftest asb-gw-unprocessed-filters-bot-and-marked ()
  (let ((messages
         (vector
          '((id . "a") (content . "run this") (author . ((id . "u1"))))          ; unprocessed
          '((id . "b") (content . "bot msg") (author . ((id . "bot") (bot . t)))) ; bot -> skip
          '((id . "c") (content . "already") (author . ((id . "u1")))
            (reactions . [((me . t) (emoji . ((name . "✅"))))])))))              ; marked -> skip
    (let ((ids (mapcar (lambda (m) (alist-get 'id m))
                       (agent-shell-bridge-discord--unprocessed-user-messages messages))))
      (should (equal ids '("a"))))))

(ert-deftest asb-gw-reject-stale-marks-each-with-x ()
  (let* ((puts nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path _b)
            (cond ((equal method "GET")
                   (vector '((id . "a") (author . ((id . "u1"))))
                           '((id . "b") (author . ((id . "u1"))))))
                  ((equal method "PUT") (push path puts) nil)))))
    (agent-shell-bridge-discord--reject-stale "chan-1")
    (should (= (length puts) 2))
    (should (seq-every-p (lambda (p) (string-match-p (url-hexify-string "❌") p)) puts))))

(ert-deftest asb-gw-live-message-consumed-gets-check ()
  (let* ((puts nil) (injected nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path _b) (when (equal method "PUT") (push path puts)) nil))
         (gw (agent-shell-bridge-discord-gateway-create
              :bot-user-id "bot-99"
              :on-inbound (lambda (ev) (setq injected ev) (list :status 'consumed)))))
    (agent-shell-bridge-discord--on-gateway-event
     gw '((op . 0) (t . "MESSAGE_CREATE")
          (d . ((id . "m-7") (content . "do it")
                (channel_id . "chan-1") (author . ((id . "u1")))))))
    (should (equal (plist-get injected :text) "do it"))
    (should (= (length puts) 1))
    (should (string-match-p "/messages/m-7/reactions/" (car puts)))
    (should (string-match-p (url-hexify-string "✅") (car puts)))))

(ert-deftest asb-gw-refused-busy-gets-x-plus-hourglass ()
  (let* ((puts nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path _b) (when (equal method "PUT") (push path puts)) nil))
         (gw (agent-shell-bridge-discord-gateway-create
              :bot-user-id "bot-99"
              :on-inbound (lambda (_ev) (list :status 'refused :reason 'busy)))))
    (agent-shell-bridge-discord--on-gateway-event
     gw '((op . 0) (t . "MESSAGE_CREATE")
          (d . ((id . "m-8") (content . "later") (channel_id . "c")
                (author . ((id . "u1")))))))
    (should (= (length puts) 2))
    (should (seq-some (lambda (p) (string-match-p (url-hexify-string "❌") p)) puts))
    (should (seq-some (lambda (p) (string-match-p (url-hexify-string "⏳") p)) puts))))

(ert-deftest asb-gw-command-gets-stop-mark ()
  (let ((res (agent-shell-bridge-discord--mark-result
              "c" "m" '(:status command :action interrupt)))
        (puts nil))
    (ignore res)
    (let ((agent-shell-bridge-discord--rest-fn
           (lambda (_m p _b) (push p puts) nil)))
      (agent-shell-bridge-discord--mark-result "c" "m" '(:status command))
      (should (string-match-p (url-hexify-string "🛑") (car puts))))))

(ert-deftest asb-gw-set-status-running-swaps-reactions ()
  (let* ((calls nil)
         (agent-shell-bridge-discord--rest-fn
          (lambda (method path _b) (push (list method path) calls) nil)))
    (agent-shell-bridge-discord--set-status "thread-1" t)
    (setq calls (reverse calls))
    ;; first removes 💤, then adds 🟢, both targeting the starter (== thread id)
    (should (equal (nth 0 (nth 0 calls)) "DELETE"))
    (should (string-match-p (url-hexify-string "💤") (nth 1 (nth 0 calls))))
    (should (equal (nth 0 (nth 1 calls)) "PUT"))
    (should (string-match-p (url-hexify-string "⚙️") (nth 1 (nth 1 calls))))
    (should (string-match-p "/messages/thread-1/" (nth 1 (nth 1 calls))))))

(ert-deftest asb-gw-reaction-ignores-bot-own ()
  (let* ((fired nil)
         (gw (agent-shell-bridge-discord-gateway-create
              :bot-user-id "bot-99"
              :on-control (lambda (ev) (setq fired ev)))))
    ;; a reaction added by the bot itself must not be treated as a control
    (agent-shell-bridge-discord--route-reaction
     gw '((message_id . "m") (channel_id . "c")
          (user_id . "bot-99") (emoji . ((name . "✅")))))
    (should (null fired))
    ;; a human reaction does fire
    (agent-shell-bridge-discord--route-reaction
     gw '((message_id . "m") (channel_id . "c")
          (user_id . "human-1") (emoji . ((name . "✅")))))
    (should (eq (plist-get fired :action) 'approve))))

(provide 'agent-shell-bridge-discord-gateway-test)
;;; agent-shell-bridge-discord-gateway-test.el ends here
