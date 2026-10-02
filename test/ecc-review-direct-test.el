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

(defmacro ecc-review-direct-test--with-review (session control &rest body)
  "Run BODY with CONTROL the ediff review of a.txt that SESSION changed."
  (declare (indent 2))
  `(let ((directory (file-name-as-directory (make-temp-file "ecc-review-direct" t)))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
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
              (right (buffer-local-value 'header-line-format ediff-buffer-B)))
          (should (stringp left))
          (should (stringp right))
          (should-not (equal left right))
          (should-not (string-search "\n" left))
          (should-not (string-search "\n" right))
          (should (string-prefix-p " n/p diff  j jump  { } comments  c comment" left))
          (should (string-prefix-p " RET open  T tour  t next  M message" right))
          (should (string-search "? all keys" right))
          ;; Faces on the string, no font-lock.
          (should (eq (get-text-property 1 'face left) 'bold)))
        ;; The panel is the state now: no key but ?.
        (should (string-match-p "\\` [0-9]+ differences, none selected   \\? all keys\\'"
                                ediff-brief-help-message))))))

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

(ert-deftest ecc-review-direct-test-d-takes-the-comment-of-the-line ()
  "d in a window removes the comment of the line at point, not another of its difference."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "first")))
        (ecc-review-direct-test--move control 'B 21)
        (ecc-review-direct-test--type control 'B "c"))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "second")))
        (ecc-review-direct-test--move control 'B 22)
        (ecc-review-direct-test--type control 'B "c"))
      (ecc-review-direct-test--type control 'B "d")
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

(ert-deftest ecc-review-direct-test-the-panel-says-the-difference-after-any-change ()
  "The status of the panel follows a reading again and a quiet change of difference."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (ecc-review-direct-test--move control 'B 55)
      (should (string-search "Difference 4 of 4" (with-current-buffer control (buffer-string))))
      ;; Off the difference, n goes from point: the panel is told of the
      ;; one n starts from, and then of where n went.
      (ecc-review-direct-test--move control 'B 10)
      (ecc-review-direct-test--type control 'B "n")
      (should (string-search "Difference 2 of 4" (with-current-buffer control (buffer-string))))
      ;; A fifth difference, read again: the count follows.
      (ecc-review-direct-test--write
       (concat directory "a.txt")
       (replace-regexp-in-string "^l58$" "l58 changed" ecc-review-direct-test--changed))
      (with-current-buffer control
        (ecc-review-reread t)
        (should (string-search "of 5" (buffer-string)))))))

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

(ert-deftest ecc-review-direct-test-the-panel-is-written-once-a-change ()
  "Point going into a new difference writes the panel once."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((writes 0)
            (write (symbol-function 'ecc-review-ediff--write-help)))
        (cl-letf (((symbol-function 'ecc-review-ediff--write-help)
                   (lambda () (cl-incf writes) (funcall write))))
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
  "No docstring of this work shows the stray = of a single-escaped quote."
  (dolist (function '(ecc-visit-open ecc-visit-shift-through ecc-review--read-comment
                      ecc-review-ediff--compute-differences))
    (let ((text (documentation function)))
      (should-not (string-match-p "=['’]" text)))))

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

;;; ecc-review-direct-test.el ends here
