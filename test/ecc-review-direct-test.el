;;; ecc-review-direct-test.el --- Tests for ecc-review-direct  -*- lexical-binding: t; -*-

;;; Commentary:

;; The keys of an ediff review in its two windows, point driving the
;; review, and RET opening the file.  The reviews are real ediff
;; sessions laid out with `ediff-setup-windows-plain', which batch can
;; do, over a throwaway repository.  Keys are typed with
;; `execute-kbd-macro', which runs the command loop and so the hooks a
;; key runs; a move of point is a `goto-char' and the hook the command
;; loop would run after it.
;;
;; ediff is given faces, as a graphical Emacs has them: without face
;; support it marks the current difference by writing flags into the
;; text, which moves the point of the window that has the keyboard.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-direct)
(require 'ecc-review-files)
(require 'ecc-session)

;;;; Helpers

(defun ecc-review-direct-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-direct-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defun ecc-review-direct-test--lines (&optional edit)
  "Return sixty lines \"lN\", with EDIT, a function of N, giving other text."
  (mapconcat (lambda (n) (or (and edit (funcall edit n)) (format "l%d\n" n)))
             (number-sequence 1 60) ""))

(defconst ecc-review-direct-test--changed
  (ecc-review-direct-test--lines
   (lambda (n)
     (pcase n
       (3 "l3 changed\n")
       (20 "l20\nadded1\nadded2\n")
       ((or 40 41) "")
       (55 "l55 changed\n"))))
  "a.txt as the session leaves it.  Four differences: line 3 changed, two
lines put in after line 20, lines 40 and 41 taken out, line 55 changed.
On the right, line 21 and 22 are the new ones, and line 55 is line 55
again.")

(defun ecc-review-direct-test--repository (directory &optional extra)
  "Make DIRECTORY a repository with a.txt of sixty lines committed.
EXTRA is a list of (NAME OLD NEW): more files, committed as OLD."
  (ecc-review-direct-test--git directory "init" "-q")
  (ecc-review-direct-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-direct-test--git directory "config" "user.name" "t")
  (ecc-review-direct-test--write (concat directory "a.txt") (ecc-review-direct-test--lines))
  (pcase-dolist (`(,name ,old ,_) extra)
    (ecc-review-direct-test--write (concat directory name) old))
  (ecc-review-direct-test--git directory "add" ".")
  (ecc-review-direct-test--git directory "commit" "-q" "-m" "init"))

