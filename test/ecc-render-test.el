;;; ecc-render-test.el --- Tests for ecc-render  -*- lexical-binding: t; -*-

;;; Commentary:

;; Replays a recording into a session buffer and compares the text of the
;; buffer with a snapshot in test/snapshots (plan section 8).  Rewrite a
;; snapshot after an intended change with:
;;
;;     ECC_UPDATE_SNAPSHOTS=1 make test

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-render)
(require 'ecc-session)
(require 'ecc-perm)
(require 'ecc-dispatch)

(defun ecc-render-test--replay (session name prompt &optional answers)
  "Replay fixture NAME into SESSION under PROMPT and draw it.
ANSWERS is a list of `allow' or `(deny . REASON)', used in turn for the
requests the recording makes."
  (ecc-session-ensure-buffer session)
  (ecc-model-begin-turn session prompt)
  (dolist (line (ecc-test-fixture-lines name))
    (let ((message (ecc-protocol-parse-line line)))
      (ecc-dispatch session message)
      (when (and answers (eq (ecc-protocol-control-subtype message) 'can_use_tool))
        (let ((request (car (ecc-session-pending session)))
              (answer (pop answers)))
          (if (eq answer 'allow)
              (ecc-perm-respond request 'allow)
            (ecc-perm-respond request 'deny :message (cdr answer)))))))
  (ecc-render-flush session)
  (ecc-test-buffer-string (ecc-session-buffer session)))

(defun ecc-render-test--check (name text)
  "Fail unless TEXT matches snapshot NAME, saying where to look."
  (unless (ecc-test-snapshot name text)
    (ert-fail (format "%s differs from its snapshot; see %s.new"
                      name (ecc-test-snapshot-file name)))))

;;;; Snapshots

(ert-deftest ecc-render-test-basic-turn ()
  "A plain question and answer draw as one turn with a result line."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "basic-turn" "hello")))
      (ecc-render-test--check "basic-turn" text)
      ;; The header carries what the CLI told us about the session.
      (should (string-prefix-p "test  ·  claude-haiku-4-5-20251001  ·  default  ·  idle"
                               text))
      ;; The prompt is quoted with a margin marker (plan 5.3).
      (should (string-search "\n▌ hello\n" text)))))

(ert-deftest ecc-render-test-tool-use ()
  "A tool call draws as a step, a tool and the permission that allowed it."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "tool-use-write"
                                         "hello.txt を作って" '(allow))))
      (ecc-render-test--check "tool-use-write" text)
      (should (string-search "Write ×1" text))
      (should (string-search "✓ Permission: Write" text)))))

(ert-deftest ecc-render-test-deny-then-allow ()
  "A denied request keeps its reason next to the retry that followed."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "permission-deny-retry"
                                         "hello.txt を作って"
                                         '((deny . "内容を hi にして") allow))))
      (ecc-render-test--check "permission-deny-retry" text)
      (should (string-search "✗ Permission: Write  denied: 内容を hi にして" text))
      (should (string-search "✓ Permission: Write" text)))))

;;;; Incremental drawing (NFR-9, plan section 5.2)

(ert-deftest ecc-render-test-finished-turns-are-left-alone ()
  "Once a turn is finished it is never drawn again."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-test-dispatch session "basic-turn" "hello")
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (should (= ecc-render--frozen 1))
      (let* ((section (ecc-render--turn-section "turn-1"))
             (text (buffer-substring-no-properties (oref section start)
                                                   (oref section end))))
        (should section)
        ;; A second turn arrives; the first one keeps its very object and
        ;; its text, so nothing above the live region was redrawn.
        (ecc-model-begin-turn session "again")
        (ecc-render-flush session)
        (should (eq section (ecc-render--turn-section "turn-1")))
        (should (= ecc-render--frozen 1))
        (should (equal text (buffer-substring-no-properties (oref section start)
                                                            (oref section end))))
        (should (string-search "Turn 2  again" (buffer-string)))))))

(ert-deftest ecc-render-test-folding-survives-a-redraw ()
  "Collapsing a section sticks, because node ids are stable (plan 9.6)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "hello.txt を作って")
    (dolist (line (ecc-test-fixture-lines "tool-use-write"))
      (ecc-dispatch session (ecc-protocol-parse-line line)))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (let* ((id "toolu_01Hcu5xtMTxBqGiZ6MfT3XyZ")
             (section (ecc-render-test--find-section id)))
        (should section)
        ;; Tool bodies start collapsed (FR-OUT-3).
        (should (oref section hidden))
        (magit-section-show section)
        (should-not (oref section hidden))
        (ecc-render-flush session)
        (should-not (oref (ecc-render-test--find-section id) hidden))))))

