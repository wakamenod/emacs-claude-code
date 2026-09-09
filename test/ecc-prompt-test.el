;;; ecc-prompt-test.el --- Tests for ecc-prompt  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sending, queueing and slash command completion (FR-INP-1, 2, 3, 6),
;; the two kinds of slash command that need care (FR-INP-4, 5), the
;; history (FR-INP-7), the @ references (FR-INP-8), pasted images
;; (FR-INP-9) and the editor context (FR-CTX-1).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-prompt)
(require 'ecc-session)
(require 'ecc-dispatch)

(defmacro ecc-prompt-test--in-buffer (session &rest body)
  "Run BODY in the buffer of SESSION, with point in the prompt region."
  (declare (indent 1))
  `(with-current-buffer (ecc-session-ensure-buffer ,session)
     (ecc-chat-goto-prompt)
     ,@body))

(ert-deftest ecc-prompt-test-send ()
  "The buffer goes out as a user message and is emptied (FR-INP-1)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--in-buffer session
      (insert "hello\nworld")
      (ecc-prompt-send)
      (should (string-empty-p (ecc-chat-draft))))
    (let ((sent (car (ecc-test-sent-messages))))
      (should (equal (ecc-protocol-serialize sent)
                     (ecc-protocol-serialize
                      (ecc-protocol-user-message "hello\nworld")))))
    ;; Sending opens the turn; the CLI does not announce one (plan 4.1).
    (should (ecc-session-current-turn session))
    (should (equal (ecc-turn-prompt (ecc-session-current-turn session))
                   "hello\nworld"))))

(ert-deftest ecc-prompt-test-empty-prompt-is-refused ()
  "An empty buffer is not sent."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--in-buffer session
      (insert "   \n")
      (should-error (ecc-prompt-send) :type 'user-error))
    (should-not (ecc-test-sent-messages))))

(ert-deftest ecc-prompt-test-queue-while-running ()
  "A prompt sent during a turn waits its turn (FR-INP-6)."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "first")
    (ecc-prompt-test--in-buffer session
      (insert "second")
      (ecc-prompt-send))
    (should (equal (ecc-session-input-queue session) '("second")))
    ;; Nothing left the client: only the first prompt is in flight.
    (should-not (ecc-test-sent-messages))
    (ecc-dispatch session '((type . "result") (subtype . "success")))
    (should-not (ecc-session-input-queue session))
    (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "second"))))

(ert-deftest ecc-prompt-test-slash-commands-go-through ()
  "A slash command is sent as ordinary text (FR-INP-2)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--in-buffer session
      (insert "/context")
      (ecc-prompt-send))
    (should (equal (alist-get 'content
                              (alist-get 'message (car (ecc-test-sent-messages))))
                   "/context"))))

(ert-deftest ecc-prompt-test-completion ()
  "Completion offers the commands of the initialize answer (FR-INP-3)."
  (ecc-test-with-fake-session session
    (setf (ecc-session-commands session)
          [((name . "context") (description . "Show context usage")
            (argumentHint . ""))
           ((name . "compact") (description . "Compact the conversation")
            (argumentHint . "[instructions]"))])
    (setf (ecc-session-init session) '((slash_commands . ["context" "review"])))
    (ecc-prompt-test--in-buffer session
      (insert "/co")
      (let ((capf (ecc-prompt-capf)))
        (should capf)
        (should (= (nth 0 capf) (line-beginning-position)))
        (should (= (nth 1 capf) (point)))
        (should (member "/context" (nth 2 capf)))
        (should (member "/compact" (nth 2 capf)))
        ;; A command only system/init knows about is offered too.
        (should (member "/review" (nth 2 capf)))
        ;; The description is what the completion user interface shows.
        (should (string-search "Show context usage"
                               (funcall (plist-get (nthcdr 3 capf)
                                                   :annotation-function)
                                        "/context")))
        (should (string-search "[instructions]"
                               (funcall (plist-get (nthcdr 3 capf)
                                                   :annotation-function)
                                        "/compact"))))
      ;; Only the first word of a slash line is a command.
      (insert " and more")
      (should-not (ecc-prompt-capf))
      (ecc-prompt-clear)
      (insert "hello")
      (should-not (ecc-prompt-capf))
      ;; Nothing is completed in the transcript (FR-INP-3).
      (goto-char (point-min))
      (should-not (ecc-prompt-capf)))))

(defmacro ecc-prompt-test--reading-command (answer asked &rest body)
  "Run BODY with `completing-read' answering ANSWER.
ASKED is bound to a list the candidates offered and the prompt are
pushed onto, newest first.  ANSWER may be the symbol `quit', which
stands for the user pressing \\[keyboard-quit]."
  (declare (indent 2))
  `(let ((,asked nil))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (prompt collection &rest _)
                  (push (cons prompt (all-completions "" collection)) ,asked)
                  (if (eq ,answer 'quit) (signal 'quit nil) ,answer))))
       ,@body)))

