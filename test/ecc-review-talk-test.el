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
(require 'ecc-review-files)

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
  "Open the ediff review of a.txt, which SESSION changed twice in DIRECTORY."
  (ecc-review-talk-test--git directory "init" "-q")
  (ecc-review-talk-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-talk-test--git directory "config" "user.name" "t")
  (with-temp-file (concat directory "a.txt") (insert (ecc-review-talk-test--lines nil)))
  (ecc-review-talk-test--git directory "add" ".")
  (ecc-review-talk-test--git directory "commit" "-q" "-m" "init")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (with-temp-file (concat directory "a.txt") (insert (ecc-review-talk-test--lines t)))
  (ecc-review-ediff-buffer session))

(defun ecc-review-talk-test--lines (changed)
  "Return twelve lines, the second and the eleventh upcased when CHANGED.
Two differences, far enough apart to stay two."
  (mapconcat (lambda (n)
               (let ((line (format "line %d" n)))
                 (if (and changed (memq n '(2 11))) (upcase line) line)))
             (number-sequence 1 12) "\n"))

(defvar ecc-review-talk-test--layout 'side-by-side
  "The `ecc-review-ediff-layout' `ecc-review-talk-test--with-ediff' opens in.")

(defmacro ecc-review-talk-test--with-ediff (session control &rest body)
  "Run BODY in CONTROL, the ediff review of one file of SESSION.
It is laid out as `ecc-review-talk-test--layout' says."
  (declare (indent 2))
  `(let ((directory (file-name-as-directory (make-temp-file "ecc-review-talk" t)))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (ecc-review-ediff-layout ecc-review-talk-test--layout)
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
  "T, t, M and y in the panel and its windows; m still ediff's wide display."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (should (eq (key-binding (kbd "T")) #'ecc-review-talk-tour))
      (should (eq (key-binding (kbd "t")) #'ecc-review-talk-next))
      (should (eq (key-binding (kbd "M")) #'ecc-review-talk-message))
      (should (eq (key-binding (kbd "y")) #'ecc-review-talk-answer))
      (should (eq (key-binding (kbd "m")) #'ediff-toggle-wide-display))
      ;; The header line of the right window says them, and so does ?.
      (should (string-search "T tour  t next  M message"
                             (ecc-review-direct-header-text
                              (buffer-local-value 'ediff-buffer-B control))))
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
          (should-not (get-buffer-window control))
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

(defun ecc-review-talk-test--stacked-p (control)
  "Return non-nil when the two sides of the review CONTROL are one above the other."
  (with-current-buffer control
    (< (cadr (window-edges ediff-window-A)) (cadr (window-edges ediff-window-B)))))

(ert-deftest ecc-review-talk-test-a-review-opens-stacked-with-the-pane-on-the-right ()
  "Stacked by default, the pane on the right; | puts the sides apart and the pane under.
The second | puts both back."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    ;; A batch frame is 80 columns: the pane is made narrow enough to fit.
    (let ((ecc-review-talk-test--layout
           (eval (car (get 'ecc-review-ediff-layout 'standard-value)) t))
          (ecc-review-talk-reply-width 20)
          (ecc-review-talk-min-diff-width 40)
          (ecc-review-talk-reply-height 6))
      (ecc-review-talk-test--with-ediff one control
        (let ((pane (ecc-review-talk-test--pane control)))
          (should (eq ecc-review-talk-test--layout 'stacked))
          (should (ecc-review-talk-test--stacked-p control))
          (should (eq (window-parameter (get-buffer-window pane) 'window-side) 'right))
          (should (= (window-total-width (get-buffer-window pane)) 20))
          (ediff-toggle-split)
          (should-not (ecc-review-talk-test--stacked-p control))
          (should (eq (window-parameter (get-buffer-window pane) 'window-side) 'bottom))
          (should (= (window-total-height (get-buffer-window pane)) 6))
          (should (eq (window-buffer ediff-window-A) ediff-buffer-A))
          (should (eq (window-buffer ediff-window-B) ediff-buffer-B))
          (ediff-toggle-split)
          (should (ecc-review-talk-test--stacked-p control))
          (should (eq (window-parameter (get-buffer-window pane) 'window-side) 'right))
          ;; One pane, never two.
          (should (= (length (get-buffer-window-list pane nil t)) 1)))))))

(ert-deftest ecc-review-talk-test-a-narrow-frame-has-the-pane-under ()
  "Stacked in a frame that cannot spare the columns, the pane goes under the review."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-test--layout 'stacked)
          (ecc-review-talk-reply-width 60)
          (ecc-review-talk-min-diff-width 80))
      (ecc-review-talk-test--with-ediff one control
        (should (ecc-review-talk-test--stacked-p control))
        (should (eq (window-parameter (get-buffer-window (ecc-review-talk-test--pane control))
                                      'window-side)
                    'bottom))))))

(defmacro ecc-review-talk-test--with-fake-frames (made deleted &rest body)
  "Run BODY with reply frames that are symbols, each shown in a side window.
Batch makes no frame.  MADE is the list of the names the frames were
made with, DELETED of the frames deleted.  A frame's window is a side
window of the frame there is, at the top, which ediff does not lay out."
  (declare (indent 2))
  `(let* ((,made nil)
          (,deleted nil)
          (live nil)
          (holders nil)
          (ecc-review-talk-reply-place 'frame)
          (ecc-review-talk-make-frame-function
           (lambda (name)
             (push name ,made)
             (let ((frame (intern (format "frame-%d" (length ,made)))))
               (push frame live)
               frame))))
     (cl-letf* ((frame-live (symbol-function 'frame-live-p))
                ((symbol-function 'frame-live-p)
                 (lambda (frame) (if (symbolp frame) (memq frame live) (funcall frame-live frame))))
                ((symbol-function 'ecc-review-talk--frame-window)
                 (lambda (frame)
                   (let ((window (alist-get frame holders)))
                     (unless (window-live-p window)
                       (setq window (display-buffer-in-side-window
                                     (get-buffer-create (format " *%s*" frame))
                                     `((side . top) (slot . ,(length holders)) (window-height . 3)
                                       ;; As a frame of its own is: out of
                                       ;; the way of ediff's layout, whose
                                       ;; `other-window' before Emacs 31
                                       ;; would go into it.
                                       (window-parameters . ((no-delete-other-windows . t)
                                                             (no-other-window . t))))))
                       (setf (alist-get frame holders) window))
                     window)))
                ((symbol-function 'delete-frame)
                 (lambda (frame &rest _)
                   (push frame ,deleted)
                   (setq live (delq frame live)))))
       ,@body)))

(ert-deftest ecc-review-talk-test-the-pane-in-a-frame-of-its-own ()
  "With the place `frame' the pane is in a frame made once and closed with the review.
The keyboard stays where it was, and | leaves the frame alone."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-fake-frames made deleted
      (ecc-review-talk-test--with-ediff one control
        (let* ((pane (ecc-review-talk-test--pane control))
               (window (get-buffer-window pane))
               (selected (selected-window)))
          (should (eq (window-parameter window 'ecc-review-talk) 'frame))
          (should (equal made (list (buffer-name pane))))
          (should (eq (selected-window) selected))
          (ediff-toggle-split)
          (should (eq (get-buffer-window pane) window))
          (should (= (length (get-buffer-window-list pane nil t)) 1))
          (ecc-review-talk-tour)
          (should (= (length made) 1))
          (ecc-review-ediff-quit control)
          (should (equal deleted '(frame-1))))))))

(ert-deftest ecc-review-talk-test-two-reviews-two-reply-frames ()
  "Two sessions with a review each: each pane has a frame, and quitting one keeps the other."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one two
    (ecc-review-talk-test--with-fake-frames made deleted
      (ecc-review-talk-test--with-ediff one first
        (let ((first-pane (ecc-review-talk-test--pane first)))
          (ecc-review-talk-test--with-ediff two second
            (let ((second-pane (ecc-review-talk-test--pane second)))
              ;; One frame each; the first is not taken by the second.
              ;; (Batch has one frame, so the second review laid out
              ;; over the side window the first pane's stood for.)
              (should (equal made (list (buffer-name second-pane) (buffer-name first-pane))))
              (should (eq (buffer-local-value 'ecc-review-talk--frame first-pane) 'frame-1))
              (should (eq (buffer-local-value 'ecc-review-talk--frame second-pane) 'frame-2))
              (should (get-buffer-window second-pane))
              (ecc-review-ediff-quit second)
              (should (equal deleted '(frame-2)))
              (should (eq (buffer-local-value 'ecc-review-talk--frame first-pane) 'frame-1))))
          (ecc-review-ediff-quit first)
          (should (equal deleted '(frame-1 frame-2))))))))

(defun ecc-review-talk-test--resized (control)
  "Run what redisplay runs when the right window of the review CONTROL changed size.
Batch does no redisplay, which is what runs `window-size-change-functions'."
  (with-current-buffer control
    (with-current-buffer ediff-buffer-B
      (run-hook-with-args 'window-size-change-functions ediff-window-B))))

(ert-deftest ecc-review-talk-test-s-and-q-move-the-pane-when-the-diff-gets-narrow ()
  "The files pane shown by s leaves the stacked diff too narrow: the pane goes under.
q in the files pane gives the columns back, and the pane goes back to
the right; a frame made narrower is checked the same way.  Each is seen
as the right window changing size."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-test--layout 'stacked)
          (ecc-review-talk-reply-width 20)
          (ecc-review-talk-min-diff-width 40)
          (ecc-review-files-shown nil)
          (ecc-review-files-width 32))
      (ecc-review-talk-test--with-ediff one control
        (let ((side (lambda ()
                      (window-parameter (get-buffer-window (ecc-review-talk-test--pane control))
                                        'window-side))))
          (should (eq (funcall side) 'right))
          (should (memq #'ecc-review-talk--size-changed
                        (buffer-local-value 'window-size-change-functions ediff-buffer-B)))
          (ecc-review-files-toggle)
          (ecc-review-talk-test--resized control)
          (should (eq (funcall side) 'bottom))
          (should (ecc-review-talk-test--stacked-p control))
          ;; q in the files pane.
          (with-selected-window (ecc-review-files--pane-window control)
            (call-interactively (key-binding (kbd "q"))))
          (should-not (ecc-review-files--pane-window control))
          (ecc-review-talk-test--resized control)
          (should (eq (funcall side) 'right))
          ;; The frame narrower.
          (let ((ecc-review-talk-min-diff-width 70))
            (ecc-review-talk-test--resized control))
          (should (eq (funcall side) 'bottom)))))))

(ert-deftest ecc-review-talk-test-a-pane-moved-keeps-the-keyboard ()
  "A reply pane that has the keyboard as it moves has it again on its new side."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-test--layout 'stacked)
          (ecc-review-talk-reply-width 20)
          (ecc-review-talk-min-diff-width 40))
      (ecc-review-talk-test--with-ediff one control
        (let ((pane (ecc-review-talk-test--pane control)))
          (select-window (get-buffer-window pane))
          (let ((ecc-review-talk-min-diff-width 70))
            (ecc-review-talk-test--resized control))
          (should (eq (window-parameter (get-buffer-window pane) 'window-side) 'bottom))
          (should (eq (window-buffer (selected-window)) pane)))))))

(ert-deftest ecc-review-talk-test-another-review-s-files-pane-moves-nothing ()
  "Two sessions' reviews: the files pane of one leaves the reply pane of the other where it is."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one two
    (let ((ecc-review-talk-test--layout 'stacked)
          (ecc-review-talk-reply-width 20)
          (ecc-review-talk-min-diff-width 40)
          (ecc-review-files-shown nil)
          (ecc-review-files-width 32))
      (ecc-review-talk-test--with-ediff one first
        (ecc-review-talk-test--with-ediff two second
          ;; The second review's files pane: `ecc-review-files-shown' is t
          ;; for every review from now on.
          (ecc-review-files-toggle)
          (should ecc-review-files-shown)
          (ecc-review-talk-test--resized second)
          (should (eq (window-parameter (get-buffer-window (ecc-review-talk-test--pane second))
                                        'window-side)
                      'bottom))
          (ecc-review-ediff-quit second))
        ;; Back on the screen, the first has no files pane, and its pane
        ;; stays on the right.
        (should-not (ecc-review-files--pane-window first))
        (ecc-review-talk-test--resized first)
        (should (eq (window-parameter (get-buffer-window (ecc-review-talk-test--pane first))
                                      'window-side)
                    'right))))))

(ert-deftest ecc-review-talk-test-a-frame-function-of-no-argument ()
  "A `ecc-review-talk-make-frame-function' of no argument still works, and the frame is named."
  (let* ((named nil)
         (ecc-review-talk-make-frame-function (lambda () 'a-frame)))
    (cl-letf (((symbol-function 'set-frame-parameter)
               (lambda (frame parameter value) (push (list frame parameter value) named))))
      (should (eq (ecc-review-talk--new-frame "*ecc-review-reply: x*") 'a-frame))
      (should (equal named '((a-frame name "*ecc-review-reply: x*")))))
    (let ((ecc-review-talk-make-frame-function (lambda (name) (list 'made name))))
      (should (equal (ecc-review-talk--new-frame "n") '(made "n"))))
    (let ((ecc-review-talk-make-frame-function (lambda (&rest args) args)))
      (should (equal (ecc-review-talk--new-frame "n") '("n"))))))

;; Batch does no redisplay: what is checked is where each window of
;; the pane was told to start, and what is at that start.

(defun ecc-review-talk-test--top (window)
  "Return the line of its buffer WINDOW starts at, without the newline."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char (window-start window))
      (buffer-substring-no-properties (point) (line-end-position)))))

(defun ecc-review-talk-test--end-shown (window)
  "Return non-nil when WINDOW, a window of a reply pane, shows its end."
  (with-current-buffer (window-buffer window)
    (ecc-review-talk--end-shown-p window)))

(defun ecc-review-talk-test--long (session)
  "Have SESSION say forty lines in a turn of its own, after a call still running.
Return the call."
  (ecc-model-begin-turn session "long")
  (prog1 (ecc-review-talk-test--call session "Read" '((file_path . "/tmp/x/a.txt")) 'running)
    (ecc-review-talk-test--say
     session (mapconcat (lambda (n) (format "Line %d of the reply." n))
                        (number-sequence 1 40) "\n"))))

(ert-deftest ecc-review-talk-test-u-and-d-scroll-the-pane ()
  "u scrolls the reply pane back, where it stays as Claude goes on; d scrolls it on.
Reaching the end, the pane follows its end again; so it does when a turn
begins.  Typed in a window of the review, the keyboard stays there."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height 6))
      (ecc-review-talk-test--with-ediff one control
        (let* ((pane (ecc-review-talk-test--pane control))
               (window (get-buffer-window pane))
               (right (with-current-buffer control ediff-window-B)))
          (should (eq (key-binding (kbd "u")) #'ecc-review-talk-scroll-back))
          (should (eq (key-binding (kbd "d")) #'ecc-review-talk-scroll-on))
          (ecc-review-talk-test--long one)
          (should (ecc-review-talk-test--end-shown window))
          (select-window right)
          (execute-kbd-macro (kbd "u"))
          (should (eq (selected-window) right))
          (should-not (ecc-review-talk-test--end-shown window))
          ;; Claude goes on; the pane stays where it was put.
          (let ((top (ecc-review-talk-test--top window)))
            (ecc-review-talk-test--say one "More.")
            (should (equal (ecc-review-talk-test--top window) top)))
          (dotimes (_ 20)
            (unless (ecc-review-talk-test--end-shown window)
              (execute-kbd-macro (kbd "d"))))
          (should (ecc-review-talk-test--end-shown window))
          (should-error (ecc-review-talk-scroll-on) :type 'user-error)
          (should (eq (selected-window) right))
          ;; At the end, it follows what comes in.
          (ecc-review-talk-test--say one (mapconcat #'identity (make-list 10 "Again.") "\n"))
          (should (ecc-review-talk-test--end-shown window))
          ;; Scrolled back again, a new turn brings it to the end.
          (execute-kbd-macro (kbd "u"))
          (should-not (ecc-review-talk-test--end-shown window))
          (ecc-model-begin-turn one "Next stop.")
          (ecc-review-talk-test--long one)
          (should (ecc-review-talk-test--end-shown window)))))))

(ert-deftest ecc-review-talk-test-a-call-done-keeps-the-lines-in-view ()
  "A pane scrolled back keeps its top line when a call above it ends.
The call's line is shorter without its \" …\", and the pane is written
afresh: the start is kept by line, not by position."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height 6))
      (ecc-review-talk-test--with-ediff one control
        (let* ((window (get-buffer-window (ecc-review-talk-test--pane control)))
               (call (ecc-review-talk-test--long one)))
          (ecc-review-talk-scroll-back)
          (ecc-review-talk-scroll-back)
          (let ((top (ecc-review-talk-test--top window)))
            (should (string-prefix-p "Line " top))
            (setf (ecc-node-status call) 'done)
            (ecc-model-node-changed one call)
            (should-not (string-search " …" (ecc-review-talk-test--pane-text control)))
            (should (equal (ecc-review-talk-test--top window) top))
            (should (string-prefix-p "Line " (ecc-review-talk-test--top window)))))))))

(ert-deftest ecc-review-talk-test-scrolled-any-way-the-pane-stays ()
  "A pane scrolled back by the wheel or its own keys stays where it is.
The keys of the review work in the pane too, and scrolling it on to the
end lets it follow again."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height 6))
      (ecc-review-talk-test--with-ediff one control
        (let* ((pane (ecc-review-talk-test--pane control))
               (window (get-buffer-window pane)))
          (with-current-buffer pane
            (should (eq (key-binding (kbd "u")) #'ecc-review-talk-scroll-back))
            (should (eq (key-binding (kbd "d")) #'ecc-review-talk-scroll-on))
            (should (eq (key-binding (kbd "DEL")) #'ecc-review-talk-scroll-back))
            (should (eq (key-binding (kbd "SPC")) #'ecc-review-talk-scroll-on)))
          (ecc-review-talk-test--long one)
          ;; What the wheel does: scroll the window, from inside it.
          (with-selected-window window
            (scroll-down 10))
          (should-not (ecc-review-talk-test--end-shown window))
          (let ((top (ecc-review-talk-test--top window)))
            (ecc-review-talk-test--say one "More.")
            (should (equal (ecc-review-talk-test--top window) top)))
          ;; d in the pane, to the end.
          (with-selected-window window
            (dotimes (_ 20)
              (unless (ecc-review-talk-test--end-shown window)
                (execute-kbd-macro (kbd "d")))))
          (should (ecc-review-talk-test--end-shown window))
          (ecc-review-talk-test--say one (mapconcat #'identity (make-list 10 "Again.") "\n"))
          (should (ecc-review-talk-test--end-shown window))
          ;; DEL in the pane is u.
          (with-selected-window window
            (execute-kbd-macro (kbd "DEL")))
          (should-not (ecc-review-talk-test--end-shown window)))))))

(ert-deftest ecc-review-talk-test-one-session-s-pane-scrolled-leaves-the-other ()
  "With two sessions, a pane scrolled back stays and the other's follows.
A new turn of one session brings its own pane to the end, not the other's."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one two
    (let ((ecc-review-talk-reply-height 6))
      (ecc-review-talk-test--with-ediff one first
        (let ((first-pane (ecc-review-talk-test--pane first)))
          (ecc-review-talk-test--with-ediff two second
            (let* ((second-window (get-buffer-window (ecc-review-talk-test--pane second)))
                   ;; The first review's pane in a window of its own, beside.
                   (first-window (split-window (with-current-buffer second ediff-window-A))))
              (set-window-buffer first-window first-pane)
              (with-current-buffer first-pane
                (ecc-review-talk--window-to-the-end first-window))
              (ecc-review-talk-test--long one)
              (ecc-review-talk-test--long two)
              (should (ecc-review-talk-test--end-shown first-window))
              (should (ecc-review-talk-test--end-shown second-window))
              (with-current-buffer first (ecc-review-talk-scroll-back))
              (let ((top (ecc-review-talk-test--top first-window)))
                (ecc-review-talk-test--say one "More from one.")
                (ecc-review-talk-test--say two "More from two.")
                (should (equal (ecc-review-talk-test--top first-window) top))
                (should (ecc-review-talk-test--end-shown second-window))
                ;; The second scrolled back; a new turn of the first lets
                ;; the first go and keeps the second where it is.
                (with-current-buffer second (ecc-review-talk-scroll-back))
                (let ((second-top (ecc-review-talk-test--top second-window)))
                  (ecc-review-talk-test--long one)
                  (should (ecc-review-talk-test--end-shown first-window))
                  (should (equal (ecc-review-talk-test--top second-window) second-top)))))))))))

(ert-deftest ecc-review-talk-test-a-pane-shown-again-is-where-it-was ()
  "| lays the review out again: a pane scrolled back shows the same line, one at its end its end.
So it does when a call above that line ends while the pane is off the screen."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height 6))
      (ecc-review-talk-test--with-ediff one control
        (let ((pane (ecc-review-talk-test--pane control))
              (call (ecc-review-talk-test--long one)))
          (ediff-toggle-split)
          (should (ecc-review-talk-test--end-shown (get-buffer-window pane)))
          (ecc-review-talk-scroll-back)
          (let ((top (ecc-review-talk-test--top (get-buffer-window pane))))
            (ediff-toggle-split)
            (let ((window (get-buffer-window pane)))
              (should (window-live-p window))
              (should (equal (ecc-review-talk-test--top window) top))
              (should-not (ecc-review-talk-test--end-shown window)))
            ;; Off the screen, as | has it between the two layouts.
            (ecc-review-talk--take-down pane 'side-only)
            (setf (ecc-node-status call) 'done)
            (ecc-model-node-changed one call)
            (ecc-review-talk--show-pane control)
            (should (equal (ecc-review-talk-test--top (get-buffer-window pane)) top))
            ;; A new turn has it at the end.
            (ediff-toggle-split)
            (ecc-model-begin-turn one "Next stop.")
            (should (ecc-review-talk-test--end-shown (get-buffer-window pane)))))))))

(ert-deftest ecc-review-talk-test-no-pane-at-height-nil ()
  "With `ecc-review-talk-reply-height' nil an ediff review shows no pane."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-talk-reply-height nil))
      (ecc-review-talk-test--with-ediff one control
        (ecc-review-talk-tour)
        (should-not (ecc-review-talk-test--pane control))
        (should-error (ecc-review-talk-scroll-back) :type 'user-error)
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
        ;; A request that is waiting is answered through the shared guard,
        ;; and resolved once.
        (let ((resolved 0))
          (let ((ecc-request-resolved-hook
                 (cons (lambda (&rest _) (cl-incf resolved)) ecc-request-resolved-hook)))
            (cl-letf (((symbol-function #'read-multiple-choice)
                       (lambda (&rest _) '(?y "allow"))))
              (ecc-review-talk-answer)))
          (should (= resolved 1)))
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

(defconst ecc-review-talk-test--questions
  '((questions . [((question . "Which cache?") (header . "Cache") (multiSelect . :false)
                   (options . [((label . "LRU") (description . "Least recently used"))
                               ((label . "TTL"))]))
                  ((question . "Which stores?") (header . "Stores") (multiSelect . t)
                   (options . [((label . "Disk")) ((label . "Memory"))]))]))
  "Two questions, the second taking several answers.")

(ert-deftest ecc-review-talk-test-a-question-is-answered-from-the-pane ()
  "A question is shown with its options, and y answers each in the minibuffer."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (ecc-model-begin-turn one "ask me")
      (let ((request (ecc-test-add-request one "AskUserQuestion"
                                           ecc-review-talk-test--questions)))
        (let ((text (ecc-review-talk-test--pane-text control)))
          (should (string-search "Which cache?" text))
          (should (string-search "  1. LRU — Least recently used" text))
          (should (string-search "  2. TTL" text))
          (should (string-search "y answers it here" text)))
        ;; The user had ticked Disk in the question buffer; the pane's
        ;; answer is its own, not a toggle of that one.
        (with-current-buffer (ecc-question-open request)
          (ecc-question-set-answer 1 "Disk"))
        (cl-letf (((symbol-function #'completing-read) (lambda (&rest _) "TTL"))
                  ((symbol-function #'completing-read-multiple)
                   (lambda (&rest _) '("Disk" "Memory" "Disk"))))
          (ecc-review-talk-answer))
        (should-not (ecc-session-pending one))
        (let* ((response (car (last (ecc-review-talk-test--responses one))))
               (answers (alist-get 'answers (alist-get 'updatedInput response))))
          (should (equal (alist-get 'behavior response) "allow"))
          (should (equal (alist-get 'Which\ cache\? answers) "TTL"))
          (should (equal (alist-get 'Which\ stores\? answers) "Disk, Memory")))
        ;; Answered, the question buffer goes, as it does when answered anywhere.
        (should-not (ecc-question-buffer request))))))

(ert-deftest ecc-review-talk-test-a-question-left-half-way-changes-nothing ()
  "C-g on the second question sends nothing and leaves the question buffer alone."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one _control
      (ecc-model-begin-turn one "ask me")
      (let* ((request (ecc-test-add-request one "AskUserQuestion"
                                            ecc-review-talk-test--questions))
             (buffer (ecc-question-open request)))
        (with-current-buffer buffer
          (ecc-question-set-answer 0 "LRU"))
        (cl-letf (((symbol-function #'completing-read) (lambda (&rest _) "TTL"))
                  ((symbol-function #'completing-read-multiple)
                   (lambda (&rest _) (signal 'quit nil))))
          ;; A quit is no error, and `should-error' would let it through.
          (should (eq (condition-case nil (ecc-review-talk-answer) (quit 'quit)) 'quit)))
        (should (memq request (ecc-session-pending one)))
        (should-not (ecc-review-talk-test--responses one))
        (with-current-buffer buffer
          (should (equal ecc-question--answers [("LRU") nil])))
        ;; An empty answer is no answer.
        (cl-letf (((symbol-function #'completing-read) (lambda (&rest _) "TTL"))
                  ((symbol-function #'completing-read-multiple) (lambda (&rest _) nil)))
          (should-error (ecc-review-talk-answer) :type 'user-error))
        (should-not (ecc-review-talk-test--responses one))))))

(ert-deftest ecc-review-talk-test-a-request-taken-back-is-not-answered ()
  "A request the CLI takes back while y asks is not answered after all."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one _control
      (ecc-model-begin-turn one "clean up")
      (dolist (choice '(?y ?n))
        (let ((request (ecc-test-add-request one "Bash" '((command . "make clean"))))
              (resolved 0))
          (cl-letf (((symbol-function #'read-multiple-choice)
                     (lambda (&rest _)
                       (ecc-model-abandon-requests one "the turn was interrupted")
                       (list choice)))
                    ((symbol-function #'read-string) (lambda (&rest _) "")))
            (let ((ecc-request-resolved-hook
                   (cons (lambda (_session r) (when (eq r request) (cl-incf resolved)))
                         ecc-request-resolved-hook)))
              (should (equal (cadr (should-error (ecc-review-talk-answer) :type 'user-error))
                             "That request is no longer waiting"))
              (should (<= resolved 1)))))
        (should-not (ecc-review-talk-test--responses one)))
      ;; A question, with the same words: one check, in `ecc-perm-respond'.
      (ecc-test-add-request one "AskUserQuestion" ecc-review-talk-test--questions)
      (cl-letf (((symbol-function #'completing-read) (lambda (&rest _) "TTL"))
                ((symbol-function #'completing-read-multiple)
                 (lambda (&rest _)
                   (ecc-model-abandon-requests one "the turn was interrupted")
                   '("Disk"))))
        (should (equal (cadr (should-error (ecc-review-talk-answer) :type 'user-error))
                       "That request is no longer waiting")))
      (should-not (ecc-review-talk-test--responses one)))))

(ert-deftest ecc-review-talk-test-taken-back-while-asked-about-the-buffer ()
  "y on a file with unsaved changes, the request taken back while that is asked."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one _control
      (ecc-model-begin-turn one "edit")
      (let* ((file (make-temp-file "ecc-review-talk" nil ".txt" "one\n"))
             (buffer (find-file-noselect file))
             (request (ecc-test-add-request one "Write" `((file_path . ,file)
                                                          (content . "two\n"))))
             (asked 0))
        (unwind-protect
            (progn
              (with-current-buffer buffer (insert "unsaved "))
              (cl-letf (((symbol-function #'read-multiple-choice)
                         (lambda (&rest _)
                           (cl-incf asked)
                           (if (= asked 1)
                               '(?y "allow")
                             ;; The second question, about the buffer.
                             (ecc-model-abandon-requests one "the turn was interrupted")
                             '(?a "allow anyway")))))
                (should (equal (cadr (should-error (ecc-review-talk-answer)
                                                   :type 'user-error))
                               "That request is no longer waiting")))
              (should (= asked 2))
              (should (eq (ecc-node-status (ecc-request-node request)) 'denied))
              (should-not (ecc-review-talk-test--responses one)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)
          (delete-file file))))))

(ert-deftest ecc-review-talk-test-an-allow-that-became-a-deny-says-so ()
  "y on a change to a file with unsaved changes, answered d, says denied."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one _control
      (ecc-model-begin-turn one "edit")
      (ecc-test-add-request one "Edit" '((file_path . "/tmp/a.txt")
                                         (old_string . "a") (new_string . "b")))
      (let ((said nil))
        (cl-letf (((symbol-function #'read-multiple-choice) (lambda (&rest _) '(?y "allow")))
                  ((symbol-function #'ecc-perm--unsaved-choice) (lambda (_request) 'deny))
                  ((symbol-function #'message)
                   (lambda (format &rest args) (setq said (apply #'format-message format args)))))
          (ecc-review-talk-answer))
        (should (string-prefix-p "Denied: " said))
        (should (string-search "unsaved changes" said)))
      (should (equal (alist-get 'behavior (car (last (ecc-review-talk-test--responses one))))
                     "deny")))))

(ert-deftest ecc-review-talk-test-moving-keeps-the-pane-window ()
  "n, p and a recentre leave the pane's window, and the height given it, alone."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (let* ((pane (ecc-review-talk-test--pane control))
             (window (get-buffer-window pane))
             (shown 0))
        (should (= ediff-number-of-differences 2))
        ;; The user makes it taller.
        (window-resize window 2)
        (let ((height (window-total-height window))
              (display (symbol-function 'display-buffer-in-side-window)))
          (cl-letf (((symbol-function 'display-buffer-in-side-window)
                     (lambda (&rest args) (cl-incf shown) (apply display args))))
            (ecc-review-ediff-next-difference)
            (ecc-review-ediff-previous-difference)
            (ediff-recenter)
            (let ((ecc-mcp--session-id (ecc-session-id one)))
              (ecc-mcp-call-tool "review_navigate" '((file . "a.txt") (line . 11)))))
          (should (zerop shown))
          (should (eq (get-buffer-window pane) window))
          (should (= (window-total-height window) height)))))))

(ert-deftest ecc-review-talk-test-both-panes ()
  "The files pane on the left and the reply pane at the bottom, through n, p, | and q."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (let ((ecc-review-files-shown nil)
          (ecc-review-files-width 20))
      (ecc-review-talk-test--with-ediff one control
        (ecc-review-files-toggle)
        (let ((files (buffer-local-value 'ecc-review-files--pane control))
              (reply (ecc-review-talk-test--pane control)))
          (cl-flet ((check ()
                      (should (eq (window-parameter (get-buffer-window files) 'window-side) 'left))
                      (should (eq (window-parameter (get-buffer-window reply) 'window-side) 'bottom))
                      (should (eq (window-buffer ediff-window-A) ediff-buffer-A))
                      (should (eq (window-buffer ediff-window-B) ediff-buffer-B))
                      (should-not (get-buffer-window control))))
            (check)
            (ecc-review-ediff-next-difference)
            (ecc-review-ediff-previous-difference)
            (check)
            (ediff-toggle-split)
            (check)
            (ediff-toggle-split)
            (check))
          (ecc-review-ediff-quit control)
          (should-not (buffer-live-p files))
          (should-not (buffer-live-p reply))
          (should-not (seq-find (lambda (window)
                                  (or (window-parameter window 'ecc-review-files)
                                      (window-parameter window 'ecc-review-talk)))
                                (window-list))))))))

(ert-deftest ecc-review-talk-test-only-what-the-pane-shows-writes-it ()
  "A subagent's nodes write nothing; an answered request writes the pane once."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one _control
      (ecc-model-begin-turn one "work")
      (let* ((agent (ecc-review-talk-test--call one "Agent" '((description . "look around"))))
             (writes 0)
             (write (symbol-function 'ecc-review-talk--write)))
        (cl-letf (((symbol-function 'ecc-review-talk--write)
                   (lambda (pane) (cl-incf writes) (funcall write pane))))
          (setf (ecc-node-type agent) 'agent)
          (let ((inner (ecc-model-add-node one :type 'text :parent agent :status 'done
                                           :data '((text . "inside")))))
            (ecc-model-node-changed one inner))
          (ecc-model-add-node one :type 'thinking :status 'done :data '((text . "hm")))
          (should (zerop writes))
          (let ((request (ecc-test-add-request one "Bash" '((command . "ls")))))
            (setq writes 0)
            (ecc-perm-respond request 'allow)
            (should (= writes 1))))))))

(ert-deftest ecc-review-talk-test-mode-lines-are-left-alone ()
  "A delta updates no mode line; a change of state only the pane's own."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (ecc-model-begin-turn one "talk")
      ;; Other modules have mode lines of their own to update on a change
      ;; of state, so what is counted is what the pane's functions do.
      (let ((node (ecc-review-talk-test--say one "Hello"))
            (pane (ecc-review-talk-test--pane control))
            (calls nil))
        (cl-letf* ((update (symbol-function 'force-mode-line-update))
                   ((symbol-function 'force-mode-line-update)
                    (lambda (&optional all) (push (cons (current-buffer) all) calls)
                      (funcall update))))
          (ecc-review-talk--on-delta one node " there")
          (should-not calls)
          (ecc-review-talk--on-state one 'running))
        (should (equal calls (list (cons pane nil))))))))

(ert-deftest ecc-review-talk-test-a-pane-is-listed-once ()
  "A pane buffer taken up again is listed once, and a killed one is forgotten."
  (skip-unless (executable-find "git"))
  (ecc-review-talk-test--with-sessions one _two
    (ecc-review-talk-test--with-ediff one control
      (let ((pane (ecc-review-talk-test--pane control)))
        (setq ecc-review-talk--pane nil)
        (should (eq (ecc-review-talk--pane-buffer control) pane))
        (should (= (seq-count (lambda (buffer) (eq buffer pane)) ecc-review-talk--panes) 1))
        ;; Looking the panes up changes nothing; killing one takes it off.
        (let ((list ecc-review-talk--panes))
          (ecc-review-talk--panes-of one)
          (should (eq ecc-review-talk--panes list)))
        (kill-buffer pane)
        (should-not (memq pane ecc-review-talk--panes))))))

(ert-deftest ecc-review-talk-test-a-pane-given-back-keeps-no-parameters ()
  "A pane alone in its frame is given back with none of its window parameters."
  (save-window-excursion
    (delete-other-windows)
    (let ((window (selected-window))
          (pane (get-buffer-create " *ecc-review-talk-test pane*")))
      (unwind-protect
          (progn
            (set-window-buffer window pane)
            (set-window-dedicated-p window t)
            (dolist (parameter '(no-other-window no-delete-other-windows ecc-review-talk))
              (set-window-parameter window parameter t))
            (ecc-review-pane-take-down window '(ecc-review-talk))
            (should (window-live-p window))
            (should-not (eq (window-buffer window) pane))
            (should-not (window-dedicated-p window))
            (dolist (parameter '(no-other-window no-delete-other-windows ecc-review-talk))
              (should-not (window-parameter window parameter))))
        (kill-buffer pane)))))

(ert-deftest ecc-review-talk-test-a-pane-name-taken-by-another-review ()
  "Two reviews whose panes would share a name get two panes."
  (ecc-review-talk-test--with-sessions one _two
    (let ((first (ecc-review-talk-test--diff-review one))
          (second (generate-new-buffer "*ecc-review: test*")))
      (with-current-buffer second
        (ecc-review-mode)
        (setq ecc-review--session one))
      (let ((a (ecc-review-pane-buffer first "files" #'ecc-review-files-mode
                                       'ecc-review-files--review))
            (b (ecc-review-pane-buffer second "files" #'ecc-review-files-mode
                                       'ecc-review-files--review)))
        (should-not (eq a b))
        (should (equal (buffer-name a) "*ecc-review-files: test*"))
        (should (eq (buffer-local-value 'ecc-review-files--review b) second))
        (should (eq (ecc-review-pane-buffer first "files" #'ecc-review-files-mode
                                            'ecc-review-files--review)
                    a))
        (kill-buffer a)
        (kill-buffer b))
      (kill-buffer second))))

(ert-deftest ecc-review-talk-test-question-mark-lists-every-key ()
  "? in the diff review lists every key; the header line keeps n/p and d."
  (ecc-review-talk-test--with-sessions one _two
    (with-current-buffer (ecc-review-talk-test--diff-review one)
      (should (eq (key-binding (kbd "?")) #'ecc-review-help))
      (let ((header (ecc-review--header-line)))
        (dolist (key '("n/p hunk" "d delete" "T tour" "t next" "M message" "? all keys"))
          (should (string-search key header))))
      (save-window-excursion
        (ecc-review-help)
        (with-current-buffer (help-buffer)
          (dolist (key '("n / p" "N / P" "RET / o" "{ / }" "C-c C-c" "C-c C-k"
                         "T " "t " "M " "a " "d " "l " "s " "/ " "g " "e "))
            (should (string-search key (buffer-string)))))))))

(ert-deftest ecc-review-talk-test-a-proposal-has-help-of-its-own ()
  "? in the review of a proposal says that C-c C-c denies, and lists e."
  (ecc-review-talk-test--with-sessions one _two
    (let ((review (ecc-review-talk-test--diff-review one)))
      (with-current-buffer review
        (save-window-excursion
          (ecc-review-help)
          (let ((text (with-current-buffer (help-buffer) (buffer-string))))
            (should (string-search "C-u C-c C-c" text))
            (should (string-search "send the comments\n" text))
            (should-not (string-search "deny" text))))
        (setq ecc-review--request (ecc-test-add-request one "Edit"))
        (save-window-excursion
          (ecc-review-help)
          (let ((text (with-current-buffer (help-buffer) (buffer-string))))
            (should (string-search "send the comments as a deny" text))
            (should (string-search "C-u C-c C-c  edit them, then deny" text))
            (should (string-search "e         edit it and apply it" text))
            (should-not (string-search "T         ask for a tour" text))))))))

(provide 'ecc-review-talk-test)

;;; ecc-review-talk-test.el ends here