(defun ecc-render-test--find-section (value)
  "Return the section whose value is VALUE, searching the whole buffer."
  (let (found)
    (magit-map-sections
     (lambda (section)
       (when (equal (oref section value) value)
         (setq found section))))
    found))

(ert-deftest ecc-render-test-refresh-rebuilds-the-same-text ()
  "Drawing everything again gives exactly what growing it gave (FR-OUT-10)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-test-dispatch session "tool-use-write" "hello.txt を作って")
    (ecc-render-flush session)
    (let ((incremental (ecc-test-buffer-string (ecc-session-buffer session))))
      (ecc-render-refresh session)
      (should (equal incremental
                     (ecc-test-buffer-string (ecc-session-buffer session)))))))

(ert-deftest ecc-render-test-unknown-is-visible ()
  "A message the client does not understand still reaches the buffer."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-dispatch session '((type . "brand_new_thing") (detail . "hello")))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "unknown: brand_new_thing" text))
      (should (string-search "hello" text)))))

;;;; Cost of drawing (NFR-1)

(ert-deftest ecc-render-test-streaming-recording-is-fast ()
  "Replaying the streaming recording with a redraw per message stays quick."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "長いファイルを書いて")
    (let* ((lines (ecc-test-fixture-lines "partial-messages"))
           (elapsed
            (car (benchmark-run 1
                   (dolist (line lines)
                     (ecc-dispatch session (ecc-protocol-parse-line line))
                     (ecc-render-flush session))))))
      ;; The threshold is loose on purpose; it catches a redraw that grew
      ;; with the length of the conversation, not a slow machine.
      (should (< elapsed 10)))))


;;;; Streaming (FR-OUT-4, FR-OUT-10)

(defun ecc-render-test--stream (session name prompt stop-at)
  "Replay fixture NAME into SESSION under PROMPT until STOP-AT returns non-nil.
STOP-AT is called with each parsed message after it was dispatched.
Every content_block_start is drawn at once so that the deltas that
follow have a section to grow.  Returns the remaining lines."
  (ecc-session-ensure-buffer session)
  (ecc-model-begin-turn session prompt)
  (let ((lines (ecc-test-fixture-lines name))
        (done nil))
    (while (and lines (not done))
      (let ((message (ecc-protocol-parse-line (pop lines))))
        (ecc-dispatch session message)
        (when (equal (alist-get 'type (alist-get 'event message)) "content_block_start")
          (ecc-render-flush session))
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          (ecc-perm-respond (car (ecc-session-pending session)) 'allow))
        (setq done (funcall stop-at message))))
    lines))

