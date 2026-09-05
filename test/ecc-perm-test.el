;;; ecc-perm-test.el --- Tests for ecc-perm  -*- lexical-binding: t; -*-

;;; Commentary:

;; Answering a can_use_tool request: what goes on the wire, what happens
;; to the queue and what the transcript remembers (FR-PERM-1, 2, 5, 6).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-perm)
(require 'ecc-session)
(require 'ecc-dispatch)

(ert-deftest ecc-perm-test-allow ()
  "Allow echoes the input back unchanged (12.3)."
  (ecc-test-with-fake-session session
    (let ((request (ecc-test-add-request session)))
      (ecc-perm-respond request 'allow)
      (should (equal (ecc-protocol-serialize (car (ecc-test-sent-messages)))
                     (concat "{\"type\":\"control_response\",\"response\":"
                             "{\"subtype\":\"success\",\"request_id\":\"req-1\","
                             "\"response\":{\"behavior\":\"allow\","
                             "\"updatedInput\":{\"file_path\":\"/tmp/a.txt\","
                             "\"content\":\"hi\"}}}}")))
      (should-not (ecc-session-pending session))
      (should (eq (ecc-node-status (ecc-request-node request)) 'done)))))

(ert-deftest ecc-perm-test-deny-with-a-reason ()
  "Deny sends the reason Claude will read (FR-PERM-2, 12.4)."
  (ecc-test-with-fake-session session
    (let ((request (ecc-test-add-request session)))
      (ecc-perm-respond request 'deny :message "内容を hi にして")
      (let ((response (alist-get 'response
                                 (alist-get 'response (car (ecc-test-sent-messages))))))
        (should (equal (alist-get 'behavior response) "deny"))
        (should (equal (alist-get 'message response) "内容を hi にして")))
      (should (eq (ecc-node-status (ecc-request-node request)) 'denied))
      ;; The transcript keeps the reason next to the request.
      (should (equal (ecc-model-node-get (ecc-request-node request) 'outcome-message)
                     "内容を hi にして")))))

(ert-deftest ecc-perm-test-deny-without-a-reason ()
  "An empty reason still says something; the CLI needs a message."
  (ecc-test-with-fake-session session
    (ecc-perm-respond (ecc-test-add-request session) 'deny :message "")
    (let ((response (alist-get 'response
                               (alist-get 'response (car (ecc-test-sent-messages))))))
      (should (equal (alist-get 'message response) ecc-perm-default-deny-message)))))

(ert-deftest ecc-perm-test-allow-with-mode ()
  "An allow can carry a permission mode change (12.5)."
  (ecc-test-with-fake-session session
    (ecc-perm-respond (ecc-test-add-request session) 'allow
                      :updated-permissions
                      (vector (ecc-protocol-set-mode-suggestion "acceptEdits")))
    (let ((response (alist-get 'response
                               (alist-get 'response (car (ecc-test-sent-messages))))))
      (should (equal (alist-get 'mode (aref (alist-get 'updatedPermissions response) 0))
                     "acceptEdits")))))

(ert-deftest ecc-perm-test-commands-find-the-oldest ()
  "With no request at point the oldest waiting one is answered (FR-PERM-6)."
  (ecc-test-with-fake-session session
    (let ((first (ecc-test-add-request session))
          (second (ecc-test-add-request session "Bash")))
      (ecc-perm-deny "no")
      (should (equal (ecc-session-pending session) (list second)))
      (should (eq (ecc-node-status (ecc-request-node first)) 'denied))
      (ecc-perm-allow)
      (should-not (ecc-session-pending session)))))

(ert-deftest ecc-perm-test-request-at-point ()
  "In a session buffer the request under the point wins."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let ((first (ecc-test-add-request session))
          (second (ecc-test-add-request session "Bash")))
      (ecc-render-flush session)
      (with-current-buffer (ecc-session-buffer session)
        (goto-char (point-max))
        (search-backward "Permission: Bash")
        (should (eq (ecc-perm-request-at-point) second))
        (ecc-perm-allow)
        (should (equal (ecc-session-pending session) (list first)))))))

(ert-deftest ecc-perm-test-question-options ()
  "The labels offered for a question are the ones the CLI sent."
  (let* ((request (ecc-test-find-message
                   "ask-user-question"
                   (lambda (m) (eq (ecc-protocol-control-subtype m) 'can_use_tool))))
         (questions (alist-get 'questions (ecc-protocol-request-input request))))
    (should (equal (ecc-perm-question-options (aref questions 0))
                   '("Emacs" "Vim")))
    ;; multiSelect stays false rather than turning into null (9.5).
    (should (eq (alist-get 'multiSelect (aref questions 0)) :false))))

;;;; Allow patterns (FR-PERM-8)

(ert-deftest ecc-perm-test-suggest-patterns-bash ()
  "Bash patterns go from the two word prefix to the command itself."
  (should (equal (ecc-perm-suggest-patterns "Bash" '((command . "git status --short | head")))
                 '("Bash(git status *)" "Bash(git *)")))
  (should (equal (ecc-perm-suggest-patterns "Bash" '((command . "npm test")))
                 '("Bash(npm test *)" "Bash(npm *)" "Bash(npm test)")))
  ;; An option is not a sub command.
  (should (equal (ecc-perm-suggest-patterns "Bash" '((command . "ls -la")))
                 '("Bash(ls *)" "Bash(ls -la)")))
  ;; A pipeline or a list only counts its first command.
  (should (equal (ecc-perm-suggest-patterns "Bash" '((command . "cd /tmp && rm -rf x")))
                 '("Bash(cd /tmp *)" "Bash(cd *)"))))

(ert-deftest ecc-perm-test-suggest-patterns-files ()
  "File patterns are relative to the project, else absolute with //."
  (should (equal (ecc-perm-suggest-patterns "Edit" '((file_path . "/proj/src/a.py")) "/proj")
                 '("Edit(src/a.py)" "Edit(src/**)" "Edit(**/*.py)")))
  (should (equal (ecc-perm-suggest-patterns "Write" '((file_path . "/proj/README")) "/proj/")
                 '("Write(README)")))
  (should (equal (ecc-perm-suggest-patterns "Read" '((file_path . "/other/x.py")) "/proj")
                 '("Read(//other/x.py)" "Read(//other/**)" "Read(**/*.py)"))))

(ert-deftest ecc-perm-test-suggest-patterns-other-tools ()
  "MCP tools offer the tool then its server; anything else its bare name."
  (should (equal (ecc-perm-suggest-patterns "mcp__github__list_issues" nil)
                 '("mcp__github__list_issues" "mcp__github")))
  (should (equal (ecc-perm-suggest-patterns "WebFetch" '((url . "https://example.com/a/b")))
                 '("WebFetch(domain:example.com)")))
  (should (equal (ecc-perm-suggest-patterns "Glob" '((pattern . "*.el"))) '("Glob"))))

(ert-deftest ecc-perm-test-add-pattern-writes-settings-and-allows ()
  "The chosen pattern lands in settings.local.json and the request is allowed."
  (ecc-test-with-fake-session session
    (let* ((root (make-temp-file "ecc-perm" t))
           (file (expand-file-name ".claude/settings.local.json" root))
           (asked nil))
      (unwind-protect
          (progn
            (setf (ecc-session-project-root session) (file-name-as-directory root))
            (let ((request (ecc-test-add-request session "Bash")))
              (setf (ecc-request-input request) '((command . "git status")))
              (cl-letf (((symbol-function 'completing-read-multiple)
                         (lambda (_prompt candidates &rest _)
                           ;; The most specific candidate comes first.
                           (should (equal (car candidates) "Bash(git status *)"))
                           (list "Bash(git status *)" "Bash(git *)")))
                        ((symbol-function 'y-or-n-p)
                         (lambda (prompt) (push prompt asked) t)))
                (ecc-perm-add-pattern))
              (should (file-exists-p file))
              (should (equal (ecc-protocol-settings-allow-list
                              (ecc-protocol-read-settings-file file))
                             '("Bash(git status *)" "Bash(git *)")))
              ;; The file and the patterns were named before writing.
              (should (seq-find (lambda (p) (and (string-search "settings.local.json" p)
                                                 (string-search "Bash(git status *)" p)))
                                asked))
              ;; ... and the request itself was allowed on request.
              (should-not (ecc-session-pending session))
              (should (equal (alist-get 'behavior (ecc-test-response 0)) "allow"))))
        (delete-directory root t)))))

(ert-deftest ecc-perm-test-add-pattern-refused-writes-nothing ()
  "Saying no at the confirmation leaves the file and the request alone."
  (ecc-test-with-fake-session session
    (let ((root (make-temp-file "ecc-perm" t)))
      (unwind-protect
          (progn
            (setf (ecc-session-project-root session) (file-name-as-directory root))
            (let ((request (ecc-test-add-request session "Bash")))
              (setf (ecc-request-input request) '((command . "git push")))
              (cl-letf (((symbol-function 'completing-read-multiple)
                         (lambda (&rest _) (list "Bash(git push *)")))
                        ((symbol-function 'y-or-n-p) (lambda (_) nil)))
                (should-error (ecc-perm-add-pattern) :type 'user-error))
              (should-not (file-exists-p (expand-file-name ".claude/settings.local.json" root)))
              (should (ecc-session-pending session))))
        (delete-directory root t)))))

;;;; Permission suggestions (FR-PERM-3)

(ert-deftest ecc-perm-test-allow-always-sends-the-suggestion ()
  "A single suggestion goes back verbatim as updatedPermissions."
  (ecc-test-with-fake-session session
    (let ((request (ecc-test-feed-until-request session "edit-tool" "直して")))
      (should (ecc-request-suggestions request))
      (ecc-perm-allow-always)
      (should-not (ecc-session-pending session))
      (let ((response (ecc-test-response 0)))
        (should (equal (alist-get 'behavior response) "allow"))
        (should (equal (ecc-protocol-serialize (alist-get 'updatedPermissions response))
                       "[{\"type\":\"setMode\",\"mode\":\"acceptEdits\",\"destination\":\"session\"}]")))
      ;; The transcript says what was chosen.
      (should (string-search "acceptEdits"
                             (ecc-model-node-get (ecc-request-node request)
                                                 'outcome-message))))))

(ert-deftest ecc-perm-test-allow-always-without-suggestion-saves-a-pattern ()
  "Without a suggestion, `A' falls through to the pattern flow (FR-PERM-8)."
  (ecc-test-with-fake-session session
    (let ((root (make-temp-file "ecc-perm" t)))
      (unwind-protect
          (progn
            (setf (ecc-session-project-root session) (file-name-as-directory root))
            (ecc-test-add-request session "Write")
            (cl-letf (((symbol-function 'completing-read-multiple)
                       (lambda (_prompt candidates &rest _) (list (car candidates))))
                      ((symbol-function 'y-or-n-p) (lambda (_) t)))
              (ecc-perm-allow-always))
            (should (equal (ecc-protocol-settings-allow-list
                            (ecc-protocol-read-settings-file
                             (expand-file-name ".claude/settings.local.json" root)))
                           '("Write(//tmp/a.txt)")))
            (should-not (ecc-session-pending session)))
        (delete-directory root t)))))

(ert-deftest ecc-perm-test-suggestion-labels ()
  "Suggestions are described in words."
  (should (string-search "acceptEdits"
                         (ecc-perm-suggestion-label
                          '((type . "setMode") (mode . "acceptEdits") (destination . "session")))))
  (should (string-search "Bash(git push *)"
                         (ecc-perm-suggestion-label
                          '((type . "addRules")
                            (rules . [((toolName . "Bash") (ruleContent . "git push *"))]))))))

;;;; Turn wide approval (FR-PERM-7)

(ert-deftest ecc-perm-test-approve-turn ()
  "`t' allows the waiting Edit, leaves Bash, and covers the rest of the turn."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "直して")
    (let ((edit (ecc-test-add-request session "Edit"))
          (bash (ecc-test-add-request session "Bash")))
      (should (= 1 (ecc-perm-approve-turn)))
      (should (equal (ecc-session-pending session) (list bash)))
      (should (eq (ecc-node-status (ecc-request-node edit)) 'done))
      (should (ecc-session-auto-approve-turn session))
      ;; A Write arriving now is allowed without queueing (dispatch).
      (ecc-dispatch session (ecc-protocol-parse-line
                             "{\"type\":\"control_request\",\"request_id\":\"req-3\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Write\",\"input\":{\"file_path\":\"/tmp/b.txt\",\"content\":\"x\"},\"tool_use_id\":\"toolu_3\"}}"))
      (should (equal (ecc-session-pending session) (list bash)))
      (should (= 2 (length (ecc-test-sent-messages))))
      ;; The result clears the flag.
      (ecc-dispatch session '((type . "result") (subtype . "success") (total_cost_usd . 0)))
      (should-not (ecc-session-auto-approve-turn session)))))

(ert-deftest ecc-perm-test-approve-turn-includes-the-request-at-point ()
  "The request `t' is pressed on is allowed even when its tool is not listed."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "実行して")
    (let ((bash (ecc-test-add-request session "Bash")))
      (ecc-render-flush session)
      (with-current-buffer (ecc-session-buffer session)
        (goto-char (point-max))
        (search-backward "Permission: Bash")
        (should (eq (ecc-perm-request-at-point) bash))
        (ecc-perm-approve-turn))
      (should-not (ecc-session-pending session)))))

;;;; Bulk operations (FR-PERM-9)

(ert-deftest ecc-perm-test-allow-all ()
  "Allow all answers every permission and leaves questions where they are."
  (ecc-test-with-fake-session session
    (let ((write (ecc-test-add-request session "Write"))
          (bash (ecc-test-add-request session "Bash"))
          (question (ecc-test-add-request session "AskUserQuestion")))
      (should (equal (ecc-perm-allow-all) (list write bash)))
      (should (equal (ecc-session-pending session) (list question)))
      (should-not (ecc-session-auto-approve-kinds session)))))

(ert-deftest ecc-perm-test-allow-all-remember ()
  "Allow all with remember stops asking about those tools in this session."
  (ecc-test-with-fake-session session
    (ecc-test-add-request session "Write")
    (ecc-test-add-request session "Bash")
    (ecc-perm-allow-all t)
    (should-not (ecc-session-pending session))
    (should (equal (sort (copy-sequence (ecc-session-auto-approve-kinds session)) #'string<)
                   '("Bash" "Write")))
    (should (ecc-dispatch-auto-approve-p
             session (make-ecc-request :kind 'permission :tool-name "Bash")))))

(ert-deftest ecc-perm-test-next-commands ()
  "Allow next and deny next act on the oldest request of the session."
  (ecc-test-with-fake-session session
    (let ((first (ecc-test-add-request session "Write"))
          (second (ecc-test-add-request session "Bash")))
      (ecc-perm-deny-next "later")
      (should (equal (ecc-session-pending session) (list second)))
      (should (eq (ecc-node-status (ecc-request-node first)) 'denied))
      (ecc-perm-allow-next)
      (should-not (ecc-session-pending session)))))

;;;; Unsaved buffers (FR-SYNC-2)

(defmacro ecc-perm-test--with-modified-file (file buffer &rest body)
  "Run BODY with FILE a temp file visited by BUFFER that has unsaved changes."
  (declare (indent 2))
  `(let* ((,file (make-temp-file "ecc-sync" nil ".txt" "one\ntwo\n"))
          (,buffer (find-file-noselect ,file)))
     (unwind-protect
         (progn
           (with-current-buffer ,buffer
             (goto-char (point-max))
             (insert "three\n"))
           (should (buffer-modified-p ,buffer))
           ,@body)
       (with-current-buffer ,buffer (set-buffer-modified-p nil))
       (kill-buffer ,buffer)
       (delete-file ,file))))

(ert-deftest ecc-perm-test-unsaved-deny ()
  "Choosing deny at the warning refuses the change and tells Claude why."
  (ecc-test-with-fake-session session
    (ecc-perm-test--with-modified-file file buffer
      (let ((request (ecc-test-add-request session "Edit")))
        (setf (ecc-request-input request)
              `((file_path . ,file) (old_string . "one") (new_string . "1")))
        (cl-letf (((symbol-function 'read-multiple-choice)
                   (lambda (&rest _) '(?d "deny"))))
          (should (eq (ecc-perm-allow-request request) 'deny)))
        (should (equal (alist-get 'behavior (ecc-test-response 0)) "deny"))
        (should (equal (alist-get 'message (ecc-test-response 0))
                       ecc-perm-unsaved-deny-message))
        (should (buffer-modified-p buffer))))))

(ert-deftest ecc-perm-test-unsaved-save-then-allow ()
  "Choosing save writes the buffer first, then allows."
  (ecc-test-with-fake-session session
    (ecc-perm-test--with-modified-file file buffer
      (let ((request (ecc-test-add-request session "Write")))
        (setf (ecc-request-input request) `((file_path . ,file) (content . "new")))
        (cl-letf (((symbol-function 'read-multiple-choice)
                   (lambda (&rest _) '(?s "save and allow"))))
          (should (eq (ecc-perm-allow-request request) 'save)))
        (should-not (buffer-modified-p buffer))
        (should (string-search "three" (with-temp-buffer (insert-file-contents file)
                                                         (buffer-string))))
        (should (equal (alist-get 'behavior (ecc-test-response 0)) "allow"))))))

(ert-deftest ecc-perm-test-unsaved-check-only-for-file-tools ()
  "A Bash request never asks about buffers, whatever is unsaved."
  (ecc-test-with-fake-session session
    (ecc-perm-test--with-modified-file file _buffer
      (let ((request (ecc-test-add-request session "Bash")))
        (setf (ecc-request-input request) `((command . ,(concat "cat " file))))
        (cl-letf (((symbol-function 'read-multiple-choice)
                   (lambda (&rest _) (error "Should not ask"))))
          (should (eq (ecc-perm-allow-request request) 'allow)))))))

;;;; The question buffer (FR-PERM-5)

(defun ecc-perm-test--question-request (session)
  "Return the AskUserQuestion request of the recording, fed to SESSION."
  (ecc-test-feed-until-request session "ask-user-question" "質問して"))

(ert-deftest ecc-perm-test-question-buffer-answers ()
  "Number keys choose, multiSelect toggles, and the answers match verified.md."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-perm-test--question-request session))
           (buffer (ecc-question-open request)))
      (with-current-buffer buffer
        (should (derived-mode-p 'ecc-question-mode))
        (should (string-search "Which editor do you prefer?" (buffer-string)))
        ;; Point starts on the first question; choosing moves it to the next.
        (should (= 0 (ecc-question--index-at-point)))
        (ecc-question-choose 1)
        (should (= 1 (ecc-question--index-at-point)))
        (ecc-question-choose 1)
        (ecc-question-choose 2)
        ;; A multiSelect question stays put and shows both marks.
        (should (= 1 (ecc-question--index-at-point)))
        (should (string-search "1. [x] Elisp" (buffer-string)))
        (should (string-search "2. [x] Python" (buffer-string)))
        (should (string-search "1. (•) Emacs" (buffer-string)))
        ;; Toggling takes an answer away again, and back.
        (ecc-question-choose 2)
        (should (string-search "2. [ ] Python" (buffer-string)))
        (ecc-question-choose 2)
        (ecc-question-submit))
      (should-not (buffer-live-p buffer))
      (should-not (ecc-session-pending session))
      (let* ((response (ecc-test-response 0))
             (updated (alist-get 'updatedInput response)))
        (should (equal (alist-get 'behavior response) "allow"))
        (should (equal (ecc-protocol-serialize (alist-get 'answers updated))
                       "{\"Which editor do you prefer?\":\"Emacs\",\"Which languages do you use?\":\"Elisp, Python\"}"))
        (should (equal (alist-get 'questions updated)
                       (alist-get 'questions (ecc-request-input request)))))
      ;; The transcript keeps the answers next to the question.
      (should (equal (ecc-model-node-get (ecc-request-node request) 'outcome-message)
                     "answered: Emacs · Elisp, Python")))))

(ert-deftest ecc-perm-test-question-buffer-other-and-clear ()
  "Other adds a free text; clear forgets; submit refuses an unanswered question."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-perm-test--question-request session))
           (buffer (ecc-question-open request)))
      (with-current-buffer buffer
        (should-error (ecc-question-submit) :type 'user-error)
        (ecc-question-other "Neovim")
        (should (string-search "その他: Neovim" (buffer-string)))
        (ecc-question-next)
        (ecc-question-choose 3)
        (ecc-question-other "Zig")
        (should (string-search "[x] その他: Zig" (buffer-string)))
        (should (equal (ecc-question-answers)
                       '(("Which editor do you prefer?" . "Neovim")
                         ("Which languages do you use?" . "Rust, Zig"))))
        (ecc-question-clear)
        (should-error (ecc-question-answers) :type 'user-error)
        (ecc-question-choose 4)
        (ecc-question-submit))
      (should (equal (cdr (assq 'Which\ languages\ do\ you\ use\?
                                (alist-get 'answers
                                           (alist-get 'updatedInput
                                                      (ecc-test-response 0)))))
                     "Go")))))

(ert-deftest ecc-perm-test-question-toggle-at-point ()
  "SPC on an option line chooses it for the question the line belongs to."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-perm-test--question-request session))
           (buffer (ecc-question-open request)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "2. ( ) Vim")
        (ecc-question-toggle-at-point)
        (should (equal (aref ecc-question--answers 0) '("Vim")))
        (goto-char (point-min))
        (should-error (ecc-question-toggle-at-point) :type 'user-error)))))

(ert-deftest ecc-perm-test-question-cancel-denies ()
  "C-c C-k refuses the question with a reason."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-perm-test--question-request session))
           (buffer (ecc-question-open request)))
      (with-current-buffer buffer
        (ecc-question-cancel "not now"))
      (should-not (buffer-live-p buffer))
      (should (eq (ecc-node-status (ecc-request-node request)) 'denied))
      (should (equal (alist-get 'message (ecc-test-response 0)) "not now")))))

(ert-deftest ecc-perm-test-question-buffer-closes-when-answered-elsewhere ()
  "A question answered from another place takes its buffer away."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-perm-test--question-request session))
           (buffer (ecc-question-open request)))
      (should (eq (ecc-question-buffer request) buffer))
      (ecc-perm-respond request 'deny :message "elsewhere")
      (should-not (buffer-live-p buffer)))))

(ert-deftest ecc-perm-test-allow-on-a-question-opens-the-buffer ()
  "`a' on a question does not guess; it opens the buffer instead."
  (ecc-test-with-fake-session session
    (let ((request (ecc-perm-test--question-request session)))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
        (should (eq (ecc-perm-allow-request request) 'opened)))
      (should (ecc-question-buffer request))
      (should (ecc-session-pending session))
      (should-not (ecc-test-sent-messages)))))

(provide 'ecc-perm-test)

;;; ecc-perm-test.el ends here
