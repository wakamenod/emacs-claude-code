;;; ecc-review-talk-test.el --- Tests for ecc-review-talk  -*- lexical-binding: t; -*-

;;; Commentary:

;; T, t and M in both kinds of review, the reply pane of an ediff review
;; and answering from it.  The ediff review runs against a throwaway
;; repository with `ediff-setup-windows-plain', which works in batch;
;; what Claude says is put into the model the way `ecc-dispatch' puts
;; it, through the model's own functions, so the hooks the pane follows
;; are the ones a live session runs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-talk)
(require 'ecc-session)

;;;; Helpers

(defconst ecc-review-talk-test--diff
  "diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
"
  "A diff of one changed line.")

(defvar ecc-review-talk-test--sent nil
  "(SESSION . OBJECT) for each message sent, most recent first.")

(defmacro ecc-review-talk-test--with-sessions (one two &rest body)
  "Run BODY with ONE and TWO two sessions that have MCP and no process.
What each sends is in `ecc-review-talk-test--sent', with the session."
  (declare (indent 2))
  `(ecc-test-with-fake-session ,one
     (let ((,two (ecc-model-create-session :name "two"
                                           :project-root temporary-file-directory))
           (ecc-review-talk-test--sent nil)
           (ecc-mcp-enabled t))
       (unwind-protect
           (cl-letf (((symbol-function #'ecc-proc-send-json)
                      (lambda (session object)
                        (push (cons session object) ecc-review-talk-test--sent)
                        object)))
             ,@body)
         (ecc-test-cleanup-session ,two)
         (ecc-review-talk-test--kill-buffers)))))

(defun ecc-review-talk-test--kill-buffers ()
  "Kill every buffer a review left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defun ecc-review-talk-test--prompts (session)
  "Return the prompts SESSION sent, oldest first."
  (delq nil (mapcar (lambda (entry)
                      (when (eq (car entry) session)
                        (alist-get 'content (alist-get 'message (cdr entry)))))
                    (reverse ecc-review-talk-test--sent))))

(defun ecc-review-talk-test--responses (session)
  "Return the control responses SESSION sent, oldest first."
  (delq nil (mapcar (lambda (entry)
                      (when (eq (car entry) session)
                        (alist-get 'response (alist-get 'response (cdr entry)))))
                    (reverse ecc-review-talk-test--sent))))

(defun ecc-review-talk-test--diff-review (session)
  "Return a diff review of SESSION, filled with a diff of one line."
  (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                    session ecc-review-talk-test--diff temporary-file-directory))

(defun ecc-review-talk-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-talk-test--ediff (session directory)
  "Open the ediff review of a.txt, which SESSION changed in DIRECTORY."
  (ecc-review-talk-test--git directory "init" "-q")
  (ecc-review-talk-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-talk-test--git directory "config" "user.name" "t")
  (with-temp-file (concat directory "a.txt") (insert "one\ntwo\nthree\n"))
  (ecc-review-talk-test--git directory "add" ".")
  (ecc-review-talk-test--git directory "commit" "-q" "-m" "init")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (with-temp-file (concat directory "a.txt") (insert "one\nTWO\nthree\n"))
  (ecc-review-ediff-buffer session))

