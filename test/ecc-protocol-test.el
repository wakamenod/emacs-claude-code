;;; ecc-protocol-test.el --- Tests for ecc-protocol  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 0 acceptance: every recorded fixture line parses, and the JSON
;; sent back to the CLI matches what the CLI expects byte for byte.

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
This is what makes the allow response possible."
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
    ;; Every replay is a distinct message with its own uuid.
    (should (= 2 (length (delete-dups (mapcar (lambda (m) (alist-get 'uuid m)) replays))))))
  (let ((synthetic (seq-filter #'ecc-protocol-synthetic-p
                               (ecc-test-fixture-messages "slash-commands"))))
    (should (= (length synthetic) 4))
    ;; Synthetic replies report no usage, so they cannot drive the
    ;; remaining-context estimate.
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
  "The initialize request matches what the CLI expects."
  (should (equal (ecc-protocol-serialize (ecc-protocol-initialize "init-1"))
                 (concat "{\"type\":\"control_request\",\"request_id\":\"init-1\","
                         "\"request\":{\"subtype\":\"initialize\",\"hooks\":{}}}"))))

(ert-deftest ecc-protocol-test-interrupt ()
  "The interrupt request matches what the CLI expects."
  (should (equal (ecc-protocol-serialize (ecc-protocol-interrupt "i1"))
                 (concat "{\"type\":\"control_request\",\"request_id\":\"i1\","
                         "\"request\":{\"subtype\":\"interrupt\"}}"))))

(ert-deftest ecc-protocol-test-set-permission-mode ()
  "The set_permission_mode request matches what the CLI expects."
  (should (equal (ecc-protocol-serialize
                  (ecc-protocol-set-permission-mode "m1" "acceptEdits"))
                 (concat "{\"type\":\"control_request\",\"request_id\":\"m1\","
                         "\"request\":{\"subtype\":\"set_permission_mode\","
                         "\"mode\":\"acceptEdits\"}}"))))

(ert-deftest ecc-protocol-test-permission-deny ()
  "The deny response matches what the CLI expects."
  (should (equal (ecc-protocol-serialize
                  (ecc-protocol-permission-deny
                   "r1" "User reviewed the diff and says: write 'hello from emacs' instead."))
                 (concat "{\"type\":\"control_response\",\"response\":"
                         "{\"subtype\":\"success\",\"request_id\":\"r1\","
                         "\"response\":{\"behavior\":\"deny\",\"message\":"
                         "\"User reviewed the diff and says: write 'hello from emacs' instead.\"}}}"))))

(ert-deftest ecc-protocol-test-permission-allow ()
  "The allow response matches what the CLI expects, input echoed verbatim."
  (let* ((input (ecc--json-read "{\"file_path\":\"/tmp/hello.txt\",\"content\":\"hi\"}")))
    (should (equal (ecc-protocol-serialize
                    (ecc-protocol-permission-allow "r2" :updated-input input))
                   (concat "{\"type\":\"control_response\",\"response\":"
                           "{\"subtype\":\"success\",\"request_id\":\"r2\","
                           "\"response\":{\"behavior\":\"allow\",\"updatedInput\":"
                           "{\"file_path\":\"/tmp/hello.txt\",\"content\":\"hi\"}}}}")))))

(ert-deftest ecc-protocol-test-permission-allow-with-mode ()
  "The allow response can carry updatedPermissions."
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
This is the trap of `json-serialize'; the reader returns vectors so that
parsed values can be echoed back unchanged."
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

(ert-deftest ecc-protocol-test-settings-json ()
  "Disabled plugins turn into an enabledPlugins override for --settings."
  (should (null (ecc-protocol-settings-json nil)))
  (should (equal (ecc-protocol-settings-json '("emacs-bridge@emacs-gravity-marketplace"))
                 (concat "{\"enabledPlugins\":"
                         "{\"emacs-bridge@emacs-gravity-marketplace\":false}}")))
  (should (equal (ecc-protocol-settings-json '("a@m" "b@m"))
                 "{\"enabledPlugins\":{\"a@m\":false,\"b@m\":false}}")))

;;;; Settings files

(ert-deftest ecc-protocol-test-settings-add-allow-creates-the-file ()
  "A missing settings file is created with the permissions.allow list."
  (let* ((root (make-temp-file "ecc-settings" t))
         (file (expand-file-name ".claude/settings.local.json" root)))
    (unwind-protect
        (progn
          (should (equal (ecc-protocol-settings-add-allow file '("Bash(git *)"))
                         '("Bash(git *)")))
          (should (file-exists-p file))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                         "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(git *)\"\n    ]\n  }\n}\n"))
          ;; Adding the same pattern again changes nothing.
          (should-not (ecc-protocol-settings-add-allow file '("Bash(git *)")))
          (should (equal (ecc-protocol-settings-add-allow file '("Bash(git *)" "Edit(src/**)"))
                         '("Edit(src/**)"))))
      (delete-directory root t))))

(ert-deftest ecc-protocol-test-settings-add-allow-keeps-other-keys ()
  "Everything else in the file survives, including {} [] false and null."
  (let ((file (make-temp-file "ecc-settings" nil ".json"
                              "{\"hooks\":{},\"permissions\":{\"allow\":[\"A\"],\"deny\":[]},\"flag\":false,\"nothing\":null}")))
    (unwind-protect
        (progn
          (ecc-protocol-settings-add-allow file '("B"))
          (let ((object (ecc-protocol-read-settings-file file)))
            (should (equal (ecc-protocol-settings-allow-list object) '("A" "B")))
            (should (equal (alist-get 'deny (alist-get 'permissions object)) []))
            (should (equal (alist-get 'hooks object) nil))
            (should (eq (alist-get 'flag object) :false))
            (should (eq (alist-get 'nothing object) :null)))
          (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (string-search "\"hooks\": {}" text))
            (should (string-search "\"deny\": []" text))
            (should (string-search "\"flag\": false" text))
            (should (string-search "\"nothing\": null" text))))
      (delete-file file))))

(ert-deftest ecc-protocol-test-settings-add-allow-refuses-a-broken-file ()
  "A file that does not parse is reported and never written over (9.16)."
  (let ((file (make-temp-file "ecc-settings" nil ".json" "{not json")))
    (unwind-protect
        (progn
          (should-error (ecc-protocol-settings-add-allow file '("A")))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                         "{not json")))
      (delete-file file))))

(defmacro ecc-protocol-test--with-settings (var text &rest body)
  "Bind VAR to a settings file holding TEXT and run BODY, then delete it.
TEXT nil leaves the file absent, which is what a machine with no hooks
of its own looks like."
  (declare (indent 2))
  `(let ((,var (if ,text
                   (make-temp-file "ecc-hooks" nil ".json" ,text)
                 (expand-file-name (format "ecc-hooks-%s.json" (random 100000))
                                   temporary-file-directory))))
     (unwind-protect (progn ,@body)
       (when (file-exists-p ,var) (delete-file ,var)))))

(ert-deftest ecc-protocol-test-hook-entries-carry-their-address ()
  "Every hook of a settings file is read out with the address of its entry."
  (let ((object (ecc--json-read-verbatim "
{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"Write|Edit\",
                             \"hooks\": [{\"type\": \"command\", \"command\": \"a\"},
                                        {\"type\": \"command\", \"command\": \"b\"}]},
                            {\"hooks\": [{\"type\": \"command\", \"command\": \"c\"}]}],
             \"Stop\": [{\"matcher\": \"\",
                        \"hooks\": [{\"type\": \"command\", \"command\": \"d\"}]}]}}")))
    (let ((entries (ecc-protocol-settings-hook-entries object)))
      (should (equal (mapcar (lambda (e) (list (plist-get e :event)
                                               (plist-get e :matcher)
                                               (plist-get e :group-index)
                                               (plist-get e :hook-index)
                                               (alist-get 'command (plist-get e :entry))))
                             entries)
                     '(("PreToolUse" "Write|Edit" 0 0 "a")
                       ("PreToolUse" "Write|Edit" 0 1 "b")
                       ;; A group with no matcher, and one whose matcher
                       ;; is the empty string, both match everything.
                       ("PreToolUse" nil 1 0 "c")
                       ("Stop" nil 0 0 "d")))))))

(ert-deftest ecc-protocol-test-hook-entries-skips-what-it-cannot-read ()
  "A hooks block of an unexpected shape yields nothing, and never signals."
  (dolist (text '("{}" "{\"hooks\": {}}" "{\"hooks\": []}"
                  "{\"hooks\": {\"Stop\": {}}}"
                  "{\"hooks\": {\"Stop\": [{\"hooks\": {}}]}}"))
    (should-not (ecc-protocol-settings-hook-entries
                 (ecc--json-read-verbatim text)))))

(ert-deftest ecc-protocol-test-add-hook-creates-the-file ()
  "A missing settings file is created with the hook, indented."
  (ecc-protocol-test--with-settings file nil
    (should (equal (ecc-protocol-settings-add-hook
                    file "PreToolUse" "Write"
                    '((type . "command") (command . "echo hi")))
                   '(0 . 0)))
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"Write\",\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"echo hi\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"))))

(ert-deftest ecc-protocol-test-add-hook-joins-a-matcher-group ()
  "A second hook for the same matcher joins the group instead of making one."
  (ecc-protocol-test--with-settings file "{}"
    (ecc-protocol-settings-add-hook file "PreToolUse" "Write"
                                    '((type . "command") (command . "a")))
    (should (equal (ecc-protocol-settings-add-hook
                    file "PreToolUse" "Write" '((type . "command") (command . "b")))
                   '(0 . 1)))
    ;; A different matcher, and no matcher at all, are groups of their own.
    (should (equal (ecc-protocol-settings-add-hook
                    file "PreToolUse" "Read" '((type . "command") (command . "c")))
                   '(1 . 0)))
    (should (equal (ecc-protocol-settings-add-hook
                    file "PreToolUse" nil '((type . "command") (command . "d")))
                   '(2 . 0)))
    (should (equal (mapcar (lambda (e) (list (plist-get e :matcher)
                                             (alist-get 'command (plist-get e :entry))))
                           (ecc-protocol-settings-hook-entries
                            (ecc-protocol-read-settings-file file)))
                   '(("Write" "a") ("Write" "b") ("Read" "c") (nil "d"))))))

(ert-deftest ecc-protocol-test-add-hook-keeps-other-keys ()
  "Everything else in the file survives a hook being added, null included."
  (ecc-protocol-test--with-settings file
      "{\"permissions\":{\"allow\":[\"A\"]},\"flag\":false,\"nothing\":null}"
    (ecc-protocol-settings-add-hook file "Stop" nil
                                    '((type . "command") (command . "a")))
    (let ((object (ecc-protocol-read-settings-file file)))
      (should (equal (ecc-protocol-settings-allow-list object) '("A")))
      (should (eq (alist-get 'flag object) :false))
      (should (eq (alist-get 'nothing object) :null)))
    ;; The keys that were there keep their order and the new one goes
    ;; last: an edit to the hooks must not shuffle the whole file.
    (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (should (< (string-search "\"permissions\"" text)
                 (string-search "\"nothing\"" text)
                 (string-search "\"hooks\"" text))))))

(ert-deftest ecc-protocol-test-add-hook-refuses-a-broken-file ()
  "A file that does not parse is reported and never written over."
  (ecc-protocol-test--with-settings file "{not json"
    (should-error (ecc-protocol-settings-add-hook
                   file "Stop" nil '((type . "command") (command . "a"))))
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "{not json"))))

(ert-deftest ecc-protocol-test-remove-hook-folds-what-it-empties ()
  "Removing the last hook takes its group, its event and the block with it."
  (ecc-protocol-test--with-settings file "{\"permissions\":{\"allow\":[\"A\"]}}"
    (ecc-protocol-settings-add-hook file "PreToolUse" "Write"
                                    '((type . "command") (command . "a")))
    (ecc-protocol-settings-add-hook file "PreToolUse" "Write"
                                    '((type . "command") (command . "b")))
    (ecc-protocol-settings-add-hook file "Stop" nil
                                    '((type . "command") (command . "c")))
    ;; The entry comes back, so that the caller can stash it.
    (should (equal (alist-get 'command
                              (ecc-protocol-settings-remove-hook file "PreToolUse" 0 0))
                   "a"))
    (should (equal (mapcar (lambda (e) (alist-get 'command (plist-get e :entry)))
                           (ecc-protocol-settings-hook-entries
                            (ecc-protocol-read-settings-file file)))
                   '("b" "c")))
    (ecc-protocol-settings-remove-hook file "PreToolUse" 0 0)
    (should-not (alist-get 'PreToolUse
                           (alist-get 'hooks (ecc-protocol-read-settings-file file))))
    (ecc-protocol-settings-remove-hook file "Stop" 0 0)
    (let ((object (ecc-protocol-read-settings-file file)))
      (should-not (assq 'hooks object))
      (should (equal (ecc-protocol-settings-allow-list object) '("A"))))))

(ert-deftest ecc-protocol-test-remove-hook-refuses-an-address-that-names-nothing ()
  "An address no longer in the file signals rather than removing something else."
  (ecc-protocol-test--with-settings file "{}"
    (ecc-protocol-settings-add-hook file "Stop" nil
                                    '((type . "command") (command . "a")))
    (should-error (ecc-protocol-settings-remove-hook file "Stop" 0 1))
    (should-error (ecc-protocol-settings-remove-hook file "Stop" 1 0))
    (should-error (ecc-protocol-settings-remove-hook file "PostToolUse" 0 0))
    (should (equal (length (ecc-protocol-settings-hook-entries
                            (ecc-protocol-read-settings-file file)))
                   1))))

(ert-deftest ecc-protocol-test-stash-round-trip ()
  "A hook taken out of a settings file comes back out of the stash unchanged."
  (ecc-protocol-test--with-settings stash nil
    (let ((entry '((type . "command") (command . "echo hi") (timeout . 60))))
      (should-not (ecc-protocol-stash-entries stash))
      (should (equal (ecc-protocol-stash-add stash "/s.json" "PreToolUse" "Write" entry)
                     0))
      (should (equal (ecc-protocol-stash-add stash "/s.json" "PreToolUse" nil entry)
                     1))
      (let ((entries (ecc-protocol-stash-entries stash)))
        (should (equal (mapcar (lambda (e) (list (plist-get e :settings-file)
                                                 (plist-get e :event)
                                                 (plist-get e :matcher)
                                                 (plist-get e :index)))
                               entries)
                       '(("/s.json" "PreToolUse" "Write" 0)
                         ("/s.json" "PreToolUse" nil 1))))
        (should (equal (plist-get (car entries) :entry) entry)))
      ;; Taking one out leaves the other, and emptying the stash leaves
      ;; neither the event nor the file behind.
      (should (equal (ecc-protocol-stash-remove stash "/s.json" "PreToolUse" 0) entry))
      (should (equal (length (ecc-protocol-stash-entries stash)) 1))
      (ecc-protocol-stash-remove stash "/s.json" "PreToolUse" 0)
      (should-not (ecc-protocol-stash-entries stash))
      (should-error (ecc-protocol-stash-remove stash "/s.json" "PreToolUse" 0)))))

(ert-deftest ecc-protocol-test-request-suggestions-verbatim ()
  "Suggestions come back exactly as sent, or nil when absent."
  (let ((edit (ecc-test-find-message
               "edit-tool" (lambda (m) (eq (ecc-protocol-control-subtype m) 'can_use_tool))))
        (question (ecc-test-find-message
                   "ask-user-question"
                   (lambda (m) (eq (ecc-protocol-control-subtype m) 'can_use_tool)))))
    (should (equal (ecc-protocol-serialize (ecc-protocol-request-suggestions edit))
                   "[{\"type\":\"setMode\",\"mode\":\"acceptEdits\",\"destination\":\"session\"}]"))
    (should-not (ecc-protocol-request-suggestions question))))

(ert-deftest ecc-protocol-test-local-command-tags ()
  "The tagged fields a local command leaves in a recording are read out."
  (let ((command (concat "<command-name>/advisor</command-name>\n"
                         "            <command-message>advisor</command-message>\n"
                         "            <command-args>on</command-args>"))
        (caveat (concat "<local-command-caveat>Caveat: The messages below were "
                        "generated by the user while running local commands."
                        "</local-command-caveat>"))
        (stdout "<local-command-stdout>Advisor: off\nUsage: /advisor</local-command-stdout>"))
    (should (equal (ecc-protocol-parse-command command)
                   '((name . "/advisor") (message . "advisor") (args . "on"))))
    ;; A command given no argument says so with an empty element.
    (should-not (alist-get 'args (ecc-protocol-parse-command
                                  "<command-name>/exit</command-name>\n<command-args></command-args>")))
    (should-not (ecc-protocol-parse-command "please run /advisor"))
    (should (ecc-protocol-command-caveat-p caveat))
    (should-not (ecc-protocol-command-caveat-p command))
    (should (equal (ecc-protocol-command-output stdout)
                   "Advisor: off\nUsage: /advisor"))
    (should-not (ecc-protocol-command-output command))
    ;; None of the three is a prompt: they are what the CLI wrote about
    ;; a command it ran itself.
    (dolist (text (list command caveat stdout))
      (should-not (ecc-protocol-history-prompt
                   `((type . "user") (message . ((role . "user") (content . ,text)))))))
    (should (equal "hello"
                   (ecc-protocol-history-prompt
                    '((type . "user") (message . ((role . "user") (content . "hello")))))))))

(ert-deftest ecc-protocol-test-value-string-is-text-not-bytes ()
  "A serialized value reads as text: `json-serialize' answers in bytes."
  (let ((value (ecc--json-read "[{\"question\":\"ツール行\"}]")))
    (should (equal (ecc-protocol-value-string value)
                   "[{\"question\":\"ツール行\"}]"))
    (should (multibyte-string-p (ecc-protocol-value-string value))))
  ;; The scalars are passed through as they are.
  (should (equal (ecc-protocol-value-string "ツール行") "ツール行"))
  (should (equal (ecc-protocol-value-string :false) "false")))

(ert-deftest ecc-protocol-test-remote-control ()
  "The remote_control request says its boolean the way the CLI wants it."
  (let ((on (alist-get 'request (ecc-protocol-remote-control "r1" t "session")))
        (off (alist-get 'request (ecc-protocol-remote-control "r2" nil))))
    (should (equal (alist-get 'subtype on) "remote_control"))
    (should (eq (alist-get 'enabled on) t))
    (should (equal (alist-get 'name on) "session"))
    ;; A switch-off carries no name, and false is `:false': nil would
    ;; serialize as an empty object and read as true.
    (should (eq (alist-get 'enabled off) :false))
    (should-not (assq 'name off))
    (should (string-search "\"enabled\":false"
                           (ecc-protocol-serialize
                            (ecc-protocol-remote-control "r2" nil))))
    ;; The bridge is folded up with the session.
    (dolist (request (list on off))
      (should-not (assq 'keep_session_on_exit request))
      (should-not (assq 'work_secret request))
      (should-not (assq 'reattach_session_id request)))))

(ert-deftest ecc-protocol-test-parses-the-agent-list ()
  "The answer of `claude agents --json' is read as recorded.
The dashboard no longer asks for it, but a live test still compares it
against what the registry says."
  (let* ((output (with-temp-buffer
                   (insert-file-contents
                    (expand-file-name "fixtures/agents.json" ecc-test-directory))
                   (buffer-string)))
         (agents (ecc-protocol-parse-agents output)))
    (should (= 4 (length agents)))
    (should (equal "emacs-gravity-a6" (alist-get 'name (car agents))))
    (should (equal "idle" (alist-get 'status (car agents))))
    (should (alist-get 'pid (car agents)))
    ;; A CLI that does not know the subcommand prints something else.
    (should-not (ecc-protocol-parse-agents "unknown command\n"))
    (should-not (ecc-protocol-parse-agents ""))))

(provide 'ecc-protocol-test)

;;; ecc-protocol-test.el ends here