(ert-deftest ecc-prompt-test-slash-offers-the-commands ()
  "The slash the prompt opens with asks which command (FR-INP-3)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--init session)
    (ecc-prompt-test--in-buffer session
      (ecc-prompt-test--reading-command "/context" asked
        (ecc-chat-slash 1)
        (should (equal (ecc-chat-draft) "/context"))
        (should (member "/context" (cdar asked)))
        ;; system/init names /model and nothing else does; it is offered.
        (should (member "/model" (cdar asked)))))))

(ert-deftest ecc-prompt-test-slash-in-prose-is-a-slash ()
  "Only the slash the prompt opens with asks (FR-INP-2, FR-INP-3).
The CLI runs a command written at the start of what it is sent and
nowhere else (`ecc-prompt-command-name\='), so a slash further in is
not offered commands that would not run."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--init session)
    (ecc-prompt-test--in-buffer session
      (insert "see src")
      (ecc-prompt-test--reading-command "/context" asked
        (ecc-chat-slash 1)
        (should-not asked)
        (should (equal (ecc-chat-draft) "see src/"))
        ;; Nor does the start of the second line: what is sent starts
        ;; with `see', so nothing in it is a command.
        (insert "\n")
        (ecc-chat-slash 1)
        (should-not asked)
        (should (equal (ecc-chat-draft) "see src/\n/")))
      (ecc-prompt-clear)
      ;; Blanks before it are all the CLI allows, and all Emacs does.
      (insert "  ")
      (ecc-prompt-test--reading-command "/context" asked
        (ecc-chat-slash 1)
        (should asked)
        (should (equal (ecc-chat-draft) "  /context"))))))

(ert-deftest ecc-prompt-test-completion-follows-a-word-anywhere ()
  "TAB completes a word that starts with a slash wherever it stands.
The terminal client does the same, with a dim suggestion inside the
input rather than a list (docs/verified.md, 2026-09-09); it leaves a
slash inside a word -- a path, a URL -- alone."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--init session)
    (ecc-prompt-test--in-buffer session
      (insert "please run /co")
      (let ((capf (ecc-prompt-capf)))
        (should capf)
        (should (equal (buffer-substring-no-properties (nth 0 capf) (nth 1 capf))
                       "/co"))
        (should (member "/context" (nth 2 capf))))
      ;; A slash inside a word is part of the word.
      (ecc-prompt-clear)
      (insert "see src/fo")
      (should-not (ecc-prompt-capf))
      (ecc-prompt-clear)
      (insert "run a/co")
      (should-not (ecc-prompt-capf))
      ;; The line before it makes no difference.
      (ecc-prompt-clear)
      (insert "first line\n/co")
      (should (ecc-prompt-capf)))))

(ert-deftest ecc-prompt-test-slash-quit-keeps-the-slash ()
  "Leaving the question keeps what was typed (FR-INP-3)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--init session)
    (ecc-prompt-test--in-buffer session
      (ecc-prompt-test--reading-command 'quit asked
        (ecc-chat-slash 1)
        (should asked)
        (should (equal (ecc-chat-draft) "/")))
      (ecc-prompt-clear)
      ;; An empty answer is no answer either.
      (ecc-prompt-test--reading-command "" asked
        (ecc-chat-slash 1)
        (should (equal (ecc-chat-draft) "/"))))))

(ert-deftest ecc-prompt-test-slash-question-can-be-turned-off ()
  "With the setting off a slash is only a slash (FR-INP-3)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--init session)
    (ecc-prompt-test--in-buffer session
      (let ((ecc-prompt-slash-reads-command nil))
        (ecc-prompt-test--reading-command "/context" asked
          (ecc-chat-slash 1)
          (should-not asked)
          (should (equal (ecc-chat-draft) "/"))))
      ;; TAB completion is there either way.
      (should (ecc-prompt-capf)))))

(ert-deftest ecc-prompt-test-slash-question-annotates-as-completion-does ()
  "The question shows what the completion shows (FR-INP-3, FR-INP-4)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--init session)
    (ecc-prompt-note-terminal-commands session)
    (let ((annotate nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq annotate (cdr (assq 'annotation-function
                                             (cdr (funcall collection "" nil 'metadata)))))
                   nil)))
        (ecc-prompt-read-command session))
      (should (string-search "terminal UI" (funcall annotate "/doctor")))
      (should (string-search "Show context usage" (funcall annotate "/context"))))))


;;;; Terminal only and interactive slash commands (FR-INP-4, FR-INP-5)

(defun ecc-prompt-test--init (session)
  "Give SESSION the command lists a system/init message carries."
  (setf (ecc-session-commands session)
        [((name . "context") (description . "Show context usage") (argumentHint . ""))
         ((name . "doctor") (description . "Check the installation") (argumentHint . ""))])
  (setf (ecc-session-init session)
        '((slash_commands . ["context" "doctor" "model"])
          (terminal_slash_commands . ["doctor" "color"]))))