(defun ecc-render-test--delta-p (message type)
  "Return non-nil when MESSAGE is a content_block_delta of TYPE."
  (let ((event (alist-get 'event message)))
    (and (equal (alist-get 'type event) "content_block_delta")
         (equal (alist-get 'type (alist-get 'delta event)) type))))

(ert-deftest ecc-render-test-text-grows-delta-by-delta ()
  "Each text delta lands in the buffer without a redraw (FR-OUT-4)."
  (ecc-test-with-fake-session session
    (let* ((ecc-stream-throttle 0)
           (seen 0)
           (lines (ecc-render-test--stream
                   session "partial-messages" "長いファイルを書いて"
                   (lambda (message)
                     (when (ecc-render-test--delta-p message "text_delta")
                       (cl-incf seen))
                     (= seen 3))))
           (buffer (ecc-session-buffer session)))
      ;; "Done" "." " Created" arrived; nothing else was redrawn.
      (should (string-search "\n  Done. Created\n" (ecc-test-buffer-string buffer)))
      (let ((node (ecc-model-find-stream session nil 'text)))
        (should node)
        (should (equal (ecc-node-streaming-text node) "Done. Created"))
        ;; The header line says what is streaming (FR-OUT-6).
        (should (string-search "text" (ecc-render-status-line session))))
      ;; Feed the rest: the complete message replaces the streamed text
      ;; with the formatted one, and it is there exactly once.
      (dolist (line lines)
        (ecc-dispatch session (ecc-protocol-parse-line line)))
      (ecc-render-flush session)
      (let ((text (ecc-test-buffer-string buffer)))
        (should (= 1 (cl-count-if (lambda (line) (string-prefix-p "  Done. Created" line))
                                  (split-string text "\n"))))
        (should (string-search "  Done. Created `long.py` with 60 functions" text))
        (should (string-search "● end_turn" text))
        (should-not (ecc-model-find-stream session nil 'text)))
      ;; A code span inside the reply got its Markdown face (FR-OUT-8).
      (with-current-buffer buffer
        (goto-char (point-min))
        (should (search-forward "`long.py`" nil t))
        (should (memq 'ecc-markdown-code-face
                      (ensure-list (get-text-property (match-beginning 0) 'face))))))))

(ert-deftest ecc-render-test-tool-input-streams-into-heading ()
  "While a Write streams its input only the heading changes (FR-OUT-10)."
  (ecc-test-with-fake-session session
    (let* ((ecc-stream-throttle 0)
           (seen 0))
      (ecc-render-test--stream
       session "partial-messages" "長いファイルを書いて"
       (lambda (message)
         (when (ecc-render-test--delta-p message "input_json_delta")
           (cl-incf seen))
         (= seen 5)))
      (let ((text (ecc-test-buffer-string (ecc-session-buffer session)))
            (node (ecc-model-node session "toolu_01QcvmkL7eVaiQDvpEut8Pak")))
        (should (ecc-node-streaming node))
        (should (string-match-p "… Write  streaming [0-9]+ chars…" text))
        (should (string-search "Write" (ecc-render-status-line session)))))))

(ert-deftest ecc-render-test-throttle-by-count ()
  "Counting deltas draws every Nth one and nothing in between."
  (ecc-test-with-fake-session session
    (let ((ecc-stream-throttle-method 'count)
          (ecc-stream-throttle-count 2)
          (seen 0))
      (ecc-render-test--stream
       session "partial-messages" "長いファイルを書いて"
       (lambda (message)
         (when (ecc-render-test--delta-p message "text_delta")
           (cl-incf seen))
         (= seen 3)))
      ;; Two deltas were drawn, the third waits.
      (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
        (should (string-search "\n  Done.\n" text)))
      (ecc-render-flush-deltas session)
      (should (string-search "\n  Done. Created\n"
                             (ecc-test-buffer-string (ecc-session-buffer session)))))))

(ert-deftest ecc-render-test-streamed-tree-matches-unstreamed ()
  "The stream events add nothing to the tree the assistant messages build."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "partial-messages" "長いファイルを書いて")
    (should (equal (ecc-test-turn-shape (car (ecc-session-turns session)))
                   '(thinking (step tool) permission thinking text result)))
    (should (= 0 (hash-table-count (ecc-session-stream-blocks session))))))

;;;; Subagents (FR-OUT-9)

(ert-deftest ecc-render-test-subagent ()
  "An agent draws nested, with its prompt, tools and reply (FR-OUT-9)."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "subagent" "探して")))
      (ecc-render-test--check "subagent" text)
      (should (string-search "✓ Agent Explore  Find all .py files in current directory  ·  1 tools  ·  5.1s"
                             text))
      (should (string-search "      ▌ List all .py files" text))
      (should (string-search "        ✓ Bash  find . -name" text))
      (let ((agent (seq-find (lambda (node) (eq (ecc-node-type node) 'agent))
                             (hash-table-values (ecc-session-nodes session)))))
        (should (= 5 (length (ecc-node-children agent))))
        ;; The transcript of the agent opens in its own buffer.
        (save-window-excursion
          (with-current-buffer (ecc-session-buffer session)
            (ecc-session-show-agent session agent))
          (let ((buffer (seq-find (lambda (b) (string-prefix-p "*ecc-agent: test"
                                                               (buffer-name b)))
                                  (buffer-list))))
            (should buffer)
            (unwind-protect
                (let ((text (ecc-test-buffer-string buffer)))
                  (should (string-prefix-p "✓ Agent Explore" text))
                  (should (string-search "Bash  find . -name" text))
                  (should (string-search "▌ List all .py files" text)))
              (kill-buffer buffer))))))))

;;;; Diffs (FR-OUT-7, FR-DIFF-1)

(ert-deftest ecc-render-test-edit-diff ()
  "An Edit is drawn as a diff with the lines of the file around it."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "edit-tool" "greet を直して" '(allow))))
      (ecc-render-test--check "edit-tool" text)
      ;; The permission section showed the change in place, with context
      ;; taken from the Read that came before (FR-DIFF-1).
      (should (string-search (concat "  ✓ Permission: Edit  allowed\n"
                                     "    /private/tmp/claude-501/")
                             text))
      (should (string-search (concat "    @@ -1,6 +1,6 @@\n"
                                     "     def greet(name):\n"
                                     "         \"\"\"Say hi.\"\"\"\n"
                                     "    -    return \"hi \" + name\n"
                                     "    +    return \"hello \" + name\n")
                             text))
      ;; The tool section shows the same diff (FR-OUT-7) ...
      (should (string-search "      -    return \"hi \" + name\n      +    return \"hello \" + name\n"
                             text))
      ;; ... with diff-mode faces.
      (with-current-buffer (ecc-session-buffer session)
        (goto-char (point-min))
        (should (search-forward "+    return \"hello \" + name" nil t))
        (should (memq 'diff-added
                      (ensure-list (get-text-property (match-beginning 0) 'face)))))
      ;; The Files section merges the patches the CLI reported (FR-OUT-12).
      (should (string-search "Files (1)\n  /private/tmp/claude-501/" text))
      (should (string-search "hello.py  R×1 E×1  +1 −1\n    @@ -1,6 +1,6 @@\n" text)))))

(ert-deftest ecc-render-test-write-diff-is-clipped ()
  "A long Write shows the head of its diff and says how much was cut."
  (ecc-test-with-fake-session session
    (let* ((ecc-render-diff-max-lines 5)
           (text (ecc-render-test--replay session "partial-messages"
                                         "長いファイルを書いて" '(allow))))
      (should (string-search "      @@ -0,0 +1,298 @@\n      +def f0():\n" text))
      (should (string-search "… 294 more lines (RET)" text))
      ;; The Files section keeps the whole diff behind its fold.
      (should (string-search "long.py  W×1  +298 −0\n" text))
      (should (string-search "    +    return 59\n" text)))))

;;;; Files and Tasks (FR-OUT-12, FR-OUT-13)

(ert-deftest ecc-render-test-tasks ()
  "TaskCreate, TaskUpdate and TaskList keep the checklist current."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "tasks" "タスクを作って")))
      (ecc-render-test--check "tasks" text)
      (should (string-search "Tasks (1/2)\n  [x] Write tests\n  [ ] Update docs\n" text)))))

(ert-deftest ecc-render-test-tasks-follow-each-update ()
  "The checklist changes as soon as a task changes, not only at the end."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "タスクを作って")
    (let ((states nil))
      (dolist (line (ecc-test-fixture-lines "tasks"))
        (let ((message (ecc-protocol-parse-line line)))
          (ecc-dispatch session message)
          (when (and (eq (ecc-protocol-type message) 'user)
                     (alist-get 'tool_use_result message))
            (ecc-render-flush session)
            (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
              (when (string-match "Tasks ([0-9]/[0-9])" text)
                (push (match-string 0 text) states))))))
      (should (equal (seq-uniq (nreverse states))
                     '("Tasks (0/1)" "Tasks (0/2)" "Tasks (1/2)"))))))

(ert-deftest ecc-render-test-files-section-folds-and-visits ()
  "A file row starts folded, toggles with SPC and opens the file with RET."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "edit-tool" "greet を直して" '(allow))
    (with-current-buffer (ecc-session-buffer session)
      (let* ((path (ecc-file-entry-path (car (ecc-model-files session))))
             (section (ecc-render-test--find-section (concat "file:" path))))
        (should section)
        (should (oref section hidden))
        (should (oref (ecc-render-test--find-section "files") hidden))
        (magit-section-goto section)
        (should (equal (ecc-session-file-at-point) path))
        (should (eq (lookup-key ecc-file-section-map (kbd "SPC")) 'magit-section-toggle))
        (magit-section-toggle section)
        (should-not (oref section hidden))
        ;; RET opens the file (which need not exist for the call to be made).
        (let (opened)
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (file) (setq opened file))))
            (ecc-session-visit))
          (should (equal opened path)))))))

;;;; The state line (FR-OUT-6)

(ert-deftest ecc-render-test-status-line ()
  "The header line follows the state and names what is running."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (should (string-prefix-p "○ starting" (ecc-render-status-line session)))
    (ecc-model-begin-turn session "hello")
    (should (string-prefix-p "● running" (ecc-render-status-line session)))
    (ecc-dispatch session '((type . "system") (subtype . "thinking_tokens")
                            (estimated_tokens . 1200)))
    (should (string-search "thinking 1.2k tokens" (ecc-render-status-line session)))
    (let ((node (ecc-model-add-node session :id "t1" :type 'tool :status 'running
                                    :parent (ecc-model-step-for-tool
                                             session (ecc-session-current-turn session))
                                    :data '((name . "Bash") (input . ((command . "git status")))
                                            (started . (0 1))))))
      (should (string-search "Bash git status" (ecc-render-status-line session)))
      (setf (ecc-node-status node) 'done))
    (ecc-model-add-request session (make-ecc-request
                                    :request-id "r" :session session :kind 'permission
                                    :tool-name "Write" :input '((file_path . "/tmp/x"))
                                    :created-at (current-time)))
    (should (string-prefix-p "⚠ permission: Write" (ecc-render-status-line session)))
    (with-current-buffer (ecc-session-buffer session)
      (should (string-prefix-p " ⚠ permission" (ecc-render-header-line))))))

;;;; Movement and extraction (FR-OUT-14)

(defun ecc-render-test--two-turns (session)
  "Give SESSION two finished turns, the second holding a code block."
  (ecc-session-ensure-buffer session)
  (ecc-test-dispatch session "basic-turn" "hello")
  (ecc-model-begin-turn session "show me code")
  (ecc-dispatch session
                '((type . "assistant") (uuid . "u2")
                  (message . ((role . "assistant")
                              (content . [((type . "text")
                                           (text . "Here:\n\n```elisp\n(+ 1 2)\n```\n\nDone."))])))))
  (ecc-dispatch session '((type . "result") (subtype . "success") (stop_reason . "end_turn")
                          (total_cost_usd . 0.01) (duration_ms . 100) (num_turns . 1)))
  (ecc-render-flush session))

(ert-deftest ecc-render-test-turn-movement-and-timeline ()
  "Turns can be walked and picked by their prompt (FR-OUT-14 a, d)."
  (ecc-test-with-fake-session session
    (ecc-render-test--two-turns session)
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (ecc-session-next-turn)
      (should (looking-at "Turn 1  hello"))
      (ecc-session-next-turn)
      (should (looking-at "Turn 2  show me code"))
      (should-error (ecc-session-next-turn) :type 'user-error)
      (ecc-session-previous-turn)
      (should (looking-at "Turn 1  hello"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _) (cadr candidates))))
        (ecc-session-timeline))
      (should (looking-at "Turn 2  show me code")))))

(ert-deftest ecc-render-test-block-movement-and-folding ()
  "Blocks can be walked, and all of them folded or unfolded (FR-OUT-14 b, c)."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "edit-tool" "greet を直して" '(allow))
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (ecc-session-next-block)
      (should (looking-at "  /private/tmp/claude-501/.*hello.py  R×1 E×1"))
      (ecc-session-next-block)
      (should (looking-at "    ✓ Read"))
      (ecc-session-next-block)
      (should (looking-at "    ✓ Edit"))
      (ecc-session-previous-block)
      (should (looking-at "    ✓ Read"))
      (let ((tool (ecc-render-test--find-section "toolu_018jWzDJTbLaoSRyvPEiAggK")))
        (ecc-session-expand-all)
        (should-not (oref tool hidden))
        (ecc-session-collapse-all)
        (should (oref tool hidden))
        ;; Turns stay open.
        (should-not (oref (ecc-render--turn-section "turn-1") hidden))))))

(ert-deftest ecc-render-test-copy-at-point ()
  "The code block under point is copied, or else the whole reply (FR-OUT-14 e)."
  (ecc-test-with-fake-session session
    (ecc-render-test--two-turns session)
    (with-current-buffer (ecc-session-buffer session)
      (let ((kill-ring nil))
        (goto-char (point-min))
        (search-forward "(+ 1 2)")
        (ecc-session-copy-at-point)
        (should (equal (car kill-ring) "(+ 1 2)\n"))
        (search-forward "Done.")
        (ecc-session-copy-at-point)
        (should (equal (car kill-ring) "Here:\n\n```elisp\n(+ 1 2)\n```\n\nDone."))
        (goto-char (point-min))
        (should-error (ecc-session-copy-at-point) :type 'user-error)))))

(ert-deftest ecc-render-test-export-markdown ()
  "The transcript is saved as Markdown, one section per turn (FR-OUT-14 f)."
  (ecc-test-with-fake-session session
    (ecc-render-test--two-turns session)
    (let ((file (make-temp-file "ecc-export" nil ".md")))
      (unwind-protect
          (with-current-buffer (ecc-session-buffer session)
            (ecc-session-export-markdown file)
            (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (should (string-prefix-p "# test\n\n## hello\n\nhello from emacs\n\n" text))
              (should (string-search "## show me code\n\nHere:\n\n```elisp\n(+ 1 2)\n```" text))
              (should (string-search "_end_turn · $0.0100_" text))))
        (delete-file file)))))


(ert-deftest ecc-render-test-delta-append-is-cheap ()
  "Appending a delta costs well under the 5ms the plan allows (phase 2)."
  (ecc-test-with-fake-session session
    (let ((ecc-stream-throttle 0)
          (count 0)
          (elapsed 0.0))
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "長いファイルを書いて")
      (dolist (line (ecc-test-fixture-lines "partial-messages"))
        (let* ((message (ecc-protocol-parse-line line))
               (event (alist-get 'event message)))
          (if (equal (alist-get 'type event) "content_block_delta")
              (progn
                (cl-incf count)
                (cl-incf elapsed (car (benchmark-run 1 (ecc-dispatch session message)))))
            (ecc-dispatch session message)
            (when (equal (alist-get 'type event) "content_block_start")
              (ecc-render-flush session)))))
      (should (> count 40))
      ;; The bound is loose for a slow machine; what it guards against is
      ;; a delta that redraws the whole live region.
      (should (< (/ elapsed count) 0.005)))))

(provide 'ecc-render-test)

;;; ecc-render-test.el ends here
