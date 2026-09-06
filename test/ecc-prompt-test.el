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
        (should (string-search "Turn 1  first" (buffer-string)))
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