(defmacro ecc-review-talk-test--with-ediff (session control &rest body)
  "Run BODY in CONTROL, the ediff review of one file of SESSION."
  (declare (indent 2))
  `(let ((directory (file-name-as-directory (make-temp-file "ecc-review-talk" t)))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (,control nil))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (setq ,control (ecc-review-talk-test--ediff ,session directory))
           (with-current-buffer ,control
             ,@body))
       (when (buffer-live-p ,control)
         (ecc-review-ediff-quit ,control))
       (delete-directory directory t))))

(defun ecc-review-talk-test--pane (control)
  "Return the reply pane of the review CONTROL."
  (buffer-local-value 'ecc-review-talk--pane control))

(defun ecc-review-talk-test--pane-text (control)
  "Return the text of the reply pane of the review CONTROL."
  (with-current-buffer (ecc-review-talk-test--pane control)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ecc-review-talk-test--say (session text &optional pieces)
  "Have SESSION say TEXT in a turn of its own, streamed in PIECES when given.
Return the text node."
  (let ((node (ecc-model-add-node session :type 'text :status 'running
                                  :data (list (cons 'text "")))))
    (ecc-model-open-stream session nil 0 node)
    (dolist (piece (or pieces (list text)))
      (ecc-model-append-stream session node piece))
    node))

(defun ecc-review-talk-test--finish-text (session node text)
  "Close the stream of NODE of SESSION with its final TEXT."
  (setf (ecc-node-data node) (list (cons 'text text))
        (ecc-node-status node) 'done)
  (ecc-model-forget-stream-text node)
  (ecc-model-close-stream session node)
  (ecc-model-node-changed session node))

(defun ecc-review-talk-test--call (session name input &optional status)
  "Have SESSION call the tool NAME with INPUT; leave it with STATUS."
  (let ((node (ecc-dispatch--new-tool session (format "toolu_%s" (random 100000)) name
                                      (ecc-model-ensure-turn session))))
    (ecc-model-node-put node 'input input)
    (setf (ecc-node-status node) (or status 'done))
    (ecc-model-node-changed session node)
    node))

;;;; The keys

(ert-deftest ecc-review-talk-test-keys-of-the-diff-review ()
  "T, t and M talk to Claude in a diff review, and N is still the next file."
  (ecc-review-talk-test--with-sessions one _two
    (with-current-buffer (ecc-review-talk-test--diff-review one)
      (should (eq (key-binding (kbd "T")) #'ecc-review-talk-tour))
      (should (eq (key-binding (kbd "t")) #'ecc-review-talk-next))
      (should (eq (key-binding (kbd "M")) #'ecc-review-talk-message))
      (should (eq (key-binding (kbd "N")) #'ecc-review-next-file))
      (should (string-search "T tour  t next  M message" (ecc-review--header-line))))))

(ert-deftest ecc-review-talk-test-keys-of-the-ediff-review ()
  "T, t, M and y in the control panel, m still ediff's wide display."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (should (eq (key-binding (kbd "T")) #'ecc-review-talk-tour))
      (should (eq (key-binding (kbd "t")) #'ecc-review-talk-next))
      (should (eq (key-binding (kbd "M")) #'ecc-review-talk-message))
      (should (eq (key-binding (kbd "y")) #'ecc-review-talk-answer))
      (should (eq (key-binding (kbd "m")) #'ediff-toggle-wide-display))
      ;; The help says them: two lines with the help off, all of them on ?.
      (should (= (length (split-string ecc-review-ediff-brief-help-message "\n")) 2))
      (should (string-search "T tour   t next   M message" ecc-review-ediff-brief-help-message))
      (should (string-match-p "T -ask Claude for a tour" ecc-review-ediff-long-help-message))
      (should (string-match-p "y -answer what Claude asks" ecc-review-ediff-long-help-message)))))

;;;; Sending

(ert-deftest ecc-review-talk-test-tour-goes-to-the-review-s-session ()
  "T and t send their fixed text to the session of the review, and no other."
  (ecc-review-talk-test--with-sessions one two
    (let ((review-one (ecc-review-talk-test--diff-review one)))
      ;; Two's review is the one used last: what counts is whose review.
      (ecc-review-talk-test--diff-review two)
      (with-current-buffer review-one
        (ecc-review-talk-tour)
        (should (equal (ecc-review-talk-test--prompts one)
                       (list ecc-review-talk-tour-prompt)))
        (ecc-model-finish-turn one nil)
        (ecc-review-talk-next)
        (should (equal (ecc-review-talk-test--prompts one)
                       (list ecc-review-talk-tour-prompt ecc-review-talk-next-prompt))))
      (should-not (ecc-review-talk-test--prompts two))
      ;; The tour is in the words the instructions use for the tools.
      (should (string-search "review_navigate" ecc-review-talk-tour-prompt))
      (should (string-search "review_comment" ecc-review-talk-tour-prompt)))))

(ert-deftest ecc-review-talk-test-message-is-a-prompt ()
  "M sends the line it reads, with what a prompt is given on its way."
  (ecc-review-talk-test--with-sessions one two
    (let ((ecc-prepare-prompt-functions
           (list (lambda (_session text) (concat text " [prepared]")))))
      (with-current-buffer (ecc-review-talk-test--diff-review one)
        (cl-letf (((symbol-function #'read-string) (lambda (&rest _) "why this line?")))
          (call-interactively #'ecc-review-talk-message))
        (should (equal (ecc-review-talk-test--prompts one) '("why this line? [prepared]")))
        (should-error (ecc-review-talk-message "  ") :type 'user-error)))
    (should-not (ecc-review-talk-test--prompts two))))

(ert-deftest ecc-review-talk-test-a-busy-session-queues ()
  "While a turn runs, T is queued as a prompt typed then would be."
  (ecc-review-talk-test--with-sessions one _two
    (with-current-buffer (ecc-review-talk-test--diff-review one)
      (ecc-model-begin-turn one "working")
      (let ((said nil))
        (cl-letf (((symbol-function #'message)
                   (lambda (format &rest args) (setq said (apply #'format-message format args)))))
          (ecc-review-talk-tour))
        (should (string-search "queued at position 1" said)))
      (should-not (ecc-review-talk-test--prompts one))
      (should (equal (ecc-session-input-queue one) (list ecc-review-talk-tour-prompt))))))

(ert-deftest ecc-review-talk-test-no-tour-without-the-tools ()
  "Without MCP there is nothing to tour with, and T says so; M still sends."
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-mcp-enabled nil))
      (with-current-buffer (ecc-review-talk-test--diff-review one)
        (should-error (ecc-review-talk-tour) :type 'user-error)
        (should-error (ecc-review-talk-next) :type 'user-error)
        (should-not (ecc-review-talk-test--prompts one))
        (ecc-review-talk-message "hello")
        (should (equal (ecc-review-talk-test--prompts one) '("hello")))))))

(ert-deftest ecc-review-talk-test-the-diff-review-has-no-pane ()
  "A diff review has the session beside it, and no reply pane."
  (ecc-review-talk-test--with-sessions one _two
    (let ((review (ecc-review-talk-test--diff-review one)))
      (save-window-excursion
        (set-window-buffer (selected-window) review)
        (with-current-buffer review
          (ecc-review-talk-tour)
          (should-not ecc-review-talk--pane)))
      (should-not (seq-find (lambda (buffer)
                              (string-prefix-p "*ecc-review-reply" (buffer-name buffer)))
                            (buffer-list))))))

;;;; The pane

(ert-deftest ecc-review-talk-test-the-pane-is-a-bottom-side-window ()
  "The pane sits at the bottom, survives |, is never selected and goes on q."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height 6))
      (ecc-review-talk-test--with-ediff one control
        (let* ((pane (ecc-review-talk-test--pane control))
               (window (get-buffer-window pane)))
          (should (window-live-p window))
          (should (eq (window-parameter window 'window-side) 'bottom))
          (should (= (window-total-height window) 6))
          (should (equal (buffer-name pane) "*ecc-review-reply: test*"))
          (with-current-buffer pane
            (should (derived-mode-p 'special-mode))
            (should buffer-read-only)
            (should-not font-lock-mode))
          (should (string-search "Nothing from Claude yet"
                                 (ecc-review-talk-test--pane-text control)))
          ;; | lays the windows out again: the pane is back at the bottom,
          ;; and each side still shows its own buffer -- with the pane in
          ;; the way the control panel took the window of the left one.
          (ediff-toggle-split)
          (setq window (get-buffer-window pane))
          (should (eq (window-parameter window 'window-side) 'bottom))
          (should (eq (window-buffer ediff-window-A) ediff-buffer-A))
          (should (eq (window-buffer ediff-window-B) ediff-buffer-B))
          (should (eq (window-buffer ediff-control-window) control))
          (ediff-toggle-split)
          (should (eq (window-buffer ediff-window-A) ediff-buffer-A))
          (should (window-live-p (get-buffer-window pane)))
          (setq window (get-buffer-window pane))
          ;; T and what comes of it leave the keyboard where it was.
          (let ((selected (selected-window)))
            (ecc-review-talk-tour)
            (ecc-review-talk-test--say one "Here is the first stop.")
            (should (eq (selected-window) selected))
            (should-not (eq (selected-window) window)))
          (ecc-review-ediff-quit control)
          (should-not (buffer-live-p pane))
          (should-not (window-live-p window)))))))

(ert-deftest ecc-review-talk-test-no-pane-at-height-nil ()
  "With `ecc-review-talk-reply-height' nil an ediff review shows no pane."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height nil))
      (ecc-review-talk-test--with-ediff one control
        (ecc-review-talk-tour)
        (should-not (ecc-review-talk-test--pane control))
        (should (equal (ecc-review-talk-test--prompts one)
                       (list ecc-review-talk-tour-prompt)))))))

