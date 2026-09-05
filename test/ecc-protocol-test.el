;;; ecc-protocol-test.el --- Tests for ecc-protocol  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 0 acceptance: every recorded fixture line parses, and the JSON
;; sent back to the CLI matches section 2.3 and the appendix of
;; IMPLEMENTATION_PLAN.md byte for byte.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-core)
(require 'ecc-protocol)

;;;; Parsing

(ert-deftest ecc-protocol-test-fixtures-exist ()
  "The fixtures listed in the plan are recorded."
  (dolist (name '("basic-turn" "tool-use-write" "permission-deny-retry"
                  "plan-mode" "ask-user-question" "subagent" "compact"
                  "partial-messages"))
    (should (file-exists-p (ecc-test-fixture-file name)))))

(ert-deftest ecc-protocol-test-parse-every-fixture-line ()
  "Every line of every fixture parses into a message with a type."
  (dolist (name (ecc-test-fixture-names))
    (let ((lines (ecc-test-fixture-lines name)))
      (should (> (length lines) 0))
      (dolist (line lines)
        (let ((message (ecc-protocol-parse-line line)))
          (should (consp message))
          (should (ecc-protocol-type message))
          ;; Nothing in a recording should fall back to `unknown'.
          (should-not (eq (ecc-protocol-type message) 'unknown)))))))

(ert-deftest ecc-protocol-test-parse-keeps-bad-lines ()
  "A line that is not JSON becomes an unknown message that keeps the text."
  (let ((message (ecc-protocol-parse-line "{not json")))
    (should (eq (ecc-protocol-type message) 'unknown))
    (should (equal (alist-get 'raw message) "{not json"))
    (should (stringp (alist-get 'error message))))
  ;; A bare JSON value is valid JSON but not a protocol message.
  (should (eq (ecc-protocol-type (ecc-protocol-parse-line "42")) 'unknown)))

(ert-deftest ecc-protocol-test-parse-json-types ()
  "Arrays parse to vectors, null to nil and false to :false."
  (let ((message (ecc-protocol-parse-line
                  "{\"type\":\"t\",\"a\":[1,2],\"n\":null,\"f\":false,\"b\":true}")))
    (should (equal (alist-get 'a message) [1 2]))
    (should (eq (alist-get 'f message) :false))
    (should (eq (alist-get 'b message) t))
    (should (null (alist-get 'n message)))
    ;; A JSON null is distinguishable from an absent key by the cell.
    (should (assq 'n message))
    (should-not (assq 'missing message))))

(ert-deftest ecc-protocol-test-parsed-input-round-trips ()
  "A parsed tool input serializes back to the same JSON.
This is what makes the allow response of section 12.3 possible."
  (dolist (name '("ask-user-question" "tool-use-write" "plan-mode"))
    (let* ((request (ecc-test-find-message
                     name (lambda (m) (eq (ecc-protocol-control-subtype m) 'can_use_tool))))
           (input (alist-get 'input (alist-get 'request request))))
      (should request)
      (should input)
      (let ((json (ecc-protocol-serialize input)))
        (should (equal json (ecc-protocol-serialize (ecc--json-read json))))))))

(ert-deftest ecc-protocol-test-message-predicates ()
  "Replay echoes and synthetic replies are recognised."
  (let ((replays (seq-filter #'ecc-protocol-replay-p
                             (ecc-test-fixture-messages "replay-user-messages"))))
    (should (= (length replays) 2))
    (should (equal (mapcar (lambda (m) (alist-get 'content (alist-get 'message m))) replays)
                   '("Reply with exactly: ONE" "Reply with exactly: TWO")))
    ;; Every replay is a distinct message with its own uuid (plan 9.13).
    (should (= 2 (length (delete-dups (mapcar (lambda (m) (alist-get 'uuid m)) replays))))))
  (let ((synthetic (seq-filter #'ecc-protocol-synthetic-p
                               (ecc-test-fixture-messages "slash-commands"))))
    (should (= (length synthetic) 4))
    ;; Synthetic replies report no usage, so they cannot drive the
    ;; remaining-context estimate (plan 9.12).
    (dolist (message synthetic)
      (let ((usage (alist-get 'usage (alist-get 'message message))))
        (should (= 0 (alist-get 'input_tokens usage)))
        (should (= 0 (alist-get 'output_tokens usage)))))))

(ert-deftest ecc-protocol-test-content-blocks ()
  "Content blocks come back as a list whatever the wire shape was."
  (let ((assistant (ecc-test-find-message
                    "basic-turn"
                    (lambda (m) (and (eq (ecc-protocol-type m) 'assistant)
                                     (seq-some (lambda (b) (equal (alist-get 'type b) "text"))
                                               (ecc-protocol-content-blocks m)))))))
    (should (listp (ecc-protocol-content-blocks assistant))))
  (should (equal (ecc-protocol-content-blocks
                  '((message . ((content . "hi")))))
                 '(((type . "text") (text . "hi"))))))

;;;; Serializing

(ert-deftest ecc-protocol-test-initialize ()
  "The initialize request matches section 12.6."
  (should (equal (ecc-protocol-serialize (ecc-protocol-initialize "init-1"))
                 (concat "{\"type\":\"control_request\",\"request_id\":\"init-1\","
                         "\"request\":{\"subtype\":\"initialize\",\"hooks\":{}}}"))))

(ert-deftest ecc-protocol-test-interrupt ()
  "The interrupt request matches section 12.7."
  (should (equal (ecc-protocol-serialize (ecc-protocol-interrupt "i1"))
                 (concat "{\"type\":\"control_request\",\"request_id\":\"i1\","
                         "\"request\":{\"subtype\":\"interrupt\"}}"))))

(ert-deftest ecc-protocol-test-set-permission-mode ()
  "The set_permission_mode request matches section 12.7."
  (should (equal (ecc-protocol-serialize
                  (ecc-protocol-set-permission-mode "m1" "acceptEdits"))
                 (concat "{\"type\":\"control_request\",\"request_id\":\"m1\","
                         "\"request\":{\"subtype\":\"set_permission_mode\","
                         "\"mode\":\"acceptEdits\"}}"))))

(ert-deftest ecc-protocol-test-permission-deny ()
  "The deny response matches section 12.4."
  (should (equal (ecc-protocol-serialize
                  (ecc-protocol-permission-deny
                   "r1" "User reviewed the diff and says: write 'hello from emacs' instead."))
                 (concat "{\"type\":\"control_response\",\"response\":"
                         "{\"subtype\":\"success\",\"request_id\":\"r1\","
                         "\"response\":{\"behavior\":\"deny\",\"message\":"
                         "\"User reviewed the diff and says: write 'hello from emacs' instead.\"}}}"))))

(ert-deftest ecc-protocol-test-permission-allow ()
  "The allow response matches section 12.3 and echoes the input verbatim."
  (let* ((input (ecc--json-read "{\"file_path\":\"/tmp/hello.txt\",\"content\":\"hi\"}")))
    (should (equal (ecc-protocol-serialize
                    (ecc-protocol-permission-allow "r2" :updated-input input))
                   (concat "{\"type\":\"control_response\",\"response\":"
                           "{\"subtype\":\"success\",\"request_id\":\"r2\","
                           "\"response\":{\"behavior\":\"allow\",\"updatedInput\":"
                           "{\"file_path\":\"/tmp/hello.txt\",\"content\":\"hi\"}}}}")))))

(ert-deftest ecc-protocol-test-permission-allow-with-mode ()
  "The allow response can carry updatedPermissions, as in section 12.5."
  (should (equal (ecc-protocol-serialize
                  (ecc-protocol-permission-allow
                   "r3"
                   :updated-input nil
                   :updated-permissions (vector (ecc-protocol-set-mode-suggestion "acceptEdits"))))
                 (concat "{\"type\":\"control_response\",\"response\":"
                         "{\"subtype\":\"success\",\"request_id\":\"r3\","
                         "\"response\":{\"behavior\":\"allow\",\"updatedInput\":{},"
                         "\"updatedPermissions\":[{\"type\":\"setMode\",\"mode\":\"acceptEdits\","
                         "\"destination\":\"session\"}]}}}"))))

(ert-deftest ecc-protocol-test-answering-a-question ()
  "An AskUserQuestion allow keeps the questions and adds the answers.
multiSelect answers are one string joined with a comma and a space."
  (let* ((request (ecc-test-find-message
                   "ask-user-question"
                   (lambda (m) (eq (ecc-protocol-control-subtype m) 'can_use_tool))))
         (input (alist-get 'input (alist-get 'request request)))
         (answered (append input
                            (list (cons 'answers
                                        (ecc-protocol-answers
                                         '(("Which languages do you use?" . "Elisp, Python")))))))
         (json (ecc-protocol-serialize
                (ecc-protocol-permission-allow "r4" :updated-input answered))))
    ;; The questions array must survive as an array, not become an object.
    (should (string-search "\"questions\":[{" json))
    (should (string-search "\"answers\":{\"Which languages do you use?\":\"Elisp, Python\"}" json))
    ;; multiSelect false must stay false rather than turning into null.
    (should (string-search "\"multiSelect\":false" json))))

(ert-deftest ecc-protocol-test-user-message ()
  "A user message accepts a plain string or a vector of content blocks."
  (should (equal (ecc-protocol-serialize (ecc-protocol-user-message "hello"))
                 "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"))
  (should (equal (ecc-protocol-serialize
                  (ecc-protocol-user-message
                   (vector '((type . "text") (text . "look")))))
                 (concat "{\"type\":\"user\",\"message\":{\"role\":\"user\","
                         "\"content\":[{\"type\":\"text\",\"text\":\"look\"}]}}"))))

(ert-deftest ecc-protocol-test-arrays-must-be-vectors ()
  "A JSON array given as a list is a serialization error, not silent junk.
This is the trap of section 9, item 4; the reader returns vectors so
that parsed values can be echoed back unchanged."
  (should-error (ecc-protocol-serialize
                 `((questions . (((question . "q"))))))
                :type 'wrong-type-argument))

(ert-deftest ecc-protocol-test-control-request-field-order ()
  "Extra fields are appended to the request in the order given."
  (should (equal (ecc-protocol-serialize
                  (ecc-protocol-control-request "x" "custom" 'a 1 'b "two"))
                 (concat "{\"type\":\"control_request\",\"request_id\":\"x\","
                         "\"request\":{\"subtype\":\"custom\",\"a\":1,\"b\":\"two\"}}"))))

(ert-deftest ecc-protocol-test-request-input-echoes-null ()
  "A null inside a tool input survives the trip back to the CLI.
`alist-get' on a parsed message would turn it into an empty object."
  (let* ((line (concat "{\"type\":\"control_request\",\"request_id\":\"r\","
                       "\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"T\","
                       "\"input\":{\"a\":null,\"b\":[1,2],\"c\":false}}}"))
         (message (ecc-protocol-parse-line line)))
    (should (equal (ecc-protocol-serialize (ecc-protocol-request-input message))
                   "{\"a\":null,\"b\":[1,2],\"c\":false}"))
    ;; The naive path is the one that loses the null.
    (should (equal (ecc-protocol-serialize
                    (alist-get 'input (alist-get 'request message)))
                   "{\"a\":{},\"b\":[1,2],\"c\":false}"))))

(ert-deftest ecc-protocol-test-request-input-matches-recording ()
  "For every recorded request the echoed input equals the recorded one."
  (dolist (name (ecc-test-fixture-names))
    (dolist (line (ecc-test-fixture-lines name))
      (let ((message (ecc-protocol-parse-line line)))
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          (let ((sent (ecc-protocol-serialize (ecc-protocol-request-input message)))
                (recorded (ecc-protocol-serialize
                           (alist-get 'input
                                      (alist-get 'request (ecc--json-read-verbatim line))))))
            (should (equal sent recorded))))))))

(provide 'ecc-protocol-test)

;;; ecc-protocol-test.el ends here