(ert-deftest ecc-prompt-test-terminal-commands ()
  "A command only the terminal client runs says so (FR-INP-4)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--init session)
    (ecc-prompt-note-terminal-commands session)
    (should (equal (ecc-prompt-terminal-commands session) '("/doctor" "/color")))
    (ecc-prompt-test--in-buffer session
      (insert "/do")
      (let* ((capf (ecc-prompt-capf))
             (annotate (plist-get (nthcdr 3 capf) :annotation-function)))
        (should (string-search "terminal UI" (funcall annotate "/doctor")))
        (should-not (string-search "terminal UI" (funcall annotate "/context")))))
    ;; It is still sent: the CLI answers it with a message of its own.
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (should (equal (ecc-prompt-prepare-command session "/doctor") "/doctor")))
      (should (string-search "terminal UI" (car (last messages)))))))

(ert-deftest ecc-prompt-test-terminal-commands-before-init ()
  "The annotation is there before the first turn, too (FR-INP-4).
system/init does not arrive until a prompt has been sent, so a session
that has not spoken yet falls back to what the CLI said last, and
failing that to the setting."
  (ecc-test-with-fake-session session
    (let ((ecc-prompt--terminal-commands nil)
          (ecc-terminal-slash-commands '("doctor" "color")))
      (should-not (ecc-session-init session))
      (should (equal (ecc-prompt-terminal-commands session) '("/doctor" "/color")))
      ;; What a session was told replaces the fallback everywhere.
      (setf (ecc-session-init session)
            '((terminal_slash_commands . ["doctor" "color" "reload-plugins"])))
      (ecc-dispatch session '((type . "system") (subtype . "init")
                              (terminal_slash_commands . ["doctor" "color" "reload-plugins"])))
      (should (equal ecc-prompt--terminal-commands
                     '("doctor" "color" "reload-plugins")))
      (ecc-test-with-fake-session fresh
        (should (equal (ecc-prompt-terminal-commands fresh)
                       '("/doctor" "/color" "/reload-plugins")))))))

(defconst ecc-prompt-test--models
  [((value . "default") (resolvedModel . "claude-sonnet-5")
    (displayName . "Default (recommended)")
    (description . "Sonnet 5 \u00b7 Efficient for routine tasks"))
   ((value . "opus") (resolvedModel . "claude-opus-5")
    (displayName . "Opus")
    (description . "Opus 5 \u00b7 Best for everyday, complex tasks"))
   ((value . "haiku") (resolvedModel . "claude-haiku-4-5-20251001")
    (displayName . "Haiku")
    (description . "Haiku 4.5 \u00b7 Fastest for quick answers"))]
  "The `models' array of an initialize response, cut down.")

(ert-deftest ecc-prompt-test-models-come-from-the-initialize-answer ()
  "/model offers what the CLI says it may be given (FR-INP-5)."
  (ecc-test-with-fake-session session
    ;; Until the answer arrives there is only the setting.
    (let ((ecc-model-candidates '("default" "opus")))
      (should (equal (ecc-prompt-model-candidates session) '("default" "opus"))))
    (ecc-dispatch session
                  `((type . "control_response")
                    (response . ((subtype . "success")
                                 (request_id . "r1")
                                 (response . ((models . ,ecc-prompt-test--models)))))))
    (should (equal (ecc-session-models session) ecc-prompt-test--models))
    (should (equal (ecc-prompt-model-candidates session)
                   '("default" "opus" "haiku")))
    (should (string-search "Opus 5"
                           (cdr (assoc "opus" (ecc-prompt-models session)))))))

(ert-deftest ecc-prompt-test-model-command-names-the-model-in-use ()
  "The annotation of /model says which model the session is on.
The terminal client adds this; the description the CLI sends is fixed
text (docs/verified.md)."
  (ecc-test-with-fake-session session
    (setf (ecc-session-models session) ecc-prompt-test--models
          (ecc-session-commands session)
          [((name . "model") (description . "Set the AI model for Claude Code")
            (argumentHint . "<model>"))])
    ;; Nothing is known about the model before the first answer.
    (should-not (ecc-prompt-current-model session))
    (should-not (string-search "currently"
                               (cdr (assoc "/model" (ecc-prompt-commands session)))))
    ;; The id of an assistant message is resolved to the display name,
    ;; and `default', which resolves to the same id, does not answer for it.
    (setf (ecc-session-last-model session) "claude-opus-5")
    (should (equal (ecc-prompt-current-model session) "Opus"))
    (setf (ecc-session-last-model session) "claude-sonnet-5")
    (should (equal (ecc-prompt-current-model session) "claude-sonnet-5"))
    ;; What was sent to /model is a value of the array and matches outright.
    (setf (ecc-session-last-model session) "haiku")
    (should (equal (ecc-prompt-current-model session) "Haiku"))
    (ecc-prompt-test--in-buffer session
      (insert "/mo")
      (let* ((capf (ecc-prompt-capf))
             (annotate (plist-get (nthcdr 3 capf) :annotation-function)))
        (should (string-search "(currently Haiku)" (funcall annotate "/model")))))
    ;; A model the array does not name stands in for itself.
    (setf (ecc-session-models session) nil
          (ecc-session-last-model session) "claude-opus-5")
    (should (equal (ecc-prompt-current-model session) "claude-opus-5"))))

(ert-deftest ecc-prompt-test-effort-levels-come-from-the-argument-hint ()
  "/effort offers the levels the CLI spells out in its hint (FR-INP-5).
The hint is the only place the set of levels appears: the models array
says which models take an effort at all, but not that `auto' is one of
the answers (verified on 2026-09-09, CLI 2.1.265)."
  (ecc-test-with-fake-session session
    (let ((ecc-effort-candidates '("low" "high")))
      ;; Until the answer arrives there is only the setting.
      (should (equal (ecc-prompt-effort-candidates session) '("low" "high")))
      (setf (ecc-session-commands session)
            [((name . "effort") (description . "Set effort level for model usage")
              (argumentHint . "<low|medium|high|xhigh|max|auto>"))
             ((name . "config") (description . "Set a setting by key")
              (argumentHint . "key=value"))
             ((name . "loop") (description . "Run a prompt on an interval")
              (argumentHint . "[interval] [prompt]"))
             ((name . "model") (description . "Set the AI model for Claude Code")
              (argumentHint . "<model>"))])
      (should (equal (ecc-prompt-effort-candidates session)
                     '("low" "medium" "high" "xhigh" "max" "auto")))
      ;; A hint that is a placeholder rather than a list of alternatives
      ;; has nothing to offer.
      (should-not (ecc-prompt-argument-candidates session "/config"))
      (should-not (ecc-prompt-argument-candidates session "/loop"))
      (should-not (ecc-prompt-argument-candidates session "/model"))
      (should-not (ecc-prompt-argument-candidates session "/nonesuch")))))

(ert-deftest ecc-prompt-test-every-command-with-alternatives-is-offered-them ()
  "A command whose hint names its arguments is asked about (FR-INP-5).
The hints are the ones CLI 2.1.265 really sends (docs/verified.md)."
  (ecc-test-with-fake-session session
    (setf (ecc-session-commands session)
          [((name . "fast") (argumentHint . "[on|off]"))
           ((name . "design") (argumentHint . "consent | revoke"))
           ((name . "color") (argumentHint . "[red|blue|default]"))
           ;; A placeholder among the alternatives is not a set of them.
           ((name . "autocompact") (argumentHint . "[auto|<tokens>]"))
           ;; Nor is a second argument, or a flag.
           ((name . "mcp") (argumentHint . "[reconnect|enable|disable [<server>|all]]"))
           ((name . "code-review")
            (argumentHint . "[low|medium|max|ultra] [--fix] [<pr#>|<branch>]"))
           ;; Nor one placeholder on its own.
           ((name . "compact") (argumentHint . "<optional custom instructions>"))
           ((name . "clear") (argumentHint . "[name]"))
           ((name . "context") (argumentHint . ""))])
    (should (equal (ecc-prompt-command-candidates session "/fast") '("on" "off")))
    (should (equal (ecc-prompt-command-candidates session "/design")
                   '("consent" "revoke")))
    (should (equal (ecc-prompt-command-candidates session "/color")
                   '("red" "blue" "default")))
    (dolist (command '("/autocompact" "/mcp" "/code-review" "/compact" "/clear"
                       "/context" "/nonesuch"))
      (should-not (ecc-prompt-argument-candidates session command))
      (should-not (ecc-prompt-interactive-command-p session command)))
    ;; Being offered them means being asked before the command goes out,
    ;; without an entry in `ecc-prompt-interactive-commands'.
    (should-not (assoc "/fast" ecc-prompt-interactive-commands))
    (should (ecc-prompt-interactive-command-p session "/fast"))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "on")))
      (should (equal (ecc-prompt-prepare-command session "/fast") "/fast on")))
    ;; system/init says what /fast is set to, so the annotation can too.
    (setf (ecc-session-init session) '((fast_mode_state . "off")))
    (should (equal (ecc-prompt-current-argument session "/fast") "off"))))

(ert-deftest ecc-prompt-test-effort-command-names-the-level-in-use ()
  "The annotation of /effort says which level the session is on.
Nothing in the stream reports one, so what was sent from here is what
is known (docs/verified.md)."
  (ecc-test-with-fake-session session
    (setf (ecc-session-commands session)
          [((name . "effort") (description . "Set effort level for model usage")
            (argumentHint . "<low|medium|high|xhigh|max|auto>"))])
    (let ((ecc-effort nil))
      (should-not (ecc-prompt-current-effort session))
      (should-not (string-search "currently"
                                 (cdr (assoc "/effort" (ecc-prompt-commands session)))))
      ;; The --effort the session was started with counts.
      (setf (ecc-session-options session) '(:effort "high"))
      (should (equal (ecc-prompt-current-effort session) "high"))
      ;; Sending an /effort replaces it; the CLI never says so itself.
      (ecc-proc-send-user session "/effort xhigh")
      (should (equal (ecc-session-last-effort session) "xhigh"))
      (should (string-search "(currently xhigh)"
                             (cdr (assoc "/effort" (ecc-prompt-commands session)))))
      ;; An /effort that asks rather than tells is left alone.
      (ecc-proc-send-user session "/effort")
      (should (equal (ecc-session-last-effort session) "xhigh")))))

(ert-deftest ecc-prompt-test-interactive-command-asks-for-its-argument ()
  "A command that opens a menu in the terminal is asked about (FR-INP-5)."
  (ecc-test-with-fake-session session
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "opus")))
      (should (equal (ecc-prompt-prepare-command session "/model") "/model opus"))
      ;; An argument that is already there is left alone.
      (should (equal (ecc-prompt-prepare-command session "/model sonnet")
                     "/model sonnet"))
      ;; So is an ordinary command.
      (should (equal (ecc-prompt-prepare-command session "/context") "/context"))
      (should (equal (ecc-prompt-prepare-command session "hello") "hello")))
    ;; An empty answer sends the command as it was typed.
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should (equal (ecc-prompt-prepare-command session "/model") "/model")))))

;;;; History (FR-INP-7)

(ert-deftest ecc-prompt-test-history ()
  "Sending fills the history, which is walked with M-p and M-n (FR-INP-7)."
  (ecc-test-with-fake-session session
    (let ((ecc-prompt-history nil))
      (ecc-prompt-test--in-buffer session
        (insert "first")
        (ecc-prompt-send)
        (ecc-dispatch session '((type . "result") (subtype . "success")))
        (insert "second")
        (ecc-prompt-send)
        (ecc-dispatch session '((type . "result") (subtype . "success")))
        (should (equal ecc-prompt-history '("second" "first")))
        ;; What is being written is kept and comes back at the end.
        (insert "draft")
        (ecc-prompt-history-previous)
        (should (equal (string-trim (ecc-chat-draft)) "second"))
        (ecc-prompt-history-previous)
        (should (equal (string-trim (ecc-chat-draft)) "first"))
        ;; The oldest entry is as far back as it goes.
        (ecc-prompt-history-previous)
        (should (equal (string-trim (ecc-chat-draft)) "first"))
        (ecc-prompt-history-next)
        (should (equal (string-trim (ecc-chat-draft)) "second"))
        (ecc-prompt-history-next)
        (should (equal (string-trim (ecc-chat-draft)) "draft"))
        ;; The transcript above is untouched by the walk.
        (ecc-render-flush session)
        (should (string-search "〉 first" (buffer-string)))
        (should (equal (string-trim (ecc-chat-draft)) "draft"))
        (should-error (ecc-prompt-history-next) :type 'user-error)))))

(ert-deftest ecc-prompt-test-history-is-deduplicated-and-capped ()
  "The same prompt twice is one entry, and the history has an end."
  (let ((ecc-prompt-history nil)
        (ecc-prompt-history-size 2))
    (ecc-prompt-history-add "a")
    (ecc-prompt-history-add "b")
    (ecc-prompt-history-add "a")
    (should (equal ecc-prompt-history '("a" "b")))
    (ecc-prompt-history-add "c")
    (should (equal ecc-prompt-history '("c" "a")))
    (ecc-prompt-history-add "   ")
    (should (equal ecc-prompt-history '("c" "a")))))

(ert-deftest ecc-prompt-test-resend-last ()
  "The last prompt can be sent again without retyping it (FR-INP-7)."
  (ecc-test-with-fake-session session
    (let ((ecc-prompt-history '("do it again")))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (ecc-prompt-test--in-buffer session (ecc-prompt-resend-last)))
      (should (equal (alist-get 'content
                                (alist-get 'message (car (ecc-test-sent-messages))))
                     "do it again")))))

;;;; The @ references (FR-INP-8)

(ert-deftest ecc-prompt-test-split-reference ()
  "A line range is told from a path, and a full stop is not part of one."
  (should (equal (ecc-prompt-split-reference "@src/a.py") '("src/a.py" nil nil)))
  (should (equal (ecc-prompt-split-reference "@src/a.py:10-40")
                 '("src/a.py" 10 40)))
  (should (equal (ecc-prompt-split-reference "@region") '("region" nil nil)))
  (should (equal (ecc-prompt-split-reference "@src/a.py.") '("src/a.py" nil nil))))

(ert-deftest ecc-prompt-test-next-reference-stops-at-a-special ()
  "A special reference ends at its name when a letter follows (FR-INP-8)."
  (should (equal (ecc-prompt--next-reference "\u6b21\u306e@region\u306f\u3069\u3046\u3067\u3059\u304b\uff1f" 0)
                 (list 2 9 "@region")))
  (should (equal (nth 2 (ecc-prompt--next-reference "@diagnostics\u3092\u898b\u3066" 0))
                 "@diagnostics"))
  (should (equal (nth 2 (ecc-prompt--next-reference "\u8aac\u660e\u3057\u3066 @region" 0)) "@region"))
  ;; A path that only begins like one is still a path.
  (should (equal (nth 2 (ecc-prompt--next-reference "@regions/list.py \u3092" 0))
                 "@regions/list.py")))

(ert-deftest ecc-prompt-test-expand-region-before-a-particle ()
  "@region is expanded with a Japanese particle straight after it."
  (let ((source (get-buffer-create "ecc-prompt-test-particle")))
    (unwind-protect
        (with-current-buffer source
          (insert "a = 1\n")
          (setq-local major-mode 'python-mode)
          (transient-mark-mode 1)
          (goto-char (point-min))
          (push-mark (point-max) t t)
          (let ((text (ecc-prompt-expand-references "\u6b21\u306e@region\u306f\u3069\u3046\u3067\u3059\u304b\uff1f" source)))
            (should-not (string-search "@region" text))
            (should (string-search "\u306f\u3069\u3046\u3067\u3059\u304b\uff1f" text))
            (should (string-search "```python\na = 1\n```" text))
            (should (equal (length ecc-prompt-last-attachments) 1))
            (should-not ecc-prompt-last-skipped)))
      (kill-buffer source))))

(ert-deftest ecc-prompt-test-region-survives-a-dead-mark ()
  "@region falls back on the snapshot when the mark has been deactivated."
  (let ((source (get-buffer-create "ecc-prompt-test-snapshot"))
        (ecc-window--last-source-buffer nil)
        (ecc-window--last-region nil))
    (unwind-protect
        (with-current-buffer source
          (insert "a = 1\n")
          (setq-local major-mode 'python-mode)
          (transient-mark-mode 1)
          (goto-char (point-min))
          (push-mark (point-max) t t)
          ;; Leaving the buffer takes the region down while it lives.
          (setq ecc-window--last-source-buffer source)
          (ecc-window-snapshot-region)
          (deactivate-mark)
          (should-not (ecc-window-buffer-region source))
          (let ((text (ecc-prompt-expand-references "@region" source)))
            (should (string-search "```python\na = 1\n```" text))
            (should-not ecc-prompt-last-skipped)))
      (kill-buffer source))))

(defun ecc-prompt-test--count (needle text)
  "Return how often NEEDLE occurs in TEXT."
  (let ((count 0) (index 0))
    (while (setq index (string-search needle text index))
      (setq count (1+ count) index (+ index (length needle))))
    count))

(ert-deftest ecc-prompt-test-one-block-for-two-references ()
  "Two @region in a sentence are labelled twice and quoted once."
  (let ((source (get-buffer-create "ecc-prompt-test-twice")))
    (unwind-protect
        (with-current-buffer source
          (insert "a = 1\n")
          (setq-local major-mode 'python-mode)
          (transient-mark-mode 1)
          (goto-char (point-min))
          (push-mark (point-max) t t)
          (let* ((text (ecc-prompt-expand-references "@region\u3060\u306d\n\n@region" source))
                 (label (car ecc-prompt-last-attachments)))
            (should (equal (length ecc-prompt-last-attachments) 1))
            ;; Twice where they were written, and once over the block.
            (should (equal 3 (ecc-prompt-test--count label text)))
            (should (equal 1 (ecc-prompt-test--count "```python" text)))))
      (kill-buffer source))))

(ert-deftest ecc-prompt-test-expand-cursor ()
  "@cursor quotes the line the cursor is on and its neighbours."
  (let ((source (get-buffer-create "ecc-prompt-test-cursor"))
        (ecc-context-cursor-lines 1))
    (unwind-protect
        (with-current-buffer source
          (insert "one\ntwo\nthree\nfour\nfive\n")
          (setq-local major-mode 'python-mode)
          (goto-char (point-min))
          (forward-line 2)
          (let ((text (ecc-prompt-expand-references "\u3053\u3053@cursor\u306f\uff1f" source)))
            (should (string-search "```python\ntwo\nthree\nfour\n```" text))
            ;; The label points at the cursor, not at the lines around it.
            (should (string-search "L3" text))
            (should-not (string-search "L2-L4" text))
            (should-not (string-search "@cursor" text))))
      (kill-buffer source))))

(ert-deftest ecc-prompt-test-path-outside-the-session-root ()
  "A file outside the project of the session is labelled in full."
  (let* ((root (file-name-as-directory (make-temp-file "ecc-root" t)))
         (other (make-temp-file "ecc-other" nil ".py" "a = 1\n"))
         (buffer (find-file-noselect other)))
    (unwind-protect
        (with-current-buffer buffer
          (transient-mark-mode 1)
          (goto-char (point-min))
          (push-mark (point-max) t t)
          ;; Relative to its own project the file is a bare name, which
          ;; the CLI would resolve from the root of the session instead.
          (let ((here (ecc-prompt-expand-references "@region" buffer))
                (there (ecc-prompt-expand-references "@region" buffer root)))
            (should (string-search (abbreviate-file-name other) there))
            (should-not (equal here there))))
      (kill-buffer buffer)
      (delete-file other)
      (delete-directory root t))))

(ert-deftest ecc-prompt-test-cursor-without-a-tracked-source ()
  "@cursor reads a buffer on the screen when nothing was tracked."
  (let ((source (get-buffer-create "ecc-prompt-test-untracked"))
        ;; A prompt is sent from a buffer of this package, so the
        ;; current one is no help; nothing was ever tracked either.
        (own (get-buffer-create "*ecc-prompt-test-own*"))
        (ecc-window--last-source-buffer nil)
        (ecc-window--last-region nil)
        (ecc-context-cursor-lines 0))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "one\ntwo\nthree\n")
            (setq-local major-mode 'python-mode)
            (goto-char (point-min))
            (forward-line 1))
          (set-window-buffer (selected-window) source)
          (with-current-buffer own
            ;; The buffer comes from the frame instead.
            (should (eq (ecc-window-context-buffer) source))
            (let ((text (ecc-prompt-expand-references "@cursor" nil)))
              (should (string-search "```python\ntwo\n```" text))
              (should-not ecc-prompt-last-skipped))))
      (kill-buffer source)
      (kill-buffer own))))

(ert-deftest ecc-prompt-test-skipped-special-is-noted ()
  "A @region with no region is left alone and noted (FR-INP-8)."
  (let ((source (get-buffer-create "ecc-prompt-test-skipped")))
    (unwind-protect
        (with-current-buffer source
          (insert "a = 1\n")
          (deactivate-mark)
          (should (equal (ecc-prompt-expand-references "@region\u3092" source) "@region\u3092"))
          (should (equal ecc-prompt-last-skipped '("@region")))
          (should-not ecc-prompt-last-attachments)
          (should (string-search "nothing to send" (ecc-prompt--attachment-report))))
      (kill-buffer source))))

(ert-deftest ecc-prompt-test-plain-path-is-left-to-the-cli ()
  "A bare @path is the CLI's own reference and is not expanded (FR-INP-8)."
  (should (equal (ecc-prompt-expand-references "look at @src/a.py please")
                 "look at @src/a.py please")))

(ert-deftest ecc-prompt-test-expand-file-range ()
  "A line range is read out and quoted under a short label (FR-INP-8)."
  (let ((file (make-temp-file "ecc-prompt" nil ".py" "1\n2\n3\n4\n5\n")))
    (unwind-protect
        (let* ((default-directory (file-name-directory file))
               (name (file-name-nondirectory file))
               (text (ecc-prompt-expand-references (format "@%s:2-3 を直して" name))))
          (should (string-prefix-p (format "`%s` L2-L3 を直して" name) text))
          (should (string-search "```python\n2\n3\n```" text)))
      (delete-file file))))

(ert-deftest ecc-prompt-test-expand-region-and-diagnostics ()
  "@region and @diagnostics are read from the buffer the user came from."
  (let ((source (get-buffer-create "ecc-prompt-test-source")))
    (unwind-protect
        (with-current-buffer source
          (insert "a = 1\nb = 2\n")
          (setq-local major-mode 'python-mode)
          (transient-mark-mode 1)
          (goto-char (point-min))
          (push-mark (point-max) t t)
          (let ((text (ecc-prompt-expand-references "説明して @region" source)))
            (should (string-search "```python\na = 1\nb = 2\n```" text))
            (should-not (string-search "@region" text)))
          (deactivate-mark)
          ;; Without a region there is nothing to quote, so the token stays.
          (should (equal (ecc-prompt-expand-references "@region" source) "@region"))
          (cl-letf (((symbol-function 'flymake-diagnostics) (lambda (&rest _) '(d)))
                    ((symbol-function 'flymake-diagnostic-beg) (lambda (_) 1))
                    ((symbol-function 'flymake-diagnostic-text) (lambda (_) "bad")))
            (let ((text (ecc-prompt-expand-references "直して @diagnostics" source)))
              (should (string-search "L1: bad" text))
              (should (string-search "Diagnostics: " text)))))
      (kill-buffer source))))

(ert-deftest ecc-prompt-test-at-completion ()
  "The @ completion offers the files of the project and the two words."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--in-buffer session
      (insert "見て @re")
      (let* ((capf (ecc-prompt-at-capf))
             (candidates (all-completions "@re" (nth 2 capf))))
        (should (= (nth 0 capf) (- (point) 3)))
        (should (member "@region" candidates))
        (should (string-search "Send the region"
                               (funcall (plist-get (nthcdr 3 capf)
                                                   :annotation-function)
                                        "@region")))))))

;;;; Images (FR-INP-9)

(ert-deftest ecc-prompt-test-pasted-image-becomes-a-path ()
  "A pasted image is written to a file and referred to by path (FR-INP-9)."
  (ecc-test-with-fake-session session
    (let ((ecc-image-dir (make-temp-file "ecc-images" t)))
      (unwind-protect
          (ecc-prompt-test--in-buffer session
            (insert "これは")
            (let ((file (ecc-prompt-yank-image "image/png" "\x89PNG-data")))
              (should (file-exists-p file))
              (should (equal (file-name-extension file) "png"))
              (should (string-prefix-p (expand-file-name (ecc-session-id session)
                                                         ecc-image-dir)
                                       file))
              ;; The prompt refers to it; no base64 goes into the recording.
              (should (equal (ecc-chat-draft) (format "これは @%s " file)))
              (should-not (string-search "PNG-data" (buffer-string)))
              ;; jpeg keeps the extension the CLI expects.
              (should (equal (file-name-extension
                              (ecc-prompt-save-image session "x" "image/jpeg"))
                             "jpg"))
              (should (ecc-image-cleanup-session session))
              (should-not (file-exists-p file))))
        (when (file-directory-p ecc-image-dir)
          (delete-directory ecc-image-dir t))))))

(ert-deftest ecc-prompt-test-images-can-be-kept ()
  "With cleanup off the files outlive the session (FR-INP-9)."
  (ecc-test-with-fake-session session
    (let ((ecc-image-dir (make-temp-file "ecc-images" t))
          (ecc-image-cleanup 'never))
      (unwind-protect
          (let ((file (ecc-prompt-save-image session "x" "image/png")))
            (should-not (ecc-image-cleanup-session session))
            (should (file-exists-p file)))
        (delete-directory ecc-image-dir t)))))

;;;; The editor context (FR-CTX-1)

(ert-deftest ecc-prompt-test-context-toggle ()
  "The context is attached only when the buffer was told to (FR-CTX-1)."
  (ecc-test-with-fake-session session
    (let ((source (get-buffer-create "ecc-prompt-test-context")))
      (unwind-protect
          (progn
            (with-current-buffer source (insert "a = 1\n"))
            (cl-letf (((symbol-function 'ecc-window-last-source-buffer)
                       (lambda () source)))
              (ecc-prompt-test--in-buffer session
                (insert "これは何?")
                (ecc-prompt-send)
                (should-not (string-search "Current context"
                                           (ecc-test-sent-text 0)))
                (ecc-dispatch session '((type . "result") (subtype . "success")))
                (ecc-prompt-toggle-context)
                (should ecc-prompt--attach-context)
                (insert "これは何?")
                (ecc-prompt-send)
                (should (string-search "Current context"
                                       (ecc-test-sent-text 1))))))
        (kill-buffer source)))))


(provide 'ecc-prompt-test)

;;; ecc-prompt-test.el ends here