(ert-deftest ecc-review-talk-test-the-pane-streams-the-latest-reply ()
  "The reply streams in, each call on a line, and the next turn replaces it."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (ecc-review-talk-tour)
      (let ((node (ecc-review-talk-test--say one nil '("The cache "))))
        (should (string-match-p "\\`› Walk me through" (ecc-review-talk-test--pane-text control)))
        (should (string-search "\nThe cache \n" (ecc-review-talk-test--pane-text control)))
        ;; A delta is appended where the text ends, not written afresh.
        (with-current-buffer (ecc-review-talk-test--pane control)
          (cl-letf (((symbol-function #'erase-buffer)
                     (lambda () (ert-fail "the pane was written afresh for a delta"))))
            (ecc-model-append-stream one node "is new.")))
        (should (string-search "\nThe cache is new.\n" (ecc-review-talk-test--pane-text control)))
        (ecc-review-talk-test--finish-text one node "The cache is new.")
        (ecc-review-talk-test--call one "mcp__emacs__review_navigate"
                                    '((file . "a.txt") (line . 2)))
        (ecc-review-talk-test--call one "mcp__emacs__review_comment"
                                    '((file . "a.txt") (line . 2) (text . "Check this")))
        (ecc-review-talk-test--call one "Read" '((file_path . "/tmp/x/a.txt")) 'running)
        (let ((text (ecc-review-talk-test--pane-text control)))
          (should (string-search "  review_navigate → a.txt:2\n" text))
          (should (string-search "  review_comment → a.txt:2: Check this\n" text))
          (should (string-match-p "  Read → .*a\\.txt …\n" text)))
        ;; Faces go on with the text.
        (with-current-buffer (ecc-review-talk-test--pane control)
          (goto-char (point-min))
          (search-forward "review_navigate")
          (should (eq (get-text-property (point) 'face) 'ecc-dim-face))))
      (ecc-model-finish-turn one nil)
      (ecc-model-begin-turn one "Next stop.")
      (ecc-review-talk-test--say one "The second stop.")
      (let ((text (ecc-review-talk-test--pane-text control)))
        (should (string-search "The second stop." text))
        (should-not (string-search "The cache" text))
        (should-not (string-search "review_navigate" text))))))

(ert-deftest ecc-review-talk-test-the-pane-follows-its-end ()
  "A reply longer than the pane shows its last line."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height 5))
      (ecc-review-talk-test--with-ediff one control
        (ecc-model-begin-turn one "long")
        (ecc-review-talk-test--say one (mapconcat (lambda (n) (format "line %d" n))
                                                  (number-sequence 1 30) "\n"))
        ;; A batch Emacs does not redisplay, so what is checked is where
        ;; the window was told to start: the last lines fill it.
        (let* ((pane (ecc-review-talk-test--pane control))
               (window (get-buffer-window pane)))
          (with-current-buffer pane
            (should (= (window-point window) (point-max)))
            (should (> (window-start window) 1))
            (should (< (count-lines (window-start window) (point-max))
                       (window-body-height window)))
            (should (string-search "line 30"
                                   (buffer-substring (window-start window) (point-max))))))))))

(ert-deftest ecc-review-talk-test-the-pane-shows-only-its-session ()
  "What another session says never reaches the pane of this review."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one two
    (ecc-review-talk-test--with-ediff one control
      (ecc-model-begin-turn one "mine")
      (ecc-review-talk-test--say one "From one.")
      (ecc-model-begin-turn two "theirs")
      (ecc-review-talk-test--say two "From two.")
      (ecc-review-talk-test--call two "mcp__emacs__review_navigate" '((file . "b.txt")))
      (ecc-test-add-request two "Bash" '((command . "rm -rf two")))
      (let ((text (ecc-review-talk-test--pane-text control)))
        (should (string-search "From one." text))
        (should-not (string-search "From two." text))
        (should-not (string-search "b.txt" text))
        (should-not (string-search "rm -rf two" text)))
      ;; Nor does y answer it.
      (should-error (ecc-review-talk-answer) :type 'user-error)
      (should (ecc-session-pending two)))))

;;;; Answering

(ert-deftest ecc-review-talk-test-a-permission-is-answered-from-the-pane ()
  "A permission is shown whole, Bash too, and y allows or denies it."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (ecc-model-begin-turn one "clean up")
      (let ((command (concat "rm -rf build && " (make-string 120 ?x))))
        (ecc-test-add-request one "Bash" `((command . ,command) (description . "Clean")))
        (let ((text (ecc-review-talk-test--pane-text control)))
          (should (string-search "Claude asks to use Bash:" text))
          (should (string-search command text))
          (should (string-search "y allows or denies it here" text)))
        (cl-letf (((symbol-function #'read-multiple-choice) (lambda (&rest _) '(?y "allow"))))
          (ecc-review-talk-answer))
        (should-not (ecc-session-pending one))
        (should (equal (alist-get 'behavior (car (last (ecc-review-talk-test--responses one))))
                       "allow"))
        (should-not (string-search command (ecc-review-talk-test--pane-text control))))
      (ecc-test-add-request one "Write" '((file_path . "/tmp/a.txt") (content . "hi")))
      (cl-letf (((symbol-function #'read-multiple-choice) (lambda (&rest _) '(?n "deny")))
                ((symbol-function #'read-string) (lambda (&rest _) "not now")))
        (ecc-review-talk-answer))
      (let ((response (car (last (ecc-review-talk-test--responses one)))))
        (should (equal (alist-get 'behavior response) "deny"))
        (should (equal (alist-get 'message response) "not now")))
      (should-error (ecc-review-talk-answer) :type 'user-error))))

(ert-deftest ecc-review-talk-test-a-question-is-answered-from-the-pane ()
  "A question is shown with its options, and y answers it in the minibuffer."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (ecc-model-begin-turn one "ask me")
      (ecc-test-add-request
       one "AskUserQuestion"
       '((questions . [((question . "Which cache?") (header . "Cache") (multiSelect . :false)
                        (options . [((label . "LRU") (description . "Least recently used"))
                                    ((label . "TTL"))]))])))
      (let ((text (ecc-review-talk-test--pane-text control)))
        (should (string-search "Which cache?" text))
        (should (string-search "  1. LRU — Least recently used" text))
        (should (string-search "  2. TTL" text))
        (should (string-search "y answers it here" text)))
      (cl-letf (((symbol-function #'completing-read) (lambda (&rest _) "TTL")))
        (ecc-review-talk-answer))
      (should-not (ecc-session-pending one))
      (let ((response (car (last (ecc-review-talk-test--responses one)))))
        (should (equal (alist-get 'behavior response) "allow"))
        (should (equal (alist-get 'Which\ cache\?
                                  (alist-get 'answers (alist-get 'updatedInput response)))
                       "TTL")))
      (should-not (get-buffer (ecc-question-buffer-name one))))))

(provide 'ecc-review-talk-test)

;;; ecc-review-talk-test.el ends here
