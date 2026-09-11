;;; ecc-render-test.el --- Tests for ecc-render  -*- lexical-binding: t; -*-

;;; Commentary:

;; Replays a recording into a session buffer and compares the text of
;; the buffer with a snapshot in test/snapshots.  Rewrite a snapshot
;; after an intended change with:
;;
;;     ECC_UPDATE_SNAPSHOTS=1 make test

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-session)
(require 'ecc-perm)
(require 'ecc-dispatch)
(require 'ecc-proc)
(require 'ecc-visual)

(defmacro ecc-render-test--with-recorded-home (&rest body)
  "Run BODY with HOME set to the one the fixtures were recorded under.
A path under the home directory is drawn with `abbreviate-file-name',
and the recordings carry /Users/jun, so a machine whose home is
somewhere else (a Linux CI runner) would draw the whole path and miss
the snapshot.  It is bound around the drawing alone: a test that starts
a process needs the home this machine really has."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (let ((process-environment (cons "HOME=/Users/jun" process-environment))
             (abbreviated-home-dir nil))
         ,@body)
     ;; The cache remembers which home it was made for, and one made for
     ;; the wrong one turns the abbreviation off for the rest of the run.
     (setq abbreviated-home-dir nil)))

(defun ecc-render-test--replay (session name prompt &optional answers)
  "Replay fixture NAME into SESSION under PROMPT and draw it.
ANSWERS is a list of `allow', `(deny . REASON)' or a function called
with the request, used in turn for the requests the recording makes."
  (ecc-render-test--with-recorded-home
   (ecc-render-test--replay-1 session name prompt answers)))

(defun ecc-render-test--replay-1 (session name prompt answers)
  "Do the work of `ecc-render-test--replay' for SESSION.
NAME, PROMPT and ANSWERS are as there."
  (ecc-session-ensure-buffer session)
  (ecc-model-begin-turn session prompt)
  (dolist (line (ecc-test-fixture-lines name))
    (let ((message (ecc-protocol-parse-line line)))
      (ecc-dispatch session message)
      (when (and answers (eq (ecc-protocol-control-subtype message) 'can_use_tool))
        (let ((request (car (ecc-session-pending session)))
              (answer (pop answers)))
          (cond ((functionp answer) (funcall answer request))
                ((eq answer 'allow) (ecc-perm-respond request 'allow))
                (t (ecc-perm-respond request 'deny :message (cdr answer))))))))
  (ecc-render-flush session)
  (ecc-test-buffer-string (ecc-session-buffer session)))

(defun ecc-render-test--check (name text)
  "Fail unless TEXT matches snapshot NAME, saying where to look."
  (unless (ecc-test-snapshot name text)
    (ert-fail (format "%s differs from its snapshot; see %s.new"
                      name (ecc-test-snapshot-file name)))))

;;;; Snapshots

(ert-deftest ecc-render-test-request-hints-name-the-keys-that-do-it ()
  "A key in the hints runs the command its word promises.
The hints are a string, and the keymap moved under it once already:
`t\\=' and `p\\=' became `u\\=' and `r\\=', and the line on screen went on
offering `t\\=', which everywhere else hands the session to a terminal.
Asking only whether the key is bound would not have caught that -- it
was bound, to the wrong thing."
  (let ((commands '(("allow" . ecc-perm-allow)
                    ("deny" . ecc-perm-deny)
                    ("always" . ecc-perm-allow-always)
                    ("turn" . ecc-perm-approve-turn)
                    ("rule" . ecc-perm-add-pattern)
                    ("comment" . ecc-review-comment-request)
                    ("edit" . ecc-review-edit-proposal)
                    ("answer" . ecc-session-visit)
                    ("review" . ecc-session-visit)
                    ("approve" . ecc-perm-allow))))
    (dolist (kind '(question plan nil))
      (let ((hints (ecc-render--request-hints kind))
            (start 0))
        (while (string-match "\\([A-Za-z]+\\): \\([a-z]+\\)" hints start)
          (setq start (match-end 0))
          (let* ((key (match-string 1 hints))
                 (word (match-string 2 hints))
                 (wanted (alist-get word commands nil nil #'equal)))
            (should wanted)
            (should (eq (lookup-key ecc-request-section-map (kbd key))
                        wanted))))))))

(ert-deftest ecc-render-test-basic-turn ()
  "A plain question and answer draw as one turn with a result line."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "basic-turn" "hello")))
      (ecc-render-test--check "basic-turn" text)
      ;; No heading of the session stands at the top of the buffer any
      ;; more; the band of the first turn is what it opens with.
      (should (string-prefix-p "\n〉 hello\n" text))
      (should-not (string-search "claude-haiku" text))
      ;; What it is doing is on the left of the header line, what it is
      ;; on the right.  The model is not there: the footer under the
      ;; prompt names it.
      (with-current-buffer (ecc-session-buffer session)
        (let ((header (substring-no-properties (ecc-render-header-line))))
          (should (string-search "○ idle" header))
          (should-not (string-search "haiku" header)))))))

(ert-deftest ecc-render-test-turn-end-line-answers-the-transcript-keys ()
  "The figures closing a turn carry the transcript keymap.
They used to carry a face and nothing else, so point sitting on them
killed the whole transcript keymap -- not only `i\=', but `n\=', `p\=',
TAB, `a\=', `d\=', `q\=' and `g\=' too."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "basic-turn" "hello")
    (with-current-buffer (ecc-session-buffer session)
      (let ((gaps 0))
        (goto-char (point-min))
        (while (< (point) ecc-render--prompt-start)
          (unless (get-text-property (point) 'keymap)
            (setq gaps (1+ gaps)))
          (forward-char 1))
        ;; Every character of the transcript answers to the map.
        (should (= gaps 0))))))

(ert-deftest ecc-render-test-footer-follows-a-model-change ()
  "The footer names the new model as soon as `/model' is sent.
It used to name the model of init, which the CLI never sends again, so a
`/model' only showed once the next answer named the model it came back
with.  The name stands under the prompt rather than in the header line,
next to the permission mode."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (setf (ecc-session-init session) '((model . "claude-haiku-4-5-20251001")))
    (with-current-buffer (ecc-session-buffer session)
      (should (equal "haiku" (ecc-render--model-name session)))
      (ecc-chat-update-footer)
      (should (string-suffix-p " haiku" (ecc-chat-footer-shown)))
      (ecc-proc-send-prompt session "/model opus")
      (should (equal "opus" (ecc-render--model-name session)))
      (ecc-chat-update-footer)
      (let ((footer (ecc-chat-footer-shown)))
        (should (string-suffix-p " opus" footer))
        (should-not (string-search "haiku" footer))))))

(ert-deftest ecc-render-test-header-shows-remote-control ()
  "A session on the Remote Control bridge says so, with the URL in the tooltip.
The header line has no room for the URL, and without it nothing on
screen says where the session can be reached (confirmed 2026-09-08)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (with-current-buffer (ecc-session-buffer session)
      (should-not (string-search "remote" (substring-no-properties
                                           (ecc-render-header-line))))
      (ecc-model-set-remote-control session 'enabled t 'state "ready"
                                    'session-url "https://claude.ai/code/session_01")
      (let ((header (ecc-render-header-line)))
        (should (string-search "⇄ remote" (substring-no-properties header)))
        (should (equal "https://claude.ai/code/session_01"
                       (get-text-property (string-search "⇄" header)
                                          'help-echo header))))
      ;; Somebody on the other end shows as a dot.
      (ecc-model-set-remote-control session 'state "connected")
      (should (string-search "⇄ remote ●" (substring-no-properties
                                           (ecc-render-header-line)))))
    ;; What the bridge says lands under a turn of its own, and that turn
    ;; says what it is: nobody prompted it, and nothing was resumed.
    (ecc-dispatch session '((type . "system") (subtype . "bridge_state")
                            (state . "connected")))
    (ecc-render-refresh session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "(session)" text))
      (should-not (string-search "(resumed)" text))
      (should (string-search "remote control connected" text)))))

(ert-deftest ecc-render-test-wrap-prefix-follows-the-indentation ()
  "Every line of a body says where a line that wraps out of it lines up."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "basic-turn" "hello")
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      ;; The text of the answer sits two columns in, and a wrapped line
      ;; sits under it, in the same column, rather than at the left edge.
      (should (search-forward "\n  " nil t))
      (let ((wrap (get-text-property (line-beginning-position) 'wrap-prefix)))
        (should (equal "  " wrap))))))

(ert-deftest ecc-render-test-a-list-item-wraps-under-itself ()
  "A line that opens a list item wraps under the item, not its bullet.
What is measured is the bullet as it is drawn: `ecc-markdown-fontify'
puts a one-column bullet over the marker, so a numbered marker is
narrower on the screen than it is in the text."
  (with-temp-buffer
    (ecc-render--insert-lines
     (ecc-markdown-fontify "- ひとつめ\n1. ふたつめ\nふつうの段落\n")
     "  " 'ecc-assistant-face)
    (goto-char (point-min))
    (let ((wraps nil))
      (while (not (eobp))
        (push (get-text-property (line-beginning-position) 'wrap-prefix) wraps)
        (forward-line 1))
      ;; "  " + "- " for the first, "  " + the bullet drawn over "1." and
      ;; the blank after it for the second, and the bare indentation for
      ;; the paragraph, which opens no item.
      (should (equal '("    " "    " "  ") (nreverse wraps))))))

(ert-deftest ecc-render-test-tool-use ()
  "A lone tool draws as a tool line and the permission that allowed it."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "tool-use-write"
                                         "hello.txt を作って" '(allow))))
      (ecc-render-test--check "tool-use-write" text)
      ;; One tool needs no step over it: the tool line takes its place.
      (should-not (string-search "Write ×1" text))
      (should (string-search "\n  ✓ Write · " text))
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

(ert-deftest ecc-render-test-plan-review ()
  "A plan request shows the plan and, once approved, the mode chosen."
  (ecc-test-with-fake-session session
    (require 'ecc-plan)
    (let ((text (ecc-render-test--replay
                 session "plan-mode" "utils.py の計画を立てて"
                 (list (lambda (request)
                         (with-current-buffer (ecc-plan-open request)
                           (ecc-plan-approve)))))))
      (ecc-render-test--check "plan-mode" text)
      (should (string-search "✓ Plan review  approved → acceptEdits" text))
      (should (string-search "# Plan: utils.py" text)))))

(ert-deftest ecc-render-test-question ()
  "A question lists its options and, once answered, the answers given."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay
                 session "ask-user-question" "質問して"
                 (list (lambda (request)
                         (with-current-buffer (ecc-question-open request)
                           (ecc-question-choose 1)
                           (ecc-question-choose 1)
                           (ecc-question-choose 2)
                           (ecc-question-submit)))))))
      (ecc-render-test--check "ask-user-question" text)
      (should (string-search "✓ Question  answered: Emacs · Elisp, Python" text))
      (should (string-search "→ Elisp, Python" text)))))

(ert-deftest ecc-render-test-pending-request-hints ()
  "A waiting permission shows its keys; a waiting question its own."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let ((node (ecc-model-add-node session :type 'permission :status 'pending))
          (request (make-ecc-request :request-id "r" :session session :kind 'permission
                                     :tool-name "Bash" :display-name "Bash"
                                     :input '((command . "ls")) :created-at (current-time))))
      (ecc-model-node-put node 'request request)
      (setf (ecc-request-node request) node)
      (ecc-model-add-request session request)
      (ecc-render-flush session)
      (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
        (should (string-search "⚠ Permission: Bash  ls   a: allow  d: deny  A: always  u: turn  r: rule"
                               text))))))

(ert-deftest ecc-render-test-unsaved-warning-in-heading ()
  "An Edit of a file open with unsaved changes says so in its heading."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let* ((file (make-temp-file "ecc-render" nil ".txt" "one\n"))
           (buffer (find-file-noselect file)))
      (unwind-protect
          (progn
            (with-current-buffer buffer (insert "x"))
            (let ((node (ecc-model-add-node session :type 'permission :status 'pending))
                  (request (make-ecc-request :request-id "r" :session session
                                             :kind 'permission :tool-name "Edit"
                                             :display-name "Edit"
                                             :input `((file_path . ,file)
                                                      (old_string . "one")
                                                      (new_string . "two"))
                                             :created-at (current-time))))
              (ecc-model-node-put node 'request request)
              (setf (ecc-request-node request) node)
              (ecc-model-add-request session request)
              (ecc-render-flush session)
              (should (string-search "⚠ unsaved changes"
                                     (ecc-test-buffer-string (ecc-session-buffer session))))
              (with-current-buffer buffer (set-buffer-modified-p nil))
              (ecc-render-refresh session)
              (should-not (string-search "unsaved"
                                         (ecc-test-buffer-string (ecc-session-buffer session))))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)
        (delete-file file)))))

;;;; Incremental drawing

(ert-deftest ecc-render-test-finished-turns-are-left-alone ()
  "Once a turn is finished it is never drawn again."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-test-dispatch session "basic-turn" "hello")
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (should (= ecc-render--frozen 1))
      (let* ((entry (ecc-render-node-entry "turn-1"))
             (bounds (ecc-render-node-bounds "turn-1"))
             (text (buffer-substring-no-properties (car bounds) (cdr bounds))))
        (should entry)
        ;; A second turn arrives; the first one keeps its very markers
        ;; and its text, so nothing above the live region was redrawn.
        (ecc-model-begin-turn session "again")
        (ecc-render-flush session)
        (should (eq entry (ecc-render-node-entry "turn-1")))
        (should (= ecc-render--frozen 1))
        ;; The top region above it was redrawn (the state changed), so
        ;; the positions moved; the text between the markers did not.
        (let ((bounds (ecc-render-node-bounds "turn-1")))
          (should (equal text (buffer-substring-no-properties (car bounds) (cdr bounds)))))
        (should (string-search "〉 again" (buffer-string)))))))

(ert-deftest ecc-render-test-folding-survives-a-redraw ()
  "Collapsing a section sticks, because node ids are stable."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "hello.txt を作って")
    (dolist (line (ecc-test-fixture-lines "tool-use-write"))
      (ecc-dispatch session (ecc-protocol-parse-line line)))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (let ((id "toolu_01Hcu5xtMTxBqGiZ6MfT3XyZ"))
        (should (ecc-render-node-bounds id))
        ;; Tool bodies start collapsed.
        (should (ecc-render-node-hidden-p id))
        (ecc-render-show-node id)
        (should-not (ecc-render-node-hidden-p id))
        (ecc-render-flush session)
        (should-not (ecc-render-node-hidden-p id))))))

(ert-deftest ecc-render-test-refresh-rebuilds-the-same-text ()
  "Drawing everything again gives exactly what growing it gave."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-test-dispatch session "tool-use-write" "hello.txt を作って")
    (ecc-render-flush session)
    (let ((incremental (ecc-test-buffer-string (ecc-session-buffer session))))
      (ecc-render-refresh session)
      (should (equal incremental
                     (ecc-test-buffer-string (ecc-session-buffer session)))))))

(ert-deftest ecc-render-test-local-command ()
  "A slash command the CLI answered draws as one heading and its output."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "hello")
    (dolist (text (list (concat "<local-command-caveat>Caveat: The messages below"
                                " were generated by the user while running local"
                                " commands.</local-command-caveat>")
                        (concat "<command-name>/advisor</command-name>\n"
                                "            <command-message>advisor</command-message>\n"
                                "            <command-args></command-args>")))
      (ecc-dispatch session `((type . "user")
                              (message . ((role . "user") (content . ,text))))))
    (ecc-dispatch session
                  '((type . "system") (subtype . "local_command")
                    (content . "<local-command-stdout>Advisor: off\nUsage: /advisor <fable|opus|sonnet|off></local-command-stdout>")))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (ecc-render-test--check "local-command" text))))

(ert-deftest ecc-render-test-unknown-is-visible ()
  "A message the client does not understand still reaches the buffer."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-dispatch session '((type . "brand_new_thing") (subtype . "odd")
                            (detail . "hello")))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      ;; The subtype is in the heading: it is what tells the next one apart.
      (should (string-search "unknown: brand_new_thing/odd" text))
      (should (string-search "hello" text)))))

(ert-deftest ecc-render-test-unhandled-system-is-a-note ()
  "A system subtype this version does not handle is a dim note saying
which one it was, not the red line of an error (2026-09-09)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-dispatch session '((type . "system") (subtype . "vcs_state_changed")
                            (kind . "commit") (branch . "main")
                            (cwd . "/tmp/x")))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "system/vcs_state_changed — git commit main" text))
      (should-not (string-search "unknown:" text)))))

(ert-deftest ecc-render-test-long-system-note-is-summarised ()
  "A note the CLI writes into the conversation is a heading of its first
line and a folded body, the way a tool call is.  Invoking a Skill puts
the whole of its instructions in as one such note, which used to be
drawn entire (2026-09-11)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "hello")
    (ecc-dispatch
     session
     `((type . "user")
       (message
        . ((role . "user")
           (content . ,(concat "Approach this as the design lead at a small"
                               " studio known for their versatility.\n"
                               "\n## Read the request first\n"
                               "\nBOTTOM of the skill."))))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (let ((note (seq-find (lambda (id)
                              (let ((node (ecc-model-node session id)))
                                (and node (eq (ecc-node-type node) 'system))))
                            (ecc-render-block-ids))))
        (should note)
        (goto-char (car (ecc-render-node-bounds note)))
        (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                    (line-end-position))))
          (should (string-search "Approach this as the design lead" line))
          (should (string-suffix-p "…" line))
          (should-not (string-search "BOTTOM" line)))
        ;; The rest of it is drawn, but folded away under the heading.
        (should (ecc-render-node-hidden-p note))
        (should (string-search "BOTTOM" (ecc-test-buffer-string)))))))

;;;; Cost of drawing

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


;;;; Streaming

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
  "Each text delta lands in the buffer without a redraw."
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
        (should (equal (ecc-node-streaming-text node) "Done. Created")))
      ;; Feed the rest: the complete message replaces the streamed text
      ;; with the formatted one, and it is there exactly once.
      (dolist (line lines)
        (ecc-dispatch session (ecc-protocol-parse-line line)))
      (ecc-render-flush session)
      (let ((text (ecc-test-buffer-string buffer)))
        (should (= 1 (cl-count-if (lambda (line) (string-prefix-p "  Done. Created" line))
                                  (split-string text "\n"))))
        (should (string-search "  Done. Created `long.py` with 60 functions" text))
        (should (string-match-p "[0-9.]+s · \\$[0-9.]+" text))
        (should-not (ecc-model-find-stream session nil 'text)))
      ;; A code span inside the reply got its Markdown face.
      (with-current-buffer buffer
        (goto-char (point-min))
        (should (search-forward "`long.py`" nil t))
        (should (memq 'ecc-markdown-code-face
                      (ensure-list (get-text-property (match-beginning 0) 'face))))))))

(ert-deftest ecc-render-test-tool-input-streams-into-heading ()
  "While a Write streams its input only the heading changes."
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
        (should (string-match-p "… Write · streaming [0-9]+ chars…" text))))))

(ert-deftest ecc-render-test-thinking-pulses-while-it-streams ()
  "The heading of a thinking block pulses until the block ends."
  (ecc-test-with-fake-session session
    (let ((ecc-visual-enable-pulse t)
          (ecc-stream-throttle 0)
          (seen 0))
      (unwind-protect
          (let ((rest (ecc-render-test--stream
                       session "partial-messages" "長いファイルを書いて"
                       (lambda (message)
                         (when (ecc-render-test--delta-p message "thinking_delta")
                           (cl-incf seen))
                         (= seen 2)))))
            ;; While it streams the heading says so and its line moves.
            (should (string-search "Thinking…"
                                   (ecc-test-buffer-string (ecc-session-buffer session))))
            (should (ecc-render-test--pulsed-line session "Thinking…"))
            ;; Once the block is over the ellipsis and the pulse go with it.
            (dolist (line rest)
              (ecc-dispatch session (ecc-protocol-parse-line line)))
            (ecc-render-flush session)
            (should-not (ecc-render-test--pulsed-line session "Thinking")))
        (ecc-visual-clear-effects (ecc-session-buffer session))))))

(defun ecc-render-test--pulsed-line (session text)
  "Return non-nil when an effect of SESSION sits on a line holding TEXT."
  (with-current-buffer (ecc-session-buffer session)
    (cl-some (lambda (overlay)
               (and (eq (overlay-buffer overlay) (current-buffer))
                    (overlay-get overlay 'ecc-visual-timer)
                    (string-search text (buffer-substring-no-properties
                                         (overlay-start overlay)
                                         (overlay-end overlay)))))
             (ecc-visual-effects))))

(ert-deftest ecc-render-test-streamed-tree-matches-unstreamed ()
  "The stream events add nothing to the tree the assistant messages build."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "partial-messages" "長いファイルを書いて")
    (should (equal (ecc-test-turn-shape (car (ecc-session-turns session)))
                   '(thinking (step tool) permission thinking text result)))
    (should (= 0 (hash-table-count (ecc-session-stream-blocks session))))))

;;;; How long a call has been running (tool_progress)

(ert-deftest ecc-render-test-running-tool-says-how-long ()
  "A call the CLI is still working on shows the elapsed time it reports.
The mark goes only while the call runs: once the result is in, the
heading has nothing to wait for."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "run something slow")
    (ecc-dispatch session
                  '((type . "assistant") (uuid . "u1")
                    (message . ((role . "assistant")
                                (content . [((type . "tool_use") (id . "t1")
                                             (name . "Bash")
                                             (input . ((command . "sleep 90"))))])))))
    (ecc-render-flush session)
    ;; Nothing is said before the first heartbeat: a call that answers
    ;; inside thirty seconds never needs a clock.
    (should-not (string-search "⏱" (ecc-test-buffer-string
                                    (ecc-session-buffer session))))
    (ecc-dispatch session '((type . "tool_progress")
                            (parent_tool_use_id . "t1")
                            (elapsed_time_seconds . 30)))
    (ecc-render-flush session)
    (should (string-search "Bash · sleep 90 · ⏱ 30s"
                           (ecc-test-buffer-string (ecc-session-buffer session))))
    ;; Above a minute it is read as minutes and seconds.
    (ecc-dispatch session '((type . "tool_progress")
                            (parent_tool_use_id . "t1")
                            (elapsed_time_seconds . 150)))
    (ecc-render-flush session)
    (should (string-search "⏱ 2m30s"
                           (ecc-test-buffer-string (ecc-session-buffer session))))
    (ecc-dispatch session
                  '((type . "user") (uuid . "u2")
                    (message . ((role . "user")
                                (content . [((type . "tool_result") (tool_use_id . "t1")
                                             (content . "done"))])))))
    (ecc-render-flush session)
    (should-not (string-search "⏱" (ecc-test-buffer-string
                                    (ecc-session-buffer session))))))

;;;; Subagents

(ert-deftest ecc-render-test-subagent ()
  "An agent draws nested, with its prompt, tools and reply."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "subagent" "探して")))
      (ecc-render-test--check "subagent" text)
      (should (string-search "✓ Agent Explore · Find all .py files in current directory · 1 tools · 5.1s"
                             text))
      (should (string-search "    〉 List all .py files" text))
      (should (string-search "    ✓ Bash · find . -name" text))
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
                  (should (string-search "Bash · find . -name" text))
                  (should (string-search "〉 List all .py files" text)))
              (kill-buffer buffer))))))))

(ert-deftest ecc-render-test-subagent-starts-folded ()
  "The body of an agent starts folded, like a tool's."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "subagent" "探して")
    (let ((agent (seq-find (lambda (node) (eq (ecc-node-type node) 'agent))
                           (hash-table-values (ecc-session-nodes session)))))
      (should agent)
      (with-current-buffer (ecc-session-buffer session)
        (let ((id (ecc-node-id agent)))
          (should (ecc-render-node-hidden-p id))
          ;; Its heading is still there to open it with.
          (should (ecc-render-node-bounds id))
          (ecc-render-show-node id)
          (should-not (ecc-render-node-hidden-p id))
          (ecc-render-flush session)
          (should-not (ecc-render-node-hidden-p id)))))))

(ert-deftest ecc-render-test-agent-with-no-type-is-named-once ()
  "An agent that names no type says \"Agent\", not \"Agent Agent\"."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "調べて")
    (let* ((node (ecc-model-add-node
                  session :id "toolu_agentless" :type 'agent
                  :data '((name . "Task")
                          (input . ((description . "look around"))))))
           (heading (substring-no-properties
                     (ecc-render--agent-heading node 0))))
      (should (string-search "Agent · look around" heading))
      (should-not (string-search "Agent Agent" heading))
      ;; A type, when there is one, is still said.
      (ecc-model-node-put node 'agent-type "Explore")
      (should (string-search "Agent Explore"
                             (substring-no-properties
                              (ecc-render--agent-heading node 0)))))))

(ert-deftest ecc-render-test-agent-description-is-cut-to-one-line ()
  "A long agent description is cut like a tool call, not wrapped."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "調べて")
    (let* ((long (make-string 200 ?x))
           (node (ecc-model-add-node
                  session :id "toolu_agent_long" :type 'agent
                  :data `((name . "Task")
                          (input . ((description . ,long))))))
           (heading (substring-no-properties
                     (ecc-render--agent-heading node 0))))
      (should (string-search (concat (make-string
                                      (1- ecc-render-summary-width) ?x)
                                     "…")
                             heading))
      (should-not (string-search (make-string ecc-render-summary-width ?x)
                                 heading))
      (should (= 1 (length (split-string heading "\n")))))
    ;; The same description reaches the same width through the tool path.
    (should (= ecc-render-summary-width
               (length (ecc-render-tool-summary
                        "Task" `((description . ,(make-string 200 ?x)))))))))

;;;; Diffs

(ert-deftest ecc-render-test-edit-diff ()
  "An Edit is drawn as a diff with the lines of the file around it."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "edit-tool" "greet を直して" '(allow))))
      (ecc-render-test--check "edit-tool" text)
      ;; The permission section showed the change in place, with context
      ;; taken from the Read that came before.
      (should (string-search (concat "  ✓ Permission: Edit  allowed\n"
                                     "    /private/tmp/claude-501/")
                             text))
      (should (string-search (concat "    @@ -1,6 +1,6 @@\n"
                                     "     def greet(name):\n"
                                     "         \"\"\"Say hi.\"\"\"\n"
                                     "    -    return \"hi \" + name\n"
                                     "    +    return \"hello \" + name\n")
                             text))
      ;; The tool section shows the same diff ...
      (should (string-search "    -    return \"hi \" + name\n    +    return \"hello \" + name\n"
                             text))
      ;; ... with diff-mode faces.
      (with-current-buffer (ecc-session-buffer session)
        (goto-char (point-min))
        (should (search-forward "+    return \"hello \" + name" nil t))
        (should (memq 'diff-added
                      (ensure-list (get-text-property (match-beginning 0) 'face)))))
      ;; The Files section merges the patches the CLI reported.
      (should (string-search "  Files (1)\n    /private/tmp/claude-501/" text))
      (should (string-search "hello.py  R×1 E×1  +1 −1\n      @@ -1,6 +1,6 @@\n" text)))))

(ert-deftest ecc-render-test-write-diff-is-clipped ()
  "A long Write shows the head of its diff and says how much was cut."
  (ecc-test-with-fake-session session
    (let* ((ecc-render-diff-max-lines 5)
           (text (ecc-render-test--replay session "partial-messages"
                                         "長いファイルを書いて" '(allow))))
      (should (string-search "    @@ -0,0 +1,298 @@\n    +def f0():\n" text))
      (should (string-search "… 294 more lines (RET)" text))
      ;; The Files section keeps the whole diff behind its fold.
      (should (string-search "long.py  W×1  +298 −0\n" text))
      (should (string-search "    +    return 59\n" text)))))

;;;; Files and Tasks

(ert-deftest ecc-render-test-tasks ()
  "TaskCreate, TaskUpdate and TaskList keep the checklist current."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "tasks" "タスクを作って")))
      (ecc-render-test--check "tasks" text)
      (should (string-search "  Tasks (1/2)\n    [x] Write tests\n    [ ] Update docs\n" text)))))

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
  "A file row starts folded, toggles with TAB and opens the file with RET."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "edit-tool" "greet を直して" '(allow))
    (with-current-buffer (ecc-session-buffer session)
      (let* ((path (ecc-file-entry-path (car (ecc-model-files session))))
             (id (concat "file:" path)))
        (should (ecc-render-node-bounds id))
        (should (ecc-render-node-hidden-p id))
        (should (ecc-render-node-hidden-p "files"))
        ;; Going to the row unfolds it and the section above it.
        (ecc-render-goto-id id)
        (should (equal (ecc-chat-file-at-point) path))
        (should-not (ecc-render-node-hidden-p id))
        (should-not (ecc-render-node-hidden-p "files"))
        ;; TAB folds here as everywhere else in the transcript; SPC is
        ;; left to scroll, which is what it does off the row.
        (should (eq (lookup-key ecc-file-section-map (kbd "TAB")) #'ecc-chat-toggle))
        (should (eq (lookup-key ecc-file-section-map (kbd "SPC")) #'scroll-up-command))
        (ecc-chat-toggle)
        (should (ecc-render-node-hidden-p id))
        (ecc-chat-toggle)
        (should-not (ecc-render-node-hidden-p id))
        ;; RET opens the file (which need not exist for the call to be made).
        (let (opened)
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (file) (setq opened file))))
            (ecc-session-visit))
          (should (equal opened path)))))))

(ert-deftest ecc-render-test-summaries-stand-above-the-prompt ()
  "The summaries are drawn under the turns, not at the start of the buffer.
At the top they scroll out of sight as the conversation grows;
`ecc-render-summary-position' puts them back there."
  (ecc-test-with-fake-session session
    (let* ((text (ecc-render-test--replay session "edit-tool"
                                         "greet を直して" '(allow)))
           (band (string-search "〉 greet" text))
           (tool (string-search "✓ Edit" text))
           (files (string-search "Files (1)" text)))
      (should band)
      (should tool)
      (should files)
      (should (< band tool files))))
  (ecc-test-with-fake-session session
    (let* ((ecc-render-summary-position 'top)
           (text (ecc-render-test--replay session "edit-tool"
                                         "greet を直して" '(allow))))
      (should (< (string-search "Files (1)" text)
                 (string-search "〉 greet" text))))))

(ert-deftest ecc-render-test-summary-fold-survives-a-redraw ()
  "A summary the user opened stays open when the live region is drawn again.
It is redrawn with every turn now, so its fold has to come back from
the cache the same way a node of the transcript does."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "edit-tool" "greet を直して" '(allow))
    (with-current-buffer (ecc-session-buffer session)
      (should (ecc-render-node-hidden-p "files"))
      (ecc-render-show-node "files")
      (ecc-model-begin-turn session "もう一度")
      (ecc-render-flush session)
      (should (ecc-render-node-bounds "files"))
      (should-not (ecc-render-node-hidden-p "files"))
      (ecc-render-hide-node "files")
      (ecc-render-refresh session)
      (should (ecc-render-node-hidden-p "files")))))

;;;; The state line

(ert-deftest ecc-render-test-status-line ()
  "The header line follows the state and names what is running."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (should (string-prefix-p "○ starting" (ecc-render-status-line session)))
    (ecc-model-begin-turn session "hello")
    ;; A running turn says that and no more: the tool, the token counts
    ;; and the line the CLI keeps about the turn were dropped from the
    ;; header, since the transcript below shows them already.
    (should (equal "▶ running"
                   (substring-no-properties (ecc-render-status-line session))))
    (ecc-dispatch session '((type . "system") (subtype . "thinking_tokens")
                            (estimated_tokens . 1200)))
    (ecc-dispatch session '((type . "system") (subtype . "task_summary")
                            (detail . "reading ecc-render.el")))
    (let ((node (ecc-model-add-node session :id "t1" :type 'tool :status 'running
                                    :parent (ecc-model-step-for-tool
                                             session (ecc-session-current-turn session))
                                    :data '((name . "Bash") (input . ((command . "git status")))
                                            (started . (0 1))))))
      (ecc-model-note-tool-running session node)
      (should (equal "▶ running"
                     (substring-no-properties (ecc-render-status-line session))))
      (setf (ecc-node-status node) 'done))
    (ecc-model-add-request session (make-ecc-request
                                    :request-id "r" :session session :kind 'permission
                                    :tool-name "Write" :input '((file_path . "/tmp/x"))
                                    :created-at (current-time)))
    (should (string-prefix-p "⚠ permission: Write" (ecc-render-status-line session)))
    (with-current-buffer (ecc-session-buffer session)
      (should (string-prefix-p " ⚠ permission" (ecc-render-header-line))))))

;;;; Movement and extraction

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

(ert-deftest ecc-render-test-band-reaches-the-edge-of-the-window ()
  "The band of a prompt is a band, not a highlight around the words.
`:extend\=' paints to the edge of the window only where the face covers
the character a line ends on, so the newline has to wear it too.  No
snapshot can catch this: a face is not text."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "basic-turn" "hello")
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (should (search-forward "〉 hello" nil t))
      (let ((faces (get-text-property (line-end-position) 'face)))
        (should (memq 'ecc-user-face (if (listp faces) faces (list faces)))))
      (should (eq (face-attribute 'ecc-user-face :extend nil t) t))
      ;; The mark carries a colour of its own on top of the band.
      (let ((faces (get-text-property (line-beginning-position) 'face)))
        (should (memq 'ecc-user-mark-face (if (listp faces) faces (list faces))))
        (should (memq 'ecc-user-face (if (listp faces) faces (list faces))))))))

(ert-deftest ecc-render-test-code-block-reaches-the-buffer ()
  "A fenced block is coloured by its mode and its fences are out of sight.
The code block colouring has to survive the trip from
`ecc-markdown-fontify\=' into the session buffer, and the fence lines
have to be there for whatever searches the text while showing nothing."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "show me code")
    (ecc-dispatch session
                  '((type . "assistant") (uuid . "u9")
                    (message . ((role . "assistant")
                                (content . [((type . "text")
                                             (text . "Here:\n\n```elisp\n(defun f () (message \"hi\"))\n```\n"))])))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (should (search-forward "defun" nil t))
      (let ((faces (get-text-property (match-beginning 0) 'face)))
        (should (memq 'font-lock-keyword-face (if (listp faces) faces (list faces))))
        (should (memq 'ecc-markdown-code-face (if (listp faces) faces (list faces)))))
      ;; A string further in is coloured as well, so the whole block
      ;; came through and not just its first token.
      (goto-char (point-min))
      (should (search-forward "\"hi\"" nil t))
      (let ((faces (get-text-property (match-beginning 0) 'face)))
        (should (memq 'font-lock-string-face (if (listp faces) faces (list faces)))))
      ;; The fence is in the buffer and hidden, newline and all.
      (goto-char (point-min))
      (should (search-forward "```elisp" nil t))
      (let ((bol (line-beginning-position)))
        (should (eq (get-text-property bol 'invisible) 'ecc-markup))
        (should (eq (get-text-property (line-end-position) 'invisible) 'ecc-markup))))))

(ert-deftest ecc-render-test-turn-movement-and-timeline ()
  "Turns can be walked and picked by their prompt (d)."
  (ecc-test-with-fake-session session
    (ecc-render-test--two-turns session)
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (ecc-chat-next-turn)
      (should (looking-at "〉 hello"))
      (ecc-chat-next-turn)
      (should (looking-at "〉 show me code"))
      (should-error (ecc-chat-next-turn) :type 'user-error)
      (ecc-chat-previous-turn)
      (should (looking-at "〉 hello"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _) (cadr candidates))))
        (ecc-session-timeline))
      (should (looking-at "〉 show me code")))))

(ert-deftest ecc-render-test-block-movement-and-folding ()
  "Blocks can be walked, and all of them folded or unfolded (c)."
  (ecc-test-with-fake-session session
    (ecc-render-test--replay session "edit-tool" "greet を直して" '(allow))
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (ecc-chat-next-block)
      (should (looking-at "  ✓ Read"))
      (ecc-chat-next-block)
      (should (looking-at "  ✓ Edit"))
      ;; The file row is a block too, and it stands under the turns now,
      ;; after the permission the Edit asked for.
      (ecc-chat-next-block)
      (should (looking-at "  ✓ Permission: Edit"))
      (ecc-chat-next-block)
      (should (looking-at "    /private/tmp/claude-501/.*hello.py  R×1 E×1"))
      (ecc-chat-previous-block)
      (should (looking-at "  ✓ Permission: Edit"))
      (let ((tool "toolu_018jWzDJTbLaoSRyvPEiAggK"))
        (ecc-chat-expand-all)
        (should-not (ecc-render-node-hidden-p tool))
        (ecc-chat-collapse-all)
        (should (ecc-render-node-hidden-p tool))
        ;; Turns stay open.
        (should-not (ecc-render-node-hidden-p "turn-1"))))))

(ert-deftest ecc-render-test-copy-at-point ()
  "The code block under point is copied, or else the whole reply."
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
  "The transcript is saved as Markdown, one section per turn."
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

;;;; Following the end

(defun ecc-render-test--answer (session text &optional uuid)
  "Give SESSION an assistant TEXT and a result, as one turn would."
  (ecc-dispatch session `((type . "assistant")
                          (message . ((role . "assistant")
                                      (content . [((type . "text") (text . ,text))])))
                          (uuid . ,(or uuid text))))
  (ecc-dispatch session '((type . "result") (subtype . "success"))))

(defun ecc-render-test--line ()
  "Return the line point stands on, without its properties."
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(ert-deftest ecc-render-test-point-stays-in-a-running-turn ()
  "Point in a turn that is still growing is not dragged to the prompt.
The live region is deleted and drawn again on every change, and a
point in it used to count as watching the end, so a redraw -- ten a
second while a turn arrives -- put it back at the prompt and the
cursor could not be moved into the answer at all."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "hello")
    (dotimes (i 6)
      (ecc-model-add-node session :type 'text
                          :data `((text . ,(format "paragraph %d" i)))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (marker-position ecc-render--live-start))
      (should (search-forward "paragraph 3" nil t))
      (goto-char (match-beginning 0))
      (let ((line (ecc-render-test--line)))
        ;; A redraw of the live region: another node of the same turn.
        (ecc-model-add-node session :type 'text :data '((text . "paragraph 6")))
        (ecc-render-flush session)
        (should (equal (ecc-render-test--line) line))
        (should-not (= (point) (ecc-render-prompt-start)))
        ;; And a flush of streamed text, which arrives far more often.
        (let ((node (ecc-model-add-node session :type 'text :data '((text . "")))))
          (ecc-render-flush session)
          (goto-char (marker-position ecc-render--live-start))
          (should (search-forward "paragraph 3" nil t))
          (goto-char (match-beginning 0))
          (ecc-render--on-delta session node "streamed")
          (ecc-render-flush-deltas session)
          (should (equal (ecc-render-test--line) line))
          (should-not (= (point) (ecc-render-prompt-start))))))))

(ert-deftest ecc-render-test-refresh-keeps-following-the-end ()
  "A window watching the end keeps watching it after a full redraw.
Drawing from scratch erases the buffer, which drags every window point
back to the top; a window that is no longer at the end is not followed,
so before this was handled a resumed session never scrolled to a new
turn again and looked as though nothing had arrived."
  (ecc-test-with-fake-session session
    (let ((buffer (ecc-session-ensure-buffer session))
          (window (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (ecc-model-begin-turn session "one")
            (ecc-render-test--answer session "first answer")
            (ecc-render-flush session)
            (set-window-point window (with-current-buffer buffer (point-max)))
            ;; What a resume, a history page and `g' all do.
            (ecc-render-refresh session)
            (should (= (window-point window)
                       (with-current-buffer buffer (point-max))))
            ;; And the next turn is followed, rather than appended out of sight.
            (ecc-model-begin-turn session "two")
            (ecc-render-test--answer session "second answer")
            (ecc-render-flush session)
            (should (string-search "second answer" (ecc-test-buffer-string buffer)))
            (should (= (window-point window)
                       (with-current-buffer buffer (point-max)))))
        (when (window-live-p window) (delete-window window))))))

(ert-deftest ecc-render-test-refresh-leaves-a-reader-alone ()
  "A window looking at an older turn is not dragged to the end."
  (ecc-test-with-fake-session session
    (let ((buffer (ecc-session-ensure-buffer session))
          (window (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (ecc-model-begin-turn session "one")
            (ecc-render-test--answer session "first answer")
            (ecc-render-flush session)
            (set-window-point window (point-min))
            (ecc-render-refresh session)
            (should-not (= (window-point window)
                           (with-current-buffer buffer (point-max)))))
        (when (window-live-p window) (delete-window window))))))

(ert-deftest ecc-render-test-header-line-keeps-a-percent-sign ()
  "A command with a percent sign in it is not eaten by the header line."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "print something")
    (ecc-test-add-request session "Bash" '((command . "printf %s done")))
    (with-current-buffer (ecc-session-buffer session)
      (let ((header (substring-no-properties (ecc-render-header-line))))
        ;; Doubled on the way in, so that one of them is drawn.
        (should (string-search "printf %%s done" header))
        (should-not (string-search "printf %s done" header))))))

(ert-deftest ecc-render-test-question-summary-is-the-question ()
  "A question reads as the question, not as the JSON around it."
  (let ((input (ecc--json-read
                (concat "{\"questions\":[{\"question\":\"行頭の記号は？\","
                        "\"header\":\"行頭\",\"options\":[{\"label\":\"状態\"}]}]}"))))
    (should (equal (ecc-render-tool-summary "AskUserQuestion" input)
                   "行頭の記号は？")))
  ;; Two questions are joined; the shape is still never shown.
  (let ((input (ecc--json-read
                "{\"questions\":[{\"question\":\"一つ目\"},{\"question\":\"二つ目\"}]}")))
    (should (equal (ecc-render-tool-summary "AskUserQuestion" input)
                   "一つ目 / 二つ目")))
  ;; Nothing to read falls back to the first value rather than erroring.
  (should (equal (ecc-render-tool-summary "AskUserQuestion" nil) "")))

(provide 'ecc-render-test)

;;; ecc-render-test.el ends here