(defun ecc-review-direct-test--open (session directory &optional extra)
  "Have SESSION change a.txt in DIRECTORY and open its ediff review.
EXTRA is a list of (NAME OLD NEW): more files, changed from OLD to NEW.
Return the control buffer, with ediff highlighting with faces."
  (ecc-review-direct-test--repository directory extra)
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (ecc-review-direct-test--write (concat directory "a.txt") ecc-review-direct-test--changed)
  (pcase-dolist (`(,name ,_ ,new) extra)
    (ecc-review-direct-test--write (concat directory name) new))
  (let ((control (ecc-review-ediff-buffer session)))
    (with-current-buffer control
      (setq ediff-highlighting-style 'face))
    control))

(defconst ecc-review-direct-test--file-content (symbol-function 'ecc-diff-file-content)
  "`ecc-diff-file-content' itself, which a fake session stands in for.")

(defmacro ecc-review-direct-test--reading-files (&rest body)
  "Run BODY with `ecc-diff-file-content' reading the disk again.
`ecc-test-with-fake-session' makes it read nothing, for the replays of
recorded sessions; RET reads the file a review is of."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'ecc-diff-file-content) ecc-review-direct-test--file-content))
     ,@body))

(defun ecc-review-direct-test--kill-buffers ()
  "Kill every buffer a review left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defvar ecc-review-direct-test--layout 'side-by-side
  "The `ecc-review-ediff-layout' `ecc-review-direct-test--with-review' opens in.")

(defmacro ecc-review-direct-test--with-review (session control &rest body)
  "Run BODY with CONTROL the ediff review of a.txt that SESSION changed.
It is laid out as `ecc-review-direct-test--layout' says."
  (declare (indent 2))
  `(let ((directory (file-name-as-directory (make-temp-file "ecc-review-direct" t)))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (ecc-review-ediff-layout ecc-review-direct-test--layout)
         (ediff-force-faces t)
         (ecc-review-talk-reply-height nil)
         (ecc-review-files-shown nil)
         (,control nil))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (setq ,control (ecc-review-direct-test--open ,session directory))
           ,@body)
       (when (buffer-live-p ,control)
         (ecc-review-ediff-quit ,control))
       (ecc-review-direct-test--kill-buffers)
       (delete-directory directory t))))

(defun ecc-review-direct-test--position (control side line)
  "Return where LINE of a.txt begins on SIDE, `A' or `B', of the review CONTROL."
  (with-current-buffer control
    (ecc-review-ediff--file-position side (cons "a.txt" line))))

(defun ecc-review-direct-test--window (control side)
  "Return the window of SIDE of the review CONTROL."
  (buffer-local-value (if (eq side 'A) 'ediff-window-A 'ediff-window-B) control))

(defun ecc-review-direct-test--line-of (window)
  "Return the line of a.txt the point of WINDOW is on, and the side's name."
  (with-current-buffer (window-buffer window)
    (cdr (with-current-buffer ecc-review--part-of
           (ecc-review-ediff--file-place
            (if (eq (window-buffer window) ediff-buffer-A) 'A 'B)
            (window-point window))))))

(defun ecc-review-direct-test--move (control side line &optional command)
  "Put point on LINE of a.txt on SIDE of CONTROL, as COMMAND would.
SIDE's window is selected and the hook the command loop runs after a
command is run, with `this-command' COMMAND, `next-line' by default."
  (select-window (ecc-review-direct-test--window control side))
  (goto-char (ecc-review-direct-test--position control side line))
  (let ((this-command (or command 'next-line)))
    (run-hooks 'post-command-hook)))

(defun ecc-review-direct-test--type (control side keys)
  "Type KEYS in the window of SIDE of the review CONTROL."
  (select-window (ecc-review-direct-test--window control side))
  (execute-kbd-macro (kbd keys)))

(defun ecc-review-direct-test--row (window)
  "Return how many lines below the top of WINDOW its point is."
  (with-current-buffer (window-buffer window)
    (count-lines (window-start window)
                 (save-excursion (goto-char (window-point window))
                                 (line-beginning-position)))))

;;;; The keys

(ert-deftest ecc-review-direct-test-the-review-opens-in-the-right-window ()
  "The keyboard is in the right window; both windows have the keys and say them."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
      (with-current-buffer control
        (dolist (buffer (list ediff-buffer-A ediff-buffer-B))
          (with-current-buffer buffer
            (should ecc-review-direct-mode)
            (should (eq (key-binding (kbd "c")) #'ecc-review-direct-comment))
            (should (eq (key-binding (kbd "{")) #'ecc-review-direct-relay))
            (should (eq (key-binding (kbd "RET")) #'ecc-review-direct-visit))))
        ;; Two header lines that differ and are one line each: the keys
        ;; are cut in two between the windows.
        (let ((left (buffer-local-value 'header-line-format ediff-buffer-A))
              (right (ecc-review-direct-header-text ediff-buffer-B)))
          (should (stringp left))
          (should (stringp right))
          (should-not (equal left right))
          (should-not (string-search "\n" left))
          (should-not (string-search "\n" right))
          ;; Side by side, the left keys are put at the right edge.
          (should (string-search "n/p diff  j jump  { } comments  c comment" left))
          (should (string-search "RET open  T tour  t next  M message"
                                 (ecc-review-direct--keys 'B)))
          ;; A window of 40 columns keeps the first keys and the help.
          (should (string-search "RET open  T tour" right))
          (should (string-search "? all keys" right))
          ;; Where the review is, on the right one.
          (should (string-search "-/4" right))
          ;; Faces on the string, no font-lock.
          (should (eq (get-text-property 1 'face left) 'bold)))
        ;; The panel says ? and nothing else.
        (should (equal ediff-brief-help-message " ? all keys"))))))

(ert-deftest ecc-review-direct-test-keys-do-what-the-panel-does ()
  "n, j and v in a window do what they do in the panel, and the window keeps the keys."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((right (ecc-review-direct-test--window control 'B)))
        (ecc-review-direct-test--type control 'B "n")
        (should (= (buffer-local-value 'ediff-current-difference control) 0))
        (should (eq (selected-window) right))
        (ecc-review-direct-test--type control 'B "n")
        (should (= (buffer-local-value 'ediff-current-difference control) 1))
        ;; From the left window just the same.
        (ecc-review-direct-test--type control 'A "p")
        (should (= (buffer-local-value 'ediff-current-difference control) 0))
        (should (eq (selected-window) (ecc-review-direct-test--window control 'A)))
        ;; A prefix argument reaches the panel's command: 3j.
        (ecc-review-direct-test--type control 'B "3j")
        (should (= (buffer-local-value 'ediff-current-difference control) 2))
        ;; v and V are ediff's scroll of both windows, run in the control
        ;; buffer with the key that was typed, which is what it reads to
        ;; tell up from down.  How far it scrolls batch cannot say: it
        ;; works from a window end only redisplay knows.
        (let ((calls nil))
          (cl-letf (((symbol-function 'ediff-scroll-vertically)
                     (lambda (&optional _arg)
                       (interactive "P")
                       (push (list (current-buffer) last-command-event) calls))))
            (ecc-review-direct-test--type control 'B "v")
            (ecc-review-direct-test--type control 'A "V"))
          (should (equal (reverse calls) (list (list control ?v) (list control ?V)))))
        (should (eq (selected-window) (ecc-review-direct-test--window control 'A)))))))

(ert-deftest ecc-review-direct-test-a-key-that-lays-out-the-windows-keeps-the-keyboard ()
  "? and | lay ediff's windows out again, selecting the panel; the window gets it back."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--type control 'B "?")
      (with-current-buffer control
        (should ediff-use-long-help-message)
        (should (string-search "Every key works in both windows" (buffer-string))))
      (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
      (ecc-review-direct-test--type control 'B "?")
      (ecc-review-direct-test--type control 'A "|")
      ;; Laid out afresh: the windows are new ones, and the left side's
      ;; has the keyboard, as it had.
      (should (eq (selected-window) (ecc-review-direct-test--window control 'A)))
      (should (eq (window-buffer (selected-window))
                  (buffer-local-value 'ediff-buffer-A control))))))

(ert-deftest ecc-review-direct-test-the-files-pane-from-a-window ()
  "s in a window shows the files pane and leaves the keyboard in the window."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--type control 'B "s")
      (should (ecc-review-files--pane-window control))
      (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
      ;; RET in the pane moves the review and hands the keyboard back to
      ;; the right window.
      (select-window (ecc-review-files--pane-window control))
      (goto-char (point-min))
      (forward-line 1)
      (ecc-review-files-visit)
      (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
      (should (= (buffer-local-value 'ediff-current-difference control) 0)))))

;;;; Comments on a line

(ert-deftest ecc-review-direct-test-c-comments-on-the-line ()
  "c on the left comments on the old line, on the right on the new; not elsewhere."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "about this line")))
        ;; The second of the two lines put in, on the right.
        (ecc-review-direct-test--move control 'B 22)
        (ecc-review-direct-test--type control 'B "c")
        ;; One of the two taken out, on the left.
        (ecc-review-direct-test--move control 'A 41)
        (ecc-review-direct-test--type control 'A "c"))
      (with-current-buffer control
        (let ((notes (sort (copy-sequence ecc-review--notes)
                           (lambda (a b) (< (ecc-review-note-id a) (ecc-review-note-id b))))))
          (should (= (length notes) 2))
          (should (eq (ecc-review-note-side (car notes)) 'new))
          (should (= (ecc-review-note-line (car notes)) 22))
          (should (equal (ecc-review-note-line-text (car notes)) "added2"))
          (should (eq (ecc-review-note-side (cadr notes)) 'old))
          (should (= (ecc-review-note-line (cadr notes)) 41))))
      ;; A line both sides share has nothing to comment on.
      (ecc-review-direct-test--move control 'B 10)
      (select-window (ecc-review-direct-test--window control 'B))
      (should-error (call-interactively #'ecc-review-direct-comment) :type 'user-error))))

(ert-deftest ecc-review-direct-test-x-takes-the-comment-of-the-line ()
  "x in a window removes the comment of the line at point, not another of its difference.
It is d in the diff review; in ediff, d scrolls the reply pane."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "first")))
        (ecc-review-direct-test--move control 'B 21)
        (ecc-review-direct-test--type control 'B "c"))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "second")))
        (ecc-review-direct-test--move control 'B 22)
        (ecc-review-direct-test--type control 'B "c"))
      (ecc-review-direct-test--type control 'B "x")
      (with-current-buffer control
        (should (equal (mapcar #'ecc-review-note-text ecc-review--notes) '("first")))))))

;;;; Point drives the review

(ert-deftest ecc-review-direct-test-point-in-a-difference-makes-it-current ()
  "Moving into a difference selects it, leaves its window alone and aligns the other."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let* ((right (ecc-review-direct-test--window control 'B))
             (left (ecc-review-direct-test--window control 'A)))
        ;; The right window shows line 50 and on.
        (set-window-start right (ecc-review-direct-test--position control 'B 50))
        (let ((start (window-start right)))
          (ecc-review-direct-test--move control 'B 55)
          (should (= (buffer-local-value 'ediff-current-difference control) 3))
          ;; The window being read did not move.
          (should (= (window-start right) start))
          ;; The other is on the same line, as high up.
          (should (= (ecc-review-direct-test--line-of left) 55))
          (should (= (ecc-review-direct-test--row left) (ecc-review-direct-test--row right))))
        ;; The lines put in on the right stand against the place on the
        ;; left they were put in at, which is the line after 20.
        (ecc-review-direct-test--move control 'B 22)
        (should (= (buffer-local-value 'ediff-current-difference control) 1))
        (should (= (ecc-review-direct-test--line-of left) 21))
        ;; A line taken out, against where it was on the right.
        (ecc-review-direct-test--move control 'A 41)
        (should (= (buffer-local-value 'ediff-current-difference control) 2))
        (should (= (ecc-review-direct-test--line-of right) 42))))))

(ert-deftest ecc-review-direct-test-point-between-differences-aligns-by-lines ()
  "In the lines both sides share, the other side is put on the same line of the file.
The current difference stays the one read last."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((left (ecc-review-direct-test--window control 'A))
            (right (ecc-review-direct-test--window control 'B)))
        (ecc-review-direct-test--move control 'B 3)
        (should (= (buffer-local-value 'ediff-current-difference control) 0))
        ;; Line 30 on the right is line 28 on the left: two were put in
        ;; above.  The right window shows it already, as it would once
        ;; redisplay had scrolled to it.
        (set-window-start right (ecc-review-direct-test--position control 'B 26))
        (ecc-review-direct-test--move control 'B 30)
        (should (= (buffer-local-value 'ediff-current-difference control) 0))
        (should (= (ecc-review-direct-test--line-of left) 28))
        (should (= (ecc-review-direct-test--row left) (ecc-review-direct-test--row right)))
        ;; And back from the left: line 50 there is line 50 here, two
        ;; put in and two taken out above it.
        (ecc-review-direct-test--move control 'A 50)
        (should (= (ecc-review-direct-test--line-of right) 50))
        ;; Above every difference, line for line.
        (ecc-review-direct-test--move control 'A 1)
        (should (= (ecc-review-direct-test--line-of right) 1))))))

(ert-deftest ecc-review-direct-test-n-and-p-go-from-point ()
  "Off the current difference, n and p go to the differences around point."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--move control 'B 55)
      (should (= (buffer-local-value 'ediff-current-difference control) 3))
      ;; Up between the first two differences, and n: the second, not
      ;; past the last.
      (ecc-review-direct-test--move control 'B 10)
      (ecc-review-direct-test--type control 'B "n")
      (should (= (buffer-local-value 'ediff-current-difference control) 1))
      (ecc-review-direct-test--move control 'B 10)
      (ecc-review-direct-test--type control 'B "p")
      (should (= (buffer-local-value 'ediff-current-difference control) 0))
      ;; Nothing above: the review stays on the difference it was on.
      (ecc-review-direct-test--move control 'B 1)
      (should-error (ecc-review-direct-previous-difference) :type 'user-error)
      (should (= (buffer-local-value 'ediff-current-difference control) 0))
      ;; Nor below.
      (ecc-review-direct-test--move control 'B 58)
      (should-error (ecc-review-direct-next-difference) :type 'user-error)
      (should (= (buffer-local-value 'ediff-current-difference control) 0))
      ;; From the place on the left where lines were put in on the right,
      ;; that difference is the one n and p go from.
      (ecc-review-direct-test--move control 'A 21)
      (should (= (buffer-local-value 'ediff-current-difference control) 1))
      (ecc-review-direct-test--type control 'A "p")
      (should (= (buffer-local-value 'ediff-current-difference control) 0)))))

(ert-deftest ecc-review-direct-test-isearch-is-followed-when-it-stops ()
  "Characters typed into an isearch move nothing; C-s and the end of it do."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((left (ecc-review-direct-test--window control 'A)))
        (ecc-review-direct-test--move control 'B 1)
        (let ((isearch-mode t))
          ;; A character typed, which put point on line 55.
          (ecc-review-direct-test--move control 'B 55 'isearch-printing-char)
          (should (= (buffer-local-value 'ediff-current-difference control) -1))
          (should (= (ecc-review-direct-test--line-of left) 1))
          ;; C-s to the next match.
          (ecc-review-direct-test--move control 'B 3 'isearch-repeat-forward)
          (should (= (buffer-local-value 'ediff-current-difference control) 0)))
        ;; The search ends on line 55.
        (goto-char (ecc-review-direct-test--position control 'B 55))
        (run-hooks 'isearch-mode-end-hook)
        (should (= (buffer-local-value 'ediff-current-difference control) 3))
        (should (= (ecc-review-direct-test--line-of left) 55))))))

(ert-deftest ecc-review-direct-test-scrolling-one-window-is-not-followed ()
  "C-v moves point in one window; the other is left where it is, for now."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((left (ecc-review-direct-test--window control 'A)))
        (ecc-review-direct-test--move control 'B 1)
        (ecc-review-direct-test--move control 'B 55 'scroll-up-command)
        (should (= (buffer-local-value 'ediff-current-difference control) -1))
        (should (= (ecc-review-direct-test--line-of left) 1))
        ;; The next move goes from there.
        (ecc-review-direct-test--move control 'B 56)
        (should (= (ecc-review-direct-test--line-of left) 56))))))

(ert-deftest ecc-review-direct-test-refining-leaves-the-cursor-alone ()
  "Marking what changed in the differences on the screen does not move point.
ediff goes to each difference it refines, and the point of the right
side is the cursor of the window that has the keyboard."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((right (ecc-review-direct-test--window control 'B)))
        (with-current-buffer control
          (setq ediff-auto-refine 'on))
        (ecc-review-direct-test--move control 'B 10)
        (let ((point (window-point right)))
          (with-current-buffer control
            (should (ecc-review-ediff--refine-shown))
            ;; It did refine: what changed in line 3 is marked.
            (should (ediff-get-fine-diff-vector 0 'B)))
          (should (eq (selected-window) right))
          (should (= (window-point right) point)))
        ;; Nor does point making a difference current.
        (ecc-review-direct-test--move control 'B 55)
        (should (= (ecc-review-direct-test--line-of right) 55))))))

;;;; Opening the file

(ert-deftest ecc-review-direct-test-a-line-is-found-in-the-file ()
  "RET finds the line in the file: on the right as it is, on the left where it stands."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--reading-files
      (with-current-buffer control
        (let ((file (file-truename (expand-file-name "a.txt" directory))))
          (should (equal (ecc-review-direct-source
                          'B (ecc-review-direct-test--position control 'B 22))
                         (cons file 22)))
          ;; A line of the left that both have: where it is on the right.
          (should (equal (ecc-review-direct-source
                          'A (ecc-review-direct-test--position control 'A 30))
                         (cons file 32)))
          ;; A line taken out: where it was.
          (should (equal (ecc-review-direct-source
                          'A (ecc-review-direct-test--position control 'A 40))
                         (cons file 42)))
          ;; The file changed since the review read it: two lines at the
          ;; top move the line down by two.
          (ecc-review-direct-test--write file (concat "top1\ntop2\n" ecc-review-direct-test--changed))
          (should (equal (ecc-review-direct-source
                          'B (ecc-review-direct-test--position control 'B 22))
                         (cons file 24)))))))))

(ert-deftest ecc-review-direct-test-a-review-of-commits-follows-later-changes ()
  "A review of a commit opens a line where it is now, after what came later."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((directory (file-name-as-directory (make-temp-file "ecc-review-direct" t)))
          (ediff-window-setup-function #'ediff-setup-windows-plain)
          (ecc-review-ediff-layout 'side-by-side)
          (ecc-review-talk-reply-height nil)
          (control nil))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (ecc-review-direct-test--repository directory)
            (ecc-review-direct-test--write (concat directory "a.txt")
                                           ecc-review-direct-test--changed)
            (ecc-review-direct-test--git directory "commit" "-q" "-am" "change")
            ;; After the commit, five lines go in at the top.
            (ecc-review-direct-test--write (concat directory "a.txt")
                                           (concat "a\nb\nc\nd\ne\n"
                                                   ecc-review-direct-test--changed))
            (setf (ecc-session-project-root session) directory)
            (setq control (ecc-review-ediff-worktree-buffer session "HEAD^!" directory))
            (ecc-review-direct-test--reading-files
              (with-current-buffer control
                (should (equal (ecc-review-direct-source
                                'B (ecc-review-direct-test--position control 'B 55))
                               (cons (file-truename (expand-file-name "a.txt" directory))
                                     60))))))
        (when (buffer-live-p control)
          (ecc-review-ediff-quit control))
        (ecc-review-direct-test--kill-buffers)
        (delete-directory directory t)))))

(ert-deftest ecc-review-direct-test-ret-opens-the-file-elsewhere ()
  "RET opens the file at the line where the files of a review go, the review as it was."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let* ((windows (window-list))
             (buffers (mapcar #'window-buffer windows))
             (opened nil))
        (cl-letf (((symbol-function 'ecc-review-direct-open-file)
                   (lambda (file line) (setq opened (cons file line)))))
          (ecc-review-direct-test--move control 'B 22)
          (ecc-review-direct-test--type control 'B "RET"))
        (should (equal opened (cons (file-truename (expand-file-name "a.txt" directory)) 22)))
        ;; The frame of a review is never the one files go to.
        (should-not (ecc-review-direct--frame-usable-p (selected-frame)))
        (should (equal (window-list) windows))
        (should (equal (mapcar #'window-buffer (window-list)) buffers))))))

(ert-deftest ecc-review-direct-test-the-file-goes-to-a-frame-used-again ()
  "Files open in one frame of their own, made once and used while it lives."
  (let ((ecc-review-direct--files-frame nil)
        (made 0))
    (save-window-excursion
      (delete-other-windows)
      (let ((ecc-review-direct-make-frame-function
             (lambda () (cl-incf made) (selected-frame)))
            (file (make-temp-file "ecc-review-direct" nil ".txt" "one\ntwo\nthree\n")))
        (unwind-protect
            (progn
              (let ((window (ecc-review-direct-open-file file 2)))
                (should (eq (window-buffer window) (find-buffer-visiting file)))
                (should (= (line-number-at-pos (window-point window)) 2)))
              (ecc-review-direct-open-file file 3)
              (should (= made 1)))
          (when (find-buffer-visiting file)
            (kill-buffer (find-buffer-visiting file)))
          (delete-file file))))))

(ert-deftest ecc-review-direct-test-o-in-the-files-pane-opens-the-file ()
  "o in the files pane opens the file at its first change; RET still moves the review."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((opened nil))
        (with-current-buffer control (ecc-review-files-toggle))
        (select-window (ecc-review-files--pane-window control))
        (goto-char (point-min))
        (forward-line 1)
        (cl-letf (((symbol-function 'ecc-review-direct-open-file)
                   (lambda (file line) (setq opened (cons file line)))))
          (execute-kbd-macro (kbd "o")))
        (should (equal opened (cons (file-truename (expand-file-name "a.txt" directory)) 3)))
        (should (= (buffer-local-value 'ediff-current-difference control) -1))))))

(ert-deftest ecc-review-direct-test-o-in-a-diff-review-opens-beside-the-session ()
  "o in the files pane of a diff review opens the file the way RET on its source does."
  (ecc-test-with-fake-session session
    (let ((opened nil))
      (cl-letf (((symbol-function 'ecc-visit-open)
                 (lambda (path line owner) (setq opened (list path line owner)))))
        (with-temp-buffer
          (setq default-directory temporary-file-directory
                ecc-review--session session)
          (ecc-review-files-open-file (list :path "a.txt"))))
      (should (equal opened (list (expand-file-name "a.txt" temporary-file-directory)
                                  nil session))))))

;;;; Review round 1

(defun ecc-review-direct-test--view (window)
  "Return (POINT . START) of WINDOW."
  (cons (window-point window) (window-start window)))

(ert-deftest ecc-review-direct-test-reading-again-leaves-the-cursor-alone ()
  "Following the files moves no cursor.
Reading the review again selects the difference being read without the
user asking, and ediff refines it by going to it in each side."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((right (ecc-review-direct-test--window control 'B)))
        (with-current-buffer control
          (setq ediff-auto-refine 'on))
        ;; Read on the right, on the last difference of a.txt.
        (ecc-review-direct-test--move control 'B 55)
        (set-window-start right (ecc-review-direct-test--position control 'B 50))
        (let ((view (ecc-review-direct-test--view right)))
          ;; Claude changes a line below the one being read.
          (ecc-review-direct-test--write
           (concat directory "a.txt")
           (replace-regexp-in-string "^l58$" "l58 changed" ecc-review-direct-test--changed))
          (with-current-buffer control
            (ecc-review-reread t)
            (should (= ediff-current-difference 3)))
          (should (equal (ecc-review-direct-test--view right) view)))))))

(defmacro ecc-review-direct-test--with-files (session control extra &rest body)
  "Run BODY with CONTROL the ediff review SESSION made of a.txt and EXTRA.
EXTRA is what `ecc-review-direct-test--open' takes."
  (declare (indent 3))
  `(let ((directory (file-name-as-directory (make-temp-file "ecc-review-direct" t)))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         (ecc-review-ediff-layout 'side-by-side)
         (ediff-force-faces t)
         (ecc-review-talk-reply-height nil)
         (ecc-review-files-shown nil)
         (,control nil))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (setq ,control (ecc-review-direct-test--open ,session directory ,extra))
           ,@body)
       (when (buffer-live-p ,control)
         (ecc-review-ediff-quit ,control))
       (ecc-review-direct-test--kill-buffers)
       (delete-directory directory t))))

(ert-deftest ecc-review-direct-test-a-filter-leaves-the-cursor-alone ()
  "A filter that hides the difference being read moves no cursor.
The review goes to the nearest difference it keeps, which ediff refines
by going to it in each side."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-files session control
        (list (list "b.txt" (ecc-review-direct-test--lines)
                    (ecc-review-direct-test--lines (lambda (n) (and (= n 5) "l5 b\n")))))
      (with-current-buffer control
        (setq ediff-auto-refine 'on))
      (let ((right (ecc-review-direct-test--window control 'B)))
        (ecc-review-direct-test--move control 'B 55)
        (let ((view (ecc-review-direct-test--view right)))
          (with-current-buffer control
            (setq ecc-review--filter "b.txt")
            (let ((ecc-review-files--applying t))
              (ecc-review--draw-notes))
            (ecc-review-files-filter-applied 'changed)
            (should (equal (plist-get (nth ediff-current-difference (ecc-review-units)) :path)
                           "b.txt")))
          (should (equal (ecc-review-direct-test--view right) view)))))))

(ert-deftest ecc-review-direct-test-the-other-side-is-aligned-by-screen-rows ()
  "The two sides are put together by the rows of the screen, not lines.
A line wrapped on one side takes rows the other does not have.  So does
a comment drawn under a line of one side, which batch, drawing no
overlay string, cannot count."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-files session control
        (list (list "c.txt" (ecc-review-direct-test--lines)
                    (ecc-review-direct-test--lines
                     (lambda (n) (and (= n 3) (concat (make-string 200 ?x) "\n"))))))
      (let* ((left (ecc-review-direct-test--window control 'A))
             (right (ecc-review-direct-test--window control 'B))
             (at (lambda (side line)
                   (with-current-buffer control
                     (ecc-review-ediff--file-position side (cons "c.txt" line)))))
             (rows (lambda (window)
                     (with-current-buffer (window-buffer window)
                       (count-screen-lines (window-start window)
                                           (save-excursion
                                             (goto-char (window-point window))
                                             (line-beginning-position))
                                           nil window)))))
        (dolist (window (list left right))
          (with-current-buffer (window-buffer window)
            ;; Batch's side windows are narrower than the 50 columns
            ;; under which `truncate-partial-width-windows' truncates.
            (setq-local truncate-partial-width-windows nil)
            (setq truncate-lines nil)))
        (set-window-start right (funcall at 'B 1))
        (select-window right)
        (goto-char (funcall at 'B 8))
        (let ((this-command 'next-line))
          (run-hooks 'post-command-hook))
        ;; The long line takes rows on the right only.
        (should (> (funcall rows right) 7))
        (should (= (window-point left) (funcall at 'A 8)))
        (should (= (funcall rows left) (funcall rows right)))))))

(ert-deftest ecc-review-direct-test-the-first-command-moves-nothing ()
  "Where ediff put the windows is taken as where they stand together.
The first command after the review opens, or after the files pane hands
the keyboard back, is no move of point."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((left (ecc-review-direct-test--window control 'A))
            (right (ecc-review-direct-test--window control 'B)))
        (with-current-buffer (window-buffer right)
          (should (eql ecc-review-direct--aligned
                       (save-excursion (goto-char (window-point right))
                                       (line-beginning-position)))))
        ;; ediff puts the left side where it will, and C-g leaves it.
        (with-current-buffer control
          (ecc-review-files-goto (car (ecc-review-files-entries)) t))
        (set-window-start left (ecc-review-direct-test--position control 'A 2))
        (let ((view (ecc-review-direct-test--view left)))
          (select-window right)
          (let ((this-command 'keyboard-quit))
            (run-hooks 'post-command-hook))
          (should (equal (ecc-review-direct-test--view left) view)))))))

(ert-deftest ecc-review-direct-test-spc-and-del-and-the-panel-s-ret ()
  "SPC and DEL in a window go on and back, and RET in the panel opens the file."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--type control 'B "SPC")
      (should (= (buffer-local-value 'ediff-current-difference control) 0))
      (ecc-review-direct-test--type control 'B "SPC")
      (ecc-review-direct-test--type control 'B "DEL")
      (should (= (buffer-local-value 'ediff-current-difference control) 0))
      (let ((opened nil))
        (cl-letf (((symbol-function 'ecc-review-direct-open-file)
                   (lambda (file line) (setq opened (cons file line)))))
          (with-current-buffer control
            (ediff-jump-to-difference 2)
            (call-interactively (key-binding (kbd "RET")))))
        (should (equal opened (cons (file-truename (expand-file-name "a.txt" directory)) 21)))))))

(ert-deftest ecc-review-direct-test-the-header-says-the-difference-after-any-change ()
  "Where the review is follows a reading again and a quiet change of difference.
It is at the end of the header line of the right window."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((status (lambda ()
                      (buffer-local-value 'ecc-review-direct--header-status
                                          (buffer-local-value 'ediff-buffer-B control)))))
        (ecc-review-direct-test--move control 'B 55)
        (should (string-suffix-p "  4/4 " (funcall status)))
        ;; Off the difference, n goes from point: the header is told of
        ;; the one n starts from, and then of where n went.
        (ecc-review-direct-test--move control 'B 10)
        (ecc-review-direct-test--type control 'B "n")
        (should (string-suffix-p "  2/4 " (funcall status)))
        ;; A fifth difference, read again: the count follows.
        (ecc-review-direct-test--write
         (concat directory "a.txt")
         (replace-regexp-in-string "^l58$" "l58 changed" ecc-review-direct-test--changed))
        (with-current-buffer control
          (ecc-review-reread t))
        (should (string-match-p "/5 \\'" (funcall status)))))))

(ert-deftest ecc-review-direct-test-a-file-too-large-opens-unshifted ()
  "A file too large to diff a line through opens at the line the review shows."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--reading-files
        (let ((file (file-truename (expand-file-name "a.txt" directory)))
              (ecc-diff-max-file-size 10))
          (ecc-review-direct-test--write file (concat "top1\ntop2\n" ecc-review-direct-test--changed))
          (with-current-buffer control
            (should (equal (ecc-review-direct-source
                            'B (ecc-review-direct-test--position control 'B 22))
                           (cons file 22)))))))))

(ert-deftest ecc-review-direct-test-a-file-through-a-link-is-the-buffer-visiting-it ()
  "A file opened by another name of a directory is the buffer that visits it.
/tmp is a link to /private/tmp on macOS, and the file opened again under
the other name said the two were one file."
  (let* ((real (file-name-as-directory (file-truename (make-temp-file "ecc-review-direct" t))))
         (link (concat (directory-file-name real) "-link"))
         (file (concat real "a.txt"))
         (messages nil))
    (unwind-protect
        (progn
          (ecc-review-direct-test--write file "one\ntwo\n")
          (make-symbolic-link real link)
          (let ((visiting (find-file-noselect file)))
            (save-window-excursion
              (cl-letf (((symbol-function 'ecc-review-direct--file-window)
                         (lambda () (selected-window)))
                        ((symbol-function 'message)
                         (lambda (format &rest args)
                           (push (apply #'format-message format args) messages))))
                (let ((window (ecc-review-direct-open-file (concat link "/a.txt") 2)))
                  (should (eq (window-buffer window) visiting)))))
            (should-not (seq-find (lambda (text) (string-search "same file" text)) messages))
            (kill-buffer visiting)))
      (delete-file link)
      (delete-directory real t))))

;;;; Review round 2

(ert-deftest ecc-review-direct-test-a-comment-above-the-line-counts-its-rows ()
  "The rows of a comment drawn right above a line are counted, on both sides.
`count-screen-lines' leaves out the strings at the end of what it
counts, and batch draws no overlay string at all: what is counted here
is the review's own count of them (`ecc-review-direct--strings-rows')."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((left (ecc-review-direct-test--window control 'A))
            (right (ecc-review-direct-test--window control 'B)))
        (with-current-buffer control
          (ecc-review-add-note 'user "first\nsecond"
                               (seq-find (lambda (line) (and (eq (plist-get line :side) 'new)
                                                             (eql (plist-get line :line) 3)))
                                         (ecc-review-lines)))
          (ecc-review--draw-notes))
        (let* ((bol (lambda (side line) (ecc-review-direct-test--position control side line)))
               (strings (with-current-buffer (window-buffer right)
                          (ecc-review-direct--strings-rows right (funcall bol 'B 4)))))
          ;; The comment is under line 3 of the right side: above line 4.
          (should (> strings 0))
          (set-window-start right (funcall bol 'B 1))
          (with-current-buffer (window-buffer right)
            (should (= (ecc-review-direct--rows right (funcall bol 'B 4))
                       (+ 3 strings))))
          ;; Point on line 4 of the left: the right side's line 4 is put on
          ;; the same row, its comment counted.
          (set-window-start left (funcall bol 'A 1))
          (ecc-review-direct-test--move control 'A 6)
          (ecc-review-direct-test--move control 'A 4)
          (should (= (with-current-buffer (window-buffer left)
                       (ecc-review-direct--rows left (funcall bol 'A 4)))
                     (with-current-buffer (window-buffer right)
                       (ecc-review-direct--rows right (funcall bol 'B 4))))))))))

(ert-deftest ecc-review-direct-test-a-far-move-does-not-walk-the-screen ()
  "Far from the window the two sides are put together by lines of the buffer.
Walking the display over the whole distance stalled a large review."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((right (ecc-review-direct-test--window control 'B))
            (walked 0)
            (count (symbol-function 'count-screen-lines))
            (motion (symbol-function 'vertical-motion)))
        (set-window-start right (ecc-review-direct-test--position control 'B 1))
        (ecc-review-direct-test--move control 'B 2)
        (cl-letf (((symbol-function 'count-screen-lines)
                   (lambda (&rest args) (cl-incf walked) (apply count args)))
                  ((symbol-function 'vertical-motion)
                   (lambda (&rest args) (cl-incf walked) (apply motion args))))
          ;; Sixty lines down from a window of a dozen.
          (ecc-review-direct-test--move control 'B 58 'end-of-buffer)
          (should (zerop walked))
          (should (= (ecc-review-direct-test--line-of (ecc-review-direct-test--window control 'A))
                     58))
          ;; Next to point, the screen is counted.
          (set-window-start right (ecc-review-direct-test--position control 'B 55))
          (ecc-review-direct-test--move control 'B 56)
          (should (> walked 0)))))))

(ert-deftest ecc-review-direct-test-a-move-above-the-window-goes-as-far-on-both ()
  "Point moved above the start of its window puts the other side as far above.
Redisplay then scrolls the two the same way; the other side's line was
put at the very top of its window instead."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((left (ecc-review-direct-test--window control 'A))
            (right (ecc-review-direct-test--window control 'B))
            (above (lambda (window)
                     (with-current-buffer (window-buffer window)
                       (count-lines (save-excursion (goto-char (window-point window))
                                                    (line-beginning-position))
                                    (window-start window))))))
        (set-window-start right (ecc-review-direct-test--position control 'B 50))
        (ecc-review-direct-test--move control 'B 52)
        ;; Three lines above the start of the right window.
        (ecc-review-direct-test--move control 'B 47)
        (should (= (ecc-review-direct-test--line-of left) 47))
        (should (= (funcall above right) 3))
        (should (= (funcall above left) 3))))))

(ert-deftest ecc-review-direct-test-a-visiting-buffer-too-large-opens-unshifted ()
  "The size limit holds for a buffer visiting the file as for the file on disk."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--reading-files
        (let* ((file (file-truename (expand-file-name "a.txt" directory)))
               (buffer (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (insert "top1\ntop2\n"))
                (with-current-buffer control
                  (should (equal (ecc-review-direct-source
                                  'B (ecc-review-direct-test--position control 'B 22))
                                 (cons file 24)))
                  (let ((ecc-diff-max-file-size 10))
                    (should (equal (ecc-review-direct-source
                                    'B (ecc-review-direct-test--position control 'B 22))
                                   (cons file 22))))))
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))))

(ert-deftest ecc-review-direct-test-v-does-not-change-the-difference ()
  "v puts the other side against point again and selects no difference.
The scroll may drag point into another difference; a scroll is not followed."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--move control 'B 3)
      (should (= (buffer-local-value 'ediff-current-difference control) 0))
      (let ((target (ecc-review-direct-test--position control 'B 55)))
        (cl-letf (((symbol-function 'ediff-scroll-vertically)
                   (lambda (&optional _arg)
                     (interactive "P")
                     (with-selected-window ediff-window-B
                       (goto-char target)))))
          (ecc-review-direct-test--type control 'B "v")))
      (should (= (buffer-local-value 'ediff-current-difference control) 0))
      (should (= (ecc-review-direct-test--line-of (ecc-review-direct-test--window control 'A))
                 55)))))

(ert-deftest ecc-review-direct-test-putting-back-sets-only-what-moved ()
  "Nothing that did not move is set again: no window is marked for redisplay."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((set 0))
        (with-current-buffer control
          (let ((places (ecc-review-ediff--places)))
            (cl-letf (((symbol-function 'set-window-start)
                       (lambda (&rest _) (cl-incf set)))
                      ((symbol-function 'set-window-point)
                       (lambda (&rest _) (cl-incf set))))
              (ecc-review-ediff--put-back places))))
        (should (zerop set))))))

(ert-deftest ecc-review-direct-test-the-header-is-written-once-a-change ()
  "Point going into a new difference writes the header lines once."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((writes 0)
            (write (symbol-function 'ecc-review-direct-refresh-headers)))
        (cl-letf (((symbol-function 'ecc-review-direct-refresh-headers)
                   (lambda (control) (cl-incf writes) (funcall write control))))
          (ecc-review-direct-test--move control 'B 22))
        (should (= (buffer-local-value 'ediff-current-difference control) 1))
        (should (= writes 1))))))

(ert-deftest ecc-review-direct-test-what-cannot-be-followed-is-told-apart ()
  "An unreadable file opens unshifted and says why; a directory is refused."
  (skip-unless (and (executable-find "git") (not (zerop (user-uid)))))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--reading-files
        (let ((file (file-truename (expand-file-name "a.txt" directory)))
              (said nil))
          (with-current-buffer control
            (unwind-protect
                (progn
                  (set-file-modes file 0)
                  (cl-letf (((symbol-function 'message)
                             (lambda (format &rest args)
                               (push (apply #'format-message format args) said))))
                    (should (equal (ecc-review-direct-source
                                    'B (ecc-review-direct-test--position control 'B 22))
                                   (cons file 22))))
                  (should (seq-find (lambda (text) (string-search "cannot be read" text)) said)))
              (set-file-modes file #o644))
            (delete-file file)
            (make-directory file)
            (should-error (ecc-review-direct-source
                           'B (ecc-review-direct-test--position control 'B 22))
                          :type 'user-error)))))))

(ert-deftest ecc-review-direct-test-a-deletion-at-the-end-opens-its-own-file ()
  "RET on lines taken out at the end of a file opens that file, not the next.
With no blank line between files, the place of such a difference on the
right is the separator of the next file."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((ecc-review-ediff-file-spacing 0))
      (ecc-review-direct-test--with-files session control
          (list (list "c.txt" "one\ntwo\nthree\n" "one\ntwo\n")
                (list "d.txt" "x\n" "y\n"))
        (let ((opened nil))
          (with-current-buffer control
            (let ((unit (seq-find (lambda (unit) (equal (plist-get unit :path) "c.txt"))
                                  (ecc-review-units))))
              (ediff-jump-to-difference (1+ (plist-get unit :number)))
              (cl-letf (((symbol-function 'ecc-review-direct-open-file)
                         (lambda (file line) (setq opened (cons file line)))))
                (call-interactively (key-binding (kbd "RET"))))))
          (should (equal (file-name-nondirectory (car opened)) "c.txt"))
          ;; Where the line was: after the two that are left.
          (should (equal (cdr opened) 3)))))))

(ert-deftest ecc-review-direct-test-the-docstrings-show-their-quotes ()
  "No docstring of this work shows the stray = of a single-escaped quote.
Nor a key command written with one backslash, which reads as itself."
  (require 'ecc-review-menu)
  (dolist (function '(ecc-visit-open ecc-visit-shift-through ecc-review--read-comment
                      ecc-review-ediff--compute-differences
                      ecc-review-menu--start-session ecc-review-ediff--keep-it-plain
                      ecc-review-ediff--hide-the-panel ecc-review-direct--header-line
                      ecc-review-talk--in-frame ecc-review-talk--side))
    (let ((text (documentation function)))
      (should-not (string-match-p "=['’]" text))
      (should-not (string-match-p "\\[[a-z-]+\\]" text)))))

(ert-deftest ecc-review-direct-test-a-whole-file-hunk ()
  "A file diff calls binary is the hunk that takes it all out and puts it all in."
  (should (equal (ecc-review-ediff--whole-file "a\nb\n" "c\n") "1,2c1,1"))
  (should (equal (ecc-review-ediff--whole-file "" "c\n") "0a1,1"))
  (should (equal (ecc-review-ediff--whole-file "a\n" "") "1,1d0")))

;;;; Two sessions

(ert-deftest ecc-review-direct-test-each-window-drives-its-own-review ()
  "With two sessions' reviews open, a key in one review's window reaches that review."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session one
    (let ((two (ecc-model-create-session :name "two" :project-root temporary-file-directory)))
      (unwind-protect
          (ecc-review-direct-test--with-review one first
            (let ((directory (file-name-as-directory (make-temp-file "ecc-review-direct" t)))
                  (second nil))
              (unwind-protect
                  (progn
                    (setq second (ecc-review-direct-test--open two directory))
                    (should (eq (selected-window) (ecc-review-direct-test--window second 'B)))
                    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "two's")))
                      (ecc-review-direct-test--move second 'B 22)
                      (ecc-review-direct-test--type second 'B "c"))
                    (ecc-review-direct-test--type second 'B "n")
                    (should (= (buffer-local-value 'ediff-current-difference second) 2))
                    (should (= (buffer-local-value 'ediff-current-difference first) -1))
                    (should (= (length (buffer-local-value 'ecc-review--notes second)) 1))
                    (should-not (buffer-local-value 'ecc-review--notes first)))
                (when (buffer-live-p second)
                  (ecc-review-ediff-quit second))
                (delete-directory directory t))))
        (ecc-test-cleanup-session two)))))

;;;; The layouts

(defun ecc-review-direct-test--align-to (header)
  "Return the :align-to of the first stretch of space in HEADER, or nil."
  (let ((at (text-property-not-all 0 (length header) 'display nil header)))
    (and at (plist-get (cdr (get-text-property at 'display header)) :align-to))))

(ert-deftest ecc-review-direct-test-stacked-sides-are-aligned-by-rows ()
  "One above the other, the line against point is at the same height in both windows."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((ecc-review-direct-test--layout 'stacked))
      (ecc-review-direct-test--with-review session control
        (let ((left (ecc-review-direct-test--window control 'A))
              (right (ecc-review-direct-test--window control 'B)))
          (should (< (cadr (window-edges left)) (cadr (window-edges right))))
          (set-window-start right (ecc-review-direct-test--position control 'B 20))
          (ecc-review-direct-test--move control 'B 24)
          (should (= (ecc-review-direct-test--line-of left) 22))
          (should (= (ecc-review-direct-test--row left) (ecc-review-direct-test--row right)))
          ;; And from the window above.
          (ecc-review-direct-test--move control 'A 10)
          (should (= (ecc-review-direct-test--line-of right) 10))
          (should (= (ecc-review-direct-test--row left) (ecc-review-direct-test--row right))))))))

(ert-deftest ecc-review-direct-test-the-left-keys-meet-the-right-ones-side-by-side ()
  "Side by side the left header is at the right edge; stacked, both are at the left.
| from a window changes it, and keeps the keyboard there."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((ecc-review-direct-test--layout 'stacked))
      (ecc-review-direct-test--with-review session control
        (let ((header (lambda (side)
                        (ecc-review-direct-header-text
                         (buffer-local-value (if (eq side 'A) 'ediff-buffer-A 'ediff-buffer-B)
                                             control)))))
          (should (string-prefix-p " n/p diff" (funcall header 'A)))
          (should-not (ecc-review-direct-test--align-to (funcall header 'A)))
          (ecc-review-direct-test--type control 'B "|")
          (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
          (should (< (car (window-edges (ecc-review-direct-test--window control 'A)))
                     (car (window-edges (ecc-review-direct-test--window control 'B)))))
          (let ((left (funcall header 'A)))
            (should (equal (ecc-review-direct-test--align-to left)
                           `(- right ,(1+ (string-width (ecc-review-direct--keys 'A))))))
            (should (string-suffix-p "/ filter " left)))
          ;; The right one is not moved.
          (should (string-search "RET open" (funcall header 'B)))
          (ecc-review-direct-test--type control 'B "|")
          (should-not (ecc-review-direct-test--align-to (funcall header 'A))))))))

(ert-deftest ecc-review-direct-test-the-panel-is-out-of-sight ()
  "The control panel is on the screen only while ? shows the long help.
Without it ediff finds the layout it made: n, p, j, v and C-l lay
nothing out, and | and ? once each, the reply pane and the files pane
with them; reading again and q work as ever."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((ecc-review-direct-test--layout 'stacked)
          (ecc-review-talk-reply-width 20)
          (ecc-review-talk-min-diff-width 40))
      (ecc-review-direct-test--with-review session control
        (let ((ecc-review-talk-reply-height 4)
              (ecc-review-files-shown t)
              (ecc-review-files-width 10)
              (layouts 0)
              (panel (lambda () (get-buffer-window control))))
          (ecc-review-files--show control)
          (should (eq (window-parameter (ecc-review-talk--show-pane control) 'window-side)
                      'right))
          (cl-letf* ((plain (symbol-function 'ediff-setup-windows-plain))
                     ((symbol-function 'ediff-setup-windows-plain)
                      (lambda (&rest args) (cl-incf layouts) (apply plain args))))
            (should-not (funcall panel))
            (dolist (key '("n" "n" "p" "j" "v" "C-l"))
              (ecc-review-direct-test--type control 'B key))
            (should (zerop layouts))
            (should-not (funcall panel))
            (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
            (ecc-review-direct-test--type control 'B "?")
            (should (= layouts 1))
            (should (window-live-p (funcall panel)))
            (should (eq (window-parameter (funcall panel) 'mode-line-format) 'none))
            (should (string-search "Every key works"
                                   (with-current-buffer control (buffer-string))))
            (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
            (ecc-review-direct-test--type control 'B "?")
            (should (= layouts 2))
            (should-not (funcall panel))
            (ecc-review-direct-test--type control 'B "|")
            (should (= layouts 3))
            (should-not (funcall panel))
            (should (ecc-review-files--pane-window control))
            (should (get-buffer-window (buffer-local-value 'ecc-review-talk--pane control)))
            (ecc-review-direct-test--type control 'B "n")
            (should (= layouts 3))
            (with-current-buffer control
              (ecc-review-reread t))
            (should (= layouts 3))
            (should-not (funcall panel))
            (ecc-review-direct-test--type control 'B "q")
            (should-not (buffer-live-p control))))))))

;;;; Fixes after review

(ert-deftest ecc-review-direct-test-a-narrow-window-shows-the-status-first ()
  "Too narrow for every key, the right header keeps ? and the status, dropping keys before ?.
Wide enough, the status is at the right end, after every key; too narrow
even for ? and the status, it starts with the status."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--move control 'B 55)
      (let ((buffer (buffer-local-value 'ediff-buffer-B control))
            (window (ecc-review-direct-test--window control 'B)))
        (should (equal (buffer-local-value 'header-line-format buffer)
                       '(:eval (ecc-review-direct--header-line))))
        (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 200)))
          (let ((text (ecc-review-direct-header-text buffer window)))
            (should (string-prefix-p " RET open" text))
            (should (string-search "! reread  ? all keys" text))
            (should (string-suffix-p "  4/4 " text))))
        (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 40)))
          (let ((text (ecc-review-direct-header-text buffer window)))
            (should (string-prefix-p " RET open  T tour  ? all keys" text))
            (should-not (string-search "reread" text))
            (should (string-suffix-p "  4/4 " text))))
        (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 15)))
          (let ((text (ecc-review-direct-header-text buffer window)))
            (should (string-prefix-p " 4/4 " text))
            (should (string-search "RET open" text))))))))

(ert-deftest ecc-review-direct-test-a-stacked-160-column-frame-keeps-the-help ()
  "Stacked in a frame of 160 columns, beside the reply pane, ? and the status are in the header.
Batch has a frame of 80 columns: the width the right window has there
is given to the header line."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let* ((buffer (buffer-local-value 'ediff-buffer-B control))
             (window (ecc-review-direct-test--window control 'B))
             ;; The frame less the pane and the scroll bar of the window.
             (width (- 160 (default-value 'ecc-review-talk-reply-width) 1)))
        (cl-letf (((symbol-function 'window-width) (lambda (&rest _) width)))
          (let ((text (ecc-review-direct-header-text buffer window)))
            (should (string-search "? all keys" text))
            (should (string-suffix-p "  -/4 " text))
            (should (string-search "C-c C-c send" text))
            (should (<= (string-width text) width))))))))

(ert-deftest ecc-review-direct-test-the-right-header-is-fitted-once-a-width ()
  "Drawing the right header line again at the same width fits the keys no more.
Another width, other keys or another status fit them again, and at any
width what is drawn, keys and status, is no wider than the window."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let* ((buffer (buffer-local-value 'ediff-buffer-B control))
             (window (ecc-review-direct-test--window control 'B))
             (width 60)
             (fitted 0)
             (fit (symbol-function 'ecc-review-direct--fit-keys)))
        (cl-letf (((symbol-function 'window-width) (lambda (&rest _) width))
                  ((symbol-function 'ecc-review-direct--fit-keys)
                   (lambda (&rest args) (cl-incf fitted) (apply fit args))))
          (let ((text (ecc-review-direct-header-text buffer window)))
            (should (= fitted 1))
            (should (equal (ecc-review-direct-header-text buffer window) text))
            (should (= fitted 1))
            (setq width 70)
            (ecc-review-direct-header-text buffer window)
            (should (= fitted 2))
            ;; The difference changes: so does the status.
            (ecc-review-direct-test--move control 'B 55)
            (ecc-review-direct-header-text buffer window)
            (should (= fitted 3))))
        (dolist (columns (number-sequence 25 120 5))
          (cl-letf (((symbol-function 'window-width) (lambda (&rest _) columns)))
            (let ((text (ecc-review-direct-header-text buffer window)))
              (should (string-search "? all keys" text))
              ;; The space aligned to the status takes no room where the
              ;; keys reach it already; it is not counted.
              (should (<= (- (string-width text)
                             (cl-count-if (lambda (at) (get-text-property at 'display text))
                                          (number-sequence 0 (1- (length text)))))
                          columns)))))))))

;; A command that leaves the keyboard elsewhere on purpose, run through
;; the relay.
(defun ecc-review-direct-test--to-the-left ()
  "Select the left window of the review, as a command that means to."
  (interactive)
  (select-window ediff-window-A))

(ert-deftest ecc-review-direct-test-an-old-hidden-panel-takes-no-keyboard ()
  "A panel hidden by an earlier layout does not pull the keyboard back after a command."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      ;; As a layout no key asked for leaves it: the opening, a move of Claude's.
      (with-current-buffer control
        (setq ecc-review-direct--panel-had-the-keyboard t))
      (select-window (ecc-review-direct-test--window control 'B))
      (ecc-review-direct--run control #'ecc-review-direct-test--to-the-left)
      (should (eq (selected-window) (ecc-review-direct-test--window control 'A)))
      (should-not (buffer-local-value 'ecc-review-direct--panel-had-the-keyboard control)))))

;; ediff's own toggle, which is not bound in a review.
(declare-function ediff-toggle-multiframe "ediff-util" ())

(ert-deftest ecc-review-direct-test-going-back-from-the-message-keeps-the-panel-hidden ()
  "C-c C-k in the message of an ediff review goes back with the panel hidden, B selected.
C-c C-c there sends and closes the review."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--move control 'B 3)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Why?")))
        (ecc-review-direct-test--type control 'B "c"))
      (with-current-buffer control
        (ecc-review-send t))
      (with-current-buffer (window-buffer (selected-window))
        (should (derived-mode-p 'ecc-review-message-mode))
        (ecc-review-message-cancel))
      (should-not (get-buffer-window control))
      (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
      (with-current-buffer control
        (ecc-review-send t))
      (with-current-buffer (window-buffer (selected-window))
        (ecc-review-message-send))
      (should-not (buffer-live-p control))
      (should-not (get-buffer-window control)))))

(ert-deftest ecc-review-direct-test-multiframe-asked-of-every-ediff-leaves-a-review-plain ()
  "`ediff-toggle-multiframe', which sets every ediff session, leaves a review laid out plain.
The panel stays out of sight, and nothing fails at the next layout."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((default (default-value 'ediff-window-setup-function)))
        (unwind-protect
            (progn
              ;; What the toggle does to the sessions, without its check
              ;; for a graphical Emacs.
              (setq-default ediff-window-setup-function #'ediff-setup-windows-multiframe)
              (with-current-buffer control
                (setq ediff-window-setup-function #'ediff-setup-windows-multiframe
                      ediff-window-B nil))
              ;; ediff forgot its right window: n from there lays out.
              ;; As a graphical Emacs: in a terminal ediff lays out plain
              ;; whatever it was asked.
              (select-window (get-buffer-window (buffer-local-value 'ediff-buffer-B control)))
              (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
                (execute-kbd-macro (kbd "n")))
              (with-current-buffer control
                (should (eq ediff-window-setup-function #'ediff-setup-windows-plain))
                (should-not (frame-live-p ediff-control-frame)))
              (should-not (get-buffer-window control))
              (ecc-review-direct-test--type control 'B "|")
              (should-not (get-buffer-window control)))
          (setq-default ediff-window-setup-function default))))))

(ert-deftest ecc-review-direct-test-a-review-opened-from-another-ediff-is-plain ()
  "A review opened with another ediff's control buffer current is laid out plain at once.
That buffer has a value of its own, which a `let' would have bound
instead, and the review would be laid out first with the user's default."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((other (generate-new-buffer "*other ediff control*"))
          (default (default-value 'ediff-window-setup-function))
          (asked nil))
      (unwind-protect
          (progn
            (setq-default ediff-window-setup-function #'ediff-setup-windows-multiframe)
            (with-current-buffer other
              (setq-local ediff-window-setup-function #'ediff-setup-windows-multiframe))
            (cl-letf* ((open (symbol-function 'ecc-review-ediff-open))
                       ((symbol-function 'ecc-review-ediff-open)
                        (lambda (&rest args)
                          ;; The user's default -- the review helper binds
                          ;; its own -- and the other ediff's panel is the
                          ;; window selected.
                          (setq-default ediff-window-setup-function
                                        #'ediff-setup-windows-multiframe)
                          (set-window-buffer (selected-window) other)
                          (with-current-buffer other (apply open args))))
                       (setup (symbol-function 'ediff-setup-windows))
                       ((symbol-function 'ediff-setup-windows)
                        (lambda (a b c control)
                          ;; What ediff reads, before a terminal makes it plain.
                          (push (buffer-local-value 'ediff-window-setup-function control) asked)
                          (funcall setup a b c control))))
              (ecc-review-direct-test--with-review session control
                (should (equal (delete-dups asked) (list #'ediff-setup-windows-plain)))
                (should-not (get-buffer-window control)))))
        (setq-default ediff-window-setup-function default)
        (kill-buffer other)))))

(ert-deftest ecc-review-direct-test-a-header-changed-is-drawn-again ()
  "Each change of what the right header line reads asks for it to be drawn again.
The status, the keys, and the construct itself; nothing changed asks
for nothing."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((buffer (buffer-local-value 'ediff-buffer-B control))
            (asked 0))
        (cl-letf (((symbol-function 'force-mode-line-update)
                   (lambda (&rest _) (cl-incf asked))))
          (ecc-review-direct-refresh-headers control)
          (should (= asked 0))
          (with-current-buffer buffer
            (setq ecc-review-direct--header-keys ""))
          (ecc-review-direct-refresh-headers control)
          (should (= asked 1))
          (with-current-buffer buffer
            (setq header-line-format nil))
          (ecc-review-direct-refresh-headers control)
          (should (= asked 2))
          (with-current-buffer buffer
            (setq ecc-review-direct--header-status nil))
          (ecc-review-direct-refresh-headers control)
          (should (= asked 3)))))))

;;; ecc-review-direct-test.el ends here
