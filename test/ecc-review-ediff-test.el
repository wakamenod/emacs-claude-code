;;; ecc-review-ediff-test.el --- Tests for ecc-review-ediff  -*- lexical-binding: t; -*-

;;; Commentary:

;; The concatenated buffers, the trees each review compares, a comment
;; on a difference turned into the prompt, and sending it.  Every test
;; drives ediff by hand with `ediff-setup-windows-plain', which works in
;; batch; the git cases build a throwaway repository the way
;; `ecc-review-test' does.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-session)

;;;; Helpers

;; `ecc-review-test.el' has the same three, under its own prefix: the
;; test files are loaded one after the other and each has to stand on
;; its own, so the helpers are not shared between them.

(defmacro ecc-review-ediff-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-review-ediff" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-ediff-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-ediff-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defun ecc-review-ediff-test--kill-buffers ()
  "Kill every buffer a review left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defmacro ecc-review-ediff-test--with-ediff (&rest body)
  "Run BODY with ediff laying its windows out the way batch can."
  (declare (indent 0))
  `(let ((ediff-window-setup-function #'ediff-setup-windows-plain))
     ,@body))

(defmacro ecc-review-ediff-test--with-ediff-and-no-pane (&rest body)
  "Run BODY as `ecc-review-ediff-test--with-ediff' does, without the reply pane.
For what counts on being on the screen at once: the pane takes lines a
batch frame, 24 of them, does not have to spare."
  (declare (indent 0))
  `(let ((ecc-review-talk-reply-height nil))
     (ecc-review-ediff-test--with-ediff ,@body)))

(defun ecc-review-ediff-test--repository (directory)
  "Make DIRECTORY a git repository with one commit of x.txt and gone.txt."
  (ecc-review-ediff-test--git directory "init" "-q")
  (ecc-review-ediff-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-ediff-test--git directory "config" "user.name" "t")
  (ecc-review-ediff-test--write (concat directory "x.txt") "one\n")
  (ecc-review-ediff-test--write (concat directory "gone.txt") "bye\n")
  (ecc-review-ediff-test--git directory "add" "x.txt" "gone.txt")
  (ecc-review-ediff-test--git directory "commit" "-q" "-m" "init"))

(defun ecc-review-ediff-test--quit (control)
  "Quit the review in CONTROL, leaving nothing behind."
  (when (buffer-live-p control)
    (ecc-review-ediff-quit control))
  (ecc-review-ediff-test--kill-buffers))

;;;; The concatenated buffers

(ert-deftest ecc-review-ediff-test-one-session-for-every-file ()
  "Every changed file goes into the two buffers under the same separator."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                ;; The session changes one file, makes one and deletes one.
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (ecc-review-ediff-test--write (concat directory "made.txt") "new\n")
                (delete-file (concat directory "gone.txt"))
                (setq control (ecc-review-ediff-buffer session))
                (should (buffer-live-p control))
                (with-current-buffer control
                  (should (derived-mode-p 'ediff-mode))
                  (should (eq ecc-review--session session))
                  (let ((base (car ecc-review-ediff--buffers))
                        (now (cdr ecc-review-ediff--buffers))
                        (sections ecc-review-ediff--sections))
                    (should (equal (buffer-name base) "*ecc-review-base: test*"))
                    (should (equal (buffer-name now) "*ecc-review-now: test*"))
                    ;; One separator per file, in the order git reports.
                    (should (equal (mapcar #'car sections)
                                   '("gone.txt" "made.txt" "x.txt")))
                    ;; A blank line in front of every file but the first.
                    (should (equal (with-current-buffer base
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                                   (concat "═══ gone.txt ═══\nbye\n"
                                           "\n═══ made.txt ═══\n"
                                           "\n═══ x.txt ═══\none\n")))
                    (should (equal (with-current-buffer now
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                                   (concat "═══ gone.txt ═══\n"
                                           "\n═══ made.txt ═══\nnew\n"
                                           "\n═══ x.txt ═══\ntwo\n")))
                    ;; The separator lines are where the sections say.
                    (pcase-dolist (`(,path ,base-line ,now-line) sections)
                      (dolist (pair (list (cons base base-line) (cons now now-line)))
                        (with-current-buffer (car pair)
                          (goto-char (point-min))
                          (forward-line (1- (cdr pair)))
                          (should (equal (buffer-substring-no-properties
                                          (line-beginning-position)
                                          (line-end-position))
                                         (format "═══ %s ═══" path))))))
                    ;; One difference per file, and neither side can be
                    ;; written to -- ediff's own copy does nothing.
                    (should (= ediff-number-of-differences 3))
                    (should (buffer-local-value 'buffer-read-only base))
                    (should (buffer-local-value 'buffer-read-only now))
                    ;; Side by side, and only for this review: ediff reads
                    ;; the variable out of the control buffer.
                    (should (eq ediff-split-window-function
                                #'split-window-horizontally))
                    ;; And from the first frame, not from the first
                    ;; command: the windows are laid out again at setup.
                    (should (window-live-p ediff-window-A))
                    (should (window-live-p ediff-window-B))
                    (should-not (= (car (window-edges ediff-window-A))
                                   (car (window-edges ediff-window-B))))
                    ;; Only here: the ediff of anything else is as it was.
                    (should (eq (default-value 'ediff-split-window-function)
                                #'split-window-vertically))
                    (let ((before (with-current-buffer now (buffer-string))))
                      (ediff-jump-to-difference 1)
                      (ediff-copy-A-to-B nil)
                      (should (equal (with-current-buffer now (buffer-string))
                                     before))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-baseline-excludes-what-came-before ()
  "What was changed before the session started is in neither buffer."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                ;; Work of the user's own, before the session starts.
                (ecc-review-ediff-test--write (concat directory "x.txt") "mine\n")
                (ecc-review-ediff-test--write (concat directory "was-here.txt") "already\n")
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "theirs\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("x.txt")))
                  (should (equal (with-current-buffer (car ecc-review-ediff--buffers)
                                   (buffer-string))
                                 "═══ x.txt ═══\nmine\n"))
                  ;; One file, so no blank line is wanted anywhere.
                  (should-not (string-search
                               "\n\n"
                               (with-current-buffer (cdr ecc-review-ediff--buffers)
                                 (buffer-string))))
                  (should-not (string-search
                               "was-here"
                               (with-current-buffer (cdr ecc-review-ediff--buffers)
                                 (buffer-string))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-nothing-changed ()
  "A review with nothing to show says so rather than opening an empty ediff."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (ecc-review-ediff-test--repository directory)
        (setf (ecc-session-project-root session) directory)
        (should (ecc-review-ensure-baseline session))
        (should-error (ecc-review-ediff-buffer session) :type 'user-error)))))

(ert-deftest ecc-review-ediff-test-layout-can-be-set-back ()
  "The spacing and the split are the review's own, and both can be undone."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((ecc-review-ediff-file-spacing 0)
                    (ecc-review-ediff-split-window-function nil))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (ecc-review-ediff-test--write (concat directory "made.txt") "new\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  ;; No blank line between the files.
                  (should (equal (with-current-buffer (cdr ecc-review-ediff--buffers)
                                   (buffer-string))
                                 "═══ made.txt ═══\nnew\n═══ x.txt ═══\ntwo\n"))
                  ;; And ediff's own layout, not the review's.  (ediff
                  ;; makes the variable local in every control buffer of
                  ;; its own accord, so what is asked is the value.)
                  (should (eq ediff-split-window-function
                              (default-value 'ediff-split-window-function)))
                  (should (= (car (window-edges ediff-window-A))
                             (car (window-edges ediff-window-B))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-the-help-is-the-reviews-own ()
  "? shows the keys a review has, and none of the ones it has not."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (dolist (key '("c -comment" "d -remove" "l -list"
                                 "C-c C-c -send" "C-c C-k -drop"
                                 "q -close" "n,SPC -next diff"
                                 "s -list the files" "/ -filter the files"))
                    (should (string-match-p (regexp-quote key)
                                            ediff-long-help-message)))
                  ;; Both sides are read-only: nothing that would write.
                  (dolist (key '("a/b" "rx -restore" "wx -save" "wd -save"
                                 "~ -swap" "X -read-only"))
                    (should-not (string-match-p (regexp-quote key)
                                                ediff-long-help-message)))
                  ;; `ediff-setup' composes the messages once before it
                  ;; runs the startup hooks, so the brief one is the
                  ;; standard string unless it is composed again there.
                  (should-not (equal ediff-brief-help-message
                                     ediff-brief-message-string))
                  ;; One line, and no key but ?: the keys are on the
                  ;; header lines of the two windows.  Where the review
                  ;; is, and it follows the difference.
                  (should (equal ediff-brief-help-message
                                 " 1 difference, none selected   ? all keys"))
                  ;; And it is in the panel, not only in the variable:
                  ;; `ediff-setup' writes the help out before it runs
                  ;; the startup hooks.
                  (should (equal ediff-help-message ediff-brief-help-message))
                  (should (string-match-p (regexp-quote "none selected") (buffer-string)))
                  (ediff-unselect-and-select-difference 0 nil 'no-recenter)
                  (should (string-match-p (regexp-quote " Difference 1 of 1   ? all keys")
                                          (buffer-string)))
                  (ediff-toggle-help)
                  (should (string-match-p (regexp-quote "c -comment on the line/diff")
                                          (buffer-string)))
                  (should (string-match-p (regexp-quote "Every key works in both windows")
                                          (buffer-string)))
                  (ediff-toggle-help)
                  ;; And no other ediff session is touched.
                  (should-not (default-value 'ediff-long-help-message-function))
                  (should-not (default-value 'ediff-brief-help-message-function))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-and-b-say-what-a-review-is ()
  "ediff's copy commands are the review's own keys instead of failing.
Both sides are read-only, so `a' and `b' could only signal
`buffer-read-only' -- an error naming a buffer nobody asked about, from
a key the review's own help does not offer.  a shows and hides Claude's
comments, as in the diff review; b says what a review is."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (should (eq (key-binding (kbd "a")) #'ecc-review-toggle-agent))
                  (should (eq (key-binding (kbd "b")) #'ecc-review-ediff-copy-refused))
                  ;; `current-message' is nil in batch, so what was said
                  ;; is taken where it is said.
                  (let (said)
                    (cl-letf (((symbol-function 'message)
                               (lambda (format &rest args)
                                 (setq said (apply #'format format args)))))
                      (ecc-review-ediff-copy-refused))
                    (should said)
                    (should (string-match-p "C-c C-c" said)))
                  ;; And the side it would have written to is untouched.
                  (let ((now (cdr ecc-review-ediff--buffers)))
                    (should (buffer-local-value 'buffer-read-only now)))))
            (ecc-review-ediff-test--quit control)))))))

;;;; What it looks like

(ert-deftest ecc-review-ediff-test-the-code-carries-the-faces-of-its-mode ()
  "The code of a review is coloured the way its own major mode colours it.
The buffers hold many files at once, so each is fontified on its own
and the faces are carried in as text properties; no buffer of ours runs
font-lock."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "code.py") "def greet():\n    return 1\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (with-current-buffer (cdr ecc-review-ediff--buffers)
                    (goto-char (point-min))
                    (should (search-forward "def" nil t))
                    ;; The keyword carries a face, and the separator its own.
                    (should (get-text-property (- (point) 1) 'face))
                    (goto-char (point-min))
                    (should (eq (get-text-property (point) 'face)
                                'ecc-heading-face))
                    ;; And the differences ediff is not standing on are
                    ;; marked in the colours a diff is read by, in these
                    ;; two buffers alone.
                    ;; `face-remap-add-relative' keeps the face itself at
                    ;; the end of the entry, so what is asked is what was
                    ;; put in front of it.
                    (should (memq 'diff-added
                                  (alist-get 'ediff-odd-diff-B
                                             face-remapping-alist)))
                    (should-not (default-value 'face-remapping-alist))
                    ;; What the prompt quotes is the text, never the faces.
                    (should-not
                     (text-properties-at
                      0 (plist-get (ecc-review-ediff--difference
                                    0 control)
                                   :text))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-the-current-difference-stands-out ()
  "The difference being read is marked apart from all the others.
A theme can paint `ediff-current-diff-A\=' in the very colours a diff is
read by -- modus-vivendi does -- so the colour is carried a shade
further, and a bar in the fringe follows the difference from line to
line as n and p walk it."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "x.txt") "one\nchanged\nand again\n")
                (ecc-review-ediff-test--write
                 (concat directory "y.txt") "a second file\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  ;; The colour of the current difference is not the one
                  ;; every other difference was given.
                  (with-current-buffer (car ecc-review-ediff--buffers)
                    (let ((current (alist-get 'ediff-current-diff-A
                                              face-remapping-alist)))
                      (should current)
                      (should-not (memq 'diff-removed current))))
                  ;; A review opens before the first difference, so
                  ;; there is nothing to mark until n has walked to one.
                  (should-not ecc-review-ediff--marks)
                  (ediff-next-difference)
                  (should (> (length ecc-review-ediff--marks) 1))
                  (should (seq-some (lambda (overlay)
                                      (eq (overlay-buffer overlay)
                                          (car ecc-review-ediff--buffers)))
                                    ecc-review-ediff--marks))
                  (should (seq-some (lambda (overlay)
                                      (eq (overlay-buffer overlay)
                                          (cdr ecc-review-ediff--buffers)))
                                    ecc-review-ediff--marks))
                  ;; Every mark is on a line of the difference, and none
                  ;; outside it.  A difference the base side does not
                  ;; hold at all -- these lines are new -- begins and
                  ;; ends in the same place, and carries the one mark.
                  (let ((beg (ediff-get-diff-posn 'A 'beg 0))
                        (end (ediff-get-diff-posn 'A 'end 0)))
                    (dolist (overlay ecc-review-ediff--marks)
                      (when (eq (overlay-buffer overlay)
                                (car ecc-review-ediff--buffers))
                        (should (<= (1- beg) (overlay-start overlay)))
                        (should (<= (overlay-start overlay) end)))))
                  ;; And the bar moves with the difference rather than
                  ;; piling up behind it.
                  (let ((first (mapcar #'overlay-start
                                       ecc-review-ediff--marks)))
                    (ediff-next-difference)
                    (should ecc-review-ediff--marks)
                    (should-not
                     (equal first (mapcar #'overlay-start
                                          ecc-review-ediff--marks)))
                    (should (seq-every-p #'overlay-buffer
                                         ecc-review-ediff--marks)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-the-review-asks-for-a-fringe ()
  "A review gives its own two windows the fringe the bar is drawn in.
A frame can be set up with no fringe at all -- `left-fringe\=' 0 in
`initial-frame-alist\=' -- and the bar then had nowhere to go.  Batch
has no fringes to look at, so what is checked is what the review asks
for and of which windows."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (asked nil))
          (unwind-protect
              (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                        ((symbol-function 'set-window-fringes)
                         (lambda (window left &rest _)
                           (push (cons window left) asked))))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (ediff-next-difference)
                  ;; The two windows of the review, and no other.
                  (should (= (length asked) 2))
                  (should (memq ediff-window-A (mapcar #'car asked)))
                  (should (memq ediff-window-B (mapcar #'car asked)))
                  (should (seq-every-p (lambda (entry)
                                         (= (cdr entry)
                                            ecc-review-ediff-fringe-width))
                                       asked))
                  ;; And nothing at all when the review is not to ask.
                  (setq asked nil)
                  (let ((ecc-review-ediff-fringe-width nil))
                    (ediff-previous-difference)
                    (ediff-next-difference)
                    (should-not asked))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-the-current-difference-can-be-left-alone ()
  "Both marks of the current difference can be turned off."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((ecc-review-ediff-current-diff-faces nil)
                    (ecc-review-ediff-current-diff-mark nil))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (should-not ecc-review-ediff--marks)
                  (with-current-buffer (car ecc-review-ediff--buffers)
                    (should-not (alist-get 'ediff-current-diff-A
                                           face-remapping-alist)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-plain-text-when-fontifying-is-off ()
  "`ecc-review-ediff-fontify' nil leaves the code as it came."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((ecc-review-ediff-fontify nil))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "code.py") "def greet():\n    return 1\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (with-current-buffer (cdr ecc-review-ediff--buffers)
                    (goto-char (point-min))
                    (should (search-forward "def" nil t))
                    (should-not (get-text-property (- (point) 1) 'face)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-quitting-hands-the-keyboard-back ()
  "Quitting gives the frame the review opened in the input focus again.
The control panel of a graphical Emacs is a frame of its own and holds
the keyboard; `ediff-cleanup-mess' deletes it and selects the other
frame within Emacs only, which leaves the window system with no focused
frame -- and a frame that is not focused draws no cursor at all where
`cursor-in-non-selected-windows' is nil.  Batch has one terminal frame,
so the graphical display and the focus are both stood in for."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (focused nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (should (eq (buffer-local-value 'ecc-review-ediff--frame control)
                            (selected-frame)))
                (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                          ((symbol-function 'select-frame-set-input-focus)
                           (lambda (frame &rest _) (push frame focused))))
                  (with-current-buffer control (ecc-review-quit)))
                (should (equal focused (list (selected-frame)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-review-of-a-terminal-frame-keeps-its-focus ()
  "Nothing is done to the focus where the panel was never a frame.
A terminal Emacs lays the control panel out as a window like any other,
and there is no frame to hand the keyboard back to."
  (let ((focused nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame &rest _) (push frame focused))))
      (ecc-review-ediff--take-the-keyboard (selected-frame)))
    (should-not focused))
  ;; A frame that was closed while the review was open is not one to
  ;; select, and not an error either.
  (let ((focused nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame &rest _) (push frame focused))))
      (ecc-review-ediff--take-the-keyboard nil))
    (should-not focused)))

(ert-deftest ecc-review-ediff-test-the-review-takes-the-frame ()
  "The review opens in a frame of its own windows, and gives them back.
Two texts side by side want the width, and `q' is the review's own
quit: ediff asks whether to quit, and the question goes to a
minibuffer the control frame of a graphical Emacs does not have."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (delete-other-windows)
                ;; Something else on the screen, which the review takes
                ;; over and hands back.
                (let ((stranger (get-buffer-create "stranger.txt")))
                  (split-window-below)
                  (set-window-buffer (next-window) stranger)
                  (should (= (length (window-list nil 'no-minibuffer)) 2))
                  (setq control (ecc-review-ediff-buffer session))
                  (with-current-buffer control
                    (should (eq (key-binding (kbd "q")) #'ecc-review-quit))
                    ;; A and B, and nothing else of what was there.
                    (should-not (get-buffer-window stranger))
                    (should (memq (window-buffer ediff-window-A)
                                  (list (car ecc-review-ediff--buffers))))
                    (ecc-review-quit))
                  (should (get-buffer-window stranger))
                  (kill-buffer stranger)))
            (ecc-review-ediff-test--quit control)))))))

;;;; One diff per file

(defun ecc-review-ediff-test--within-its-file (unit)
  "Return non-nil when the difference UNIT lies inside the section of its file."
  (let ((a (ecc-review-ediff--section-bounds 'A (plist-get unit :path)))
        (b (ecc-review-ediff--section-bounds 'B (plist-get unit :path))))
    (and (car a) (car b)
         (<= (car a) (plist-get unit :a-beg)) (<= (plist-get unit :a-end) (cdr a))
         (<= (car b) (plist-get unit :b-beg)) (<= (plist-get unit :b-end) (cdr b)))))

(ert-deftest ecc-review-ediff-test-a-difference-stays-in-its-file ()
  "Each file is diffed on its own: no difference runs over a separator.
A file taken out and another put in with the same text were one diff of
the two buffers whole, which paired the text of the one with the text
of the other across the separator between them -- the new file was
given lines of the old side, and the old one none."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (text (ecc-review-ediff-test--numbered 20))
              (script (lambda (name)
                        (mapconcat (lambda (n) (format "echo %s step %d\n" name n))
                                   (number-sequence 1 15) ""))))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (ecc-review-ediff-test--write (concat directory "a.txt") text)
                (ecc-review-ediff-test--write (concat directory "one.sh") (funcall script "one"))
                (ecc-review-ediff-test--git directory "add" "a.txt" "one.sh")
                (ecc-review-ediff-test--git directory "commit" "-q" "-m" "a")
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                ;; a.txt goes and b.txt comes with its text; two scripts
                ;; much like one.sh come, and one.sh grows by a lot.
                (delete-file (concat directory "a.txt"))
                (ecc-review-ediff-test--write (concat directory "b.txt") text)
                (ecc-review-ediff-test--write (concat directory "one.sh")
                                              (concat (funcall script "one")
                                                      (ecc-review-ediff-test--numbered 40)))
                (ecc-review-ediff-test--write (concat directory "two.sh") (funcall script "two"))
                (ecc-review-ediff-test--write (concat directory "three.sh") (funcall script "one"))
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (let ((units (ecc-review-units)))
                    (should (seq-every-p #'ecc-review-ediff-test--within-its-file units))
                    ;; Every file is in what review_hunks lists.
                    (should (equal (sort (seq-uniq (mapcar (lambda (unit) (plist-get unit :path))
                                                           units))
                                         #'string<)
                                   (sort (mapcar #'car ecc-review-ediff--sections) #'string<)))
                    (dolist (unit units)
                      (pcase (nth 3 (assoc (plist-get unit :path) ecc-review-ediff--sections))
                        ;; A file put in has no old line, one taken out no new.
                        ("A" (should (zerop (plist-get unit :old-count))))
                        ("D" (should (zerop (plist-get unit :new-count))))))
                    (let ((gone (seq-find (lambda (unit) (equal (plist-get unit :path) "a.txt"))
                                          units)))
                      (should (= (plist-get gone :old-count) 20))
                      (should (equal (plist-get gone :header) "@@ -1,20 +1,0 @@"))))
                  ;; And it holds when ediff computes them again.
                  (ediff-update-diffs)
                  (should (seq-every-p #'ecc-review-ediff-test--within-its-file (ecc-review-units)))
                  ;; n walks them, and the filter still hides a file.
                  (ediff-jump-to-difference 1)
                  (ecc-review-ediff-next-difference)
                  (should (= ediff-current-difference 1))
                  (ecc-review-files-set-filter control "two")
                  (should (seq-every-p (lambda (unit)
                                         (eq (ecc-review-ediff--hidden-difference-p
                                              (plist-get unit :number))
                                             (not (equal (plist-get unit :path) "two.sh"))))
                                       (ecc-review-units)))))
            (ecc-review-ediff-test--quit control)))))))

(defmacro ecc-review-ediff-test--with-one-file (session control old new &rest body)
  "Run BODY with CONTROL the ediff review of x.txt that SESSION took from OLD to NEW."
  (declare (indent 4))
  `(ecc-review-ediff-test--with-ediff
     (ecc-review-ediff-test--with-directory directory
       (let ((,control nil))
         (unwind-protect
             (progn
               (ecc-review-ediff-test--git directory "init" "-q")
               (ecc-review-ediff-test--git directory "config" "user.email" "t@example.com")
               (ecc-review-ediff-test--git directory "config" "user.name" "t")
               (ecc-review-ediff-test--write (concat directory "x.txt") ,old)
               (ecc-review-ediff-test--git directory "add" "x.txt")
               (ecc-review-ediff-test--git directory "commit" "-q" "-m" "x")
               (setf (ecc-session-project-root ,session) directory)
               (should (ecc-review-ensure-baseline ,session))
               (ecc-review-ediff-test--write (concat directory "x.txt") ,new)
               (setq ,control (ecc-review-ediff-buffer ,session))
               (with-current-buffer ,control
                 ,@body))
           (ecc-review-ediff-test--quit ,control))))))

(ert-deftest ecc-review-ediff-test-the-diff-options-are-the-review-s-own ()
  "The review diffs with its own options, not with those another ediff set.
ediff keeps them in each control buffer, and `#c' in another ediff sets
the default; read from anywhere but the review's control buffer, a
review ignoring case stopped ignoring it."
  (skip-unless (and (executable-find "git") (executable-find ediff-diff-program)))
  (ecc-test-with-fake-session session
    (ecc-review-ediff-test--with-one-file session control "Hello\nworld\n" "hello\nworld\n"
      (should (= ediff-number-of-differences 1))
      (let ((default (default-value 'ediff-actual-diff-options)))
        (unwind-protect
            (progn
              (setq ediff-actual-diff-options "-i")
              (setq-default ediff-actual-diff-options "")
              (ecc-review-ediff--compute-differences)
              (should (= ediff-number-of-differences 0)))
          (setq-default ediff-actual-diff-options default))))))

(ert-deftest ecc-review-ediff-test-a-file-diff-calls-binary-is-one-difference ()
  "A file git reads as text and diff as binary is one difference, the whole file.
git looks for a NUL in the first 8000 bytes only."
  (skip-unless (and (executable-find "git") (executable-find ediff-diff-program)))
  (ecc-test-with-fake-session session
    (let ((text (concat (make-string 9000 ?a) "\n" "x\0y\n")))
      (ecc-review-ediff-test--with-one-file session control
          (concat "one\n" text) (concat "two\n" text)
        (should (>= ediff-number-of-differences 1))
        (should (seq-every-p #'ecc-review-ediff-test--within-its-file (ecc-review-units)))))))

(ert-deftest ecc-review-ediff-test-trouble-in-diff-is-said ()
  "diff exiting with 2 is an error with what it said; what it says on stderr
otherwise is no part of the diff."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-ediff-test--with-one-file session control "one\n" "two\n"
      (let ((script (make-temp-file "ecc-review-diff" nil ".sh")))
        (unwind-protect
            (progn
              (set-file-modes script #o755)
              (ecc-review-ediff-test--write
               script "#!/bin/sh\necho 'a warning' >&2\necho 'diff -r a/000000 b/000000'\necho 1c1\nexit 1\n")
              (setq-local ediff-diff-program script)
              (ecc-review-ediff--compute-differences)
              (should (= ediff-number-of-differences 1))
              (ecc-review-ediff-test--write script "#!/bin/sh\necho 'no such thing' >&2\nexit 2\n")
              (let ((error (should-error (ecc-review-ediff--compute-differences))))
                (should (string-search "no such thing" (error-message-string error))))
              ;; A line that is no part of a diff names the review's file.
              (ecc-review-ediff-test--write
               script "#!/bin/sh\necho 'diff -r a/000000 b/000000'\necho 'what is this'\nexit 1\n")
              (let ((error (should-error (ecc-review-ediff--compute-differences))))
                (should (string-search "x.txt" (error-message-string error)))))
          (delete-file script))))))

(ert-deftest ecc-review-ediff-test-reading-again-writes-no-whole-buffer ()
  "The differences are computed from the buffers, with no file of either whole."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-ediff-test--with-one-file session control "one\n" "two\n"
      (cl-letf (((symbol-function 'ediff-make-temp-file)
                 (lambda (&rest _) (error "A whole side was written out"))))
        (ecc-review-ediff--compute-differences))
      (should (= ediff-number-of-differences 1)))))

(ert-deftest ecc-review-ediff-test-recentering-keeps-the-control-buffer ()
  "Before Emacs 31, recentering one side made the selected window's buffer current.
With the keyboard in a side that broke every recentre; the review keeps
the current buffer around it, as Emacs 31 does."
  (let ((side (get-buffer-create " *ecc-review-ediff-test-side*")))
    (unwind-protect
        (with-temp-buffer
          (let ((control (current-buffer)))
            (ecc-review-ediff--recenter-one-window (lambda (_type) (set-buffer side)) 'B)
            (should (eq (current-buffer) control))))
      (kill-buffer side)))
  (should (eq (< emacs-major-version 31)
              (and (advice-member-p #'ecc-review-ediff--recenter-one-window
                                    'ediff-recenter-one-window)
                   t))))

;;;; Binary and oversized files

(ert-deftest ecc-review-ediff-test-binary-and-oversize-are-named ()
  "A binary or oversized file is a separator line saying why, and no more."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (with-temp-file (concat directory "photo.png")
                  (set-buffer-multibyte nil)
                  (insert "\211PNG\r\n\032\n" (make-string 64 0) "\377\330\377"))
                (ecc-review-ediff-test--write (concat directory "dump.sql")
                                        (make-string 200 ?x))
                (let ((ecc-review-max-bytes 100))
                  (setq control (ecc-review-ediff-buffer session)))
                (with-current-buffer control
                  (let ((base (with-current-buffer (car ecc-review-ediff--buffers)
                                (buffer-string)))
                        (now (with-current-buffer (cdr ecc-review-ediff--buffers)
                               (buffer-string))))
                    (should (string-search "═══ photo.png (binary, not shown) ═══" now))
                    (should (string-search "not shown) ═══" now))
                    (should (string-search "dump.sql (" now))
                    ;; Nothing of either file is in the review.
                    (should-not (string-search "PNG" now))
                    (should-not (string-search "xxxxx" now))
                    (should (equal base now)))
                  ;; Both sides being empty, neither file is a difference.
                  (should (= ediff-number-of-differences 0))))
            (ecc-review-ediff-test--quit control)))))))

;;;; The trees a working tree review compares

(ert-deftest ecc-review-ediff-test-trees ()
  "Every range `ecc-review-worktree' takes resolves to two trees."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--repository directory)
    (ecc-review-ediff-test--write (concat directory "x.txt") "second\n")
    (ecc-review-ediff-test--git directory "commit" "-q" "-a" "-m" "second")
    (let* ((root (ecc-review-git-root directory))
           (head (ecc-review--head-tree root))
           (first (string-trim (ecc-review-ediff-test--git directory "rev-parse"
                                                     "HEAD~1^{tree}"))))
      ;; A revision is compared with the working tree as it stands.
      (ecc-review-ediff-test--write (concat directory "x.txt") "working\n")
      (let ((trees (ecc-review-ediff--trees root "HEAD")))
        (should (equal (car trees) head))
        (should-not (equal (cdr trees) head)))
      ;; Two revisions are two trees of the history and nothing else.
      (should (equal (ecc-review-ediff--trees root "HEAD~1..HEAD")
                     (cons first head)))
      (should (equal (ecc-review-ediff--trees root "HEAD~1...HEAD")
                     (cons first head)))
      ;; One commit, the way `c' in the review menu names it.
      (should (equal (ecc-review-ediff--trees root "HEAD^!")
                     (cons first head)))
      ;; The empty range is the index against the working tree.
      (ecc-review-ediff-test--git directory "add" "x.txt")
      (let ((trees (ecc-review-ediff--trees root "")))
        (should (equal (car trees) (ecc-review-snapshot root t)))
        (should-not (equal (car trees) head)))
      (should-error (ecc-review-ediff--trees root "no-such-revision")
                    :type 'user-error))))

(ert-deftest ecc-review-ediff-test-trees-without-commits ()
  "HEAD in a repository with no commit is the empty tree."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--git directory "init" "-q")
    (ecc-review-ediff-test--write (concat directory "x.txt") "one\n")
    (let* ((root (ecc-review-git-root directory))
           (trees (ecc-review-ediff--trees root "HEAD")))
      (should (equal (car trees) (ecc-review--empty-tree root)))
      (should-not (equal (car trees) (cdr trees))))))

(ert-deftest ecc-review-ediff-test-worktree ()
  "The working tree review shows every change, staged, unstaged or untracked."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (ecc-review-ediff-test--write (concat directory "x.txt") "unstaged\n")
                (ecc-review-ediff-test--write (concat directory "gone.txt") "staged\n")
                (ecc-review-ediff-test--git directory "add" "gone.txt")
                (ecc-review-ediff-test--write (concat directory "new.txt") "hello\n")
                (setf (ecc-session-project-root session) directory)
                (setq control (ecc-review-ediff-worktree-buffer session))
                (with-current-buffer control
                  (should (equal ecc-review--range "HEAD"))
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("gone.txt" "new.txt" "x.txt")))
                  (should (= ediff-number-of-differences 3)))
                (ecc-review-ediff-test--quit control)
                ;; Without a revision only what is not staged is shown.
                (setq control (ecc-review-ediff-worktree-buffer session ""))
                (with-current-buffer control
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("new.txt" "x.txt")))))
            (ecc-review-ediff-test--quit control)))))))

;;;; Comments and the prompt

(defun ecc-review-ediff-test--setup (session directory)
  "Make DIRECTORY a repository SESSION changed two files of, and open it."
  (ecc-review-ediff-test--repository directory)
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (delete-file (concat directory "gone.txt"))
  (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
  (ecc-review-ediff-buffer session))

(ert-deftest ecc-review-ediff-test-comment-carries-the-file-and-the-line ()
  "A comment on a difference names the file and the lines inside it."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--setup session directory))
                (with-current-buffer control
                  (should (= ediff-number-of-differences 2))
                  ;; Nothing is on a difference until ediff is moved.
                  (should (= ediff-current-difference -1))
                  (should-error (call-interactively #'ecc-review-ediff-comment)
                                :type 'user-error)
                  ;; The second difference is the change to x.txt.
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use a word")
                  (let ((comment (car (ecc-review-comments))))
                    (should (equal (plist-get comment :path) "x.txt"))
                    (should (equal (plist-get comment :start) 1))
                    (should (equal (plist-get comment :end) 1))
                    (should (equal (plist-get comment :text)
                                   "@@ -1,1 +1,1 @@\n-one\n+two"))
                    (should (equal (plist-get comment :header) "@@ -1,1 +1,1 @@"))
                    (should (equal (plist-get comment :comment) "use a word")))
                  ;; The first is the file that is gone: it has no line
                  ;; on the right, and is still that file's.
                  (ediff-jump-to-difference 1)
                  (ecc-review-ediff-comment "keep it")
                  (let ((comments (ecc-review-comments)))
                    (should (= (length comments) 2))
                    (should (equal (plist-get (car comments) :path) "gone.txt"))
                    (should (equal (plist-get (car comments) :text)
                                   "@@ -1,1 +1,0 @@\n-bye"))
                    ;; In the order of the differences, not of the typing.
                    (should (equal (plist-get (cadr comments) :path) "x.txt")))
                  ;; Shown under the difference on the right.
                  (let ((overlay (seq-find (lambda (overlay)
                                             (string-search "▎ #1 use a word"
                                                            (or (overlay-get overlay 'after-string)
                                                                "")))
                                           ecc-review--comments)))
                    (should overlay)
                    (should (eq (overlay-buffer overlay) (cdr ecc-review-ediff--buffers))))
                  ;; Editing replaces, removing drops.
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use two words")
                  (should (= (length (ecc-review-comments)) 2))
                  (should (equal (plist-get (cadr (ecc-review-comments))
                                            :comment)
                                 "use two words"))
                  (ecc-review-ediff-remove-comment)
                  (should (= (length (ecc-review-comments)) 1))
                  (should-error (ecc-review-ediff-remove-comment)
                                :type 'user-error)))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-send ()
  "C-c C-c sends the comments as the diff review would and closes the ediff."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((windows (current-window-configuration)))
                (setq control (ecc-review-ediff-test--setup session directory))
                (with-current-buffer control
                  (should (eq (key-binding (kbd "c")) #'ecc-review-ediff-comment))
                  (should (eq (key-binding (kbd "d"))
                              #'ecc-review-ediff-remove-comment))
                  (should (eq (key-binding (kbd "l"))
                              #'ecc-review-ediff-list-comments))
                  (should (eq (key-binding (kbd "C-c C-c")) #'ecc-review-send))
                  (should (eq (key-binding (kbd "C-c C-k")) #'ecc-review-quit))
                  (should-error (ecc-review-send) :type 'user-error)
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use a word")
                  (let ((base (car ecc-review-ediff--buffers))
                        (now (cdr ecc-review-ediff--buffers))
                        (expected (ecc-review-format-message
                                   (ecc-review-comments))))
                    (ecc-review-send)
                    (should (string-search "## x.txt  L1-L1" expected))
                    (let ((sent (car (ecc-test-sent-messages))))
                      (should (equal (alist-get 'type sent) "user"))
                      (should (equal (alist-get 'content (alist-get 'message sent))
                                     expected)))
                    (should (ecc-session-current-turn session))
                    ;; The control buffer and both sides are gone, and
                    ;; the screen is what it was.
                    (should-not (buffer-live-p control))
                    (should-not (buffer-live-p base))
                    (should-not (buffer-live-p now))
                    (should (compare-window-configurations
                             (current-window-configuration) windows)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-send-editing-first ()
  "C-u C-c C-c shows the prompt; cancelling leaves the ediff open."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--setup session directory))
                (with-current-buffer control
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use a word")
                  (let ((expected (ecc-review-format-message
                                   (ecc-review-comments))))
                    (ecc-review-send t)
                    (let ((message-buffer (get-buffer "*ecc-review-message: test*")))
                      (should message-buffer)
                      (with-current-buffer message-buffer
                        (should (equal (buffer-string) expected))
                        ;; Going back leaves the review to carry on.
                        (ecc-review-message-cancel))
                      (should-not (buffer-live-p message-buffer))
                      (should (buffer-live-p control))
                      (should-not ecc-test-sent)
                      ;; And sending from there closes the ediff.
                      (with-current-buffer control (ecc-review-send t))
                      (with-current-buffer (get-buffer "*ecc-review-message: test*")
                        (goto-char (point-max))
                        (insert "\n\n全体: テストも足すこと")
                        (ecc-review-message-send))
                      (should-not (buffer-live-p control))
                      (should (equal (alist-get 'content
                                                (alist-get 'message
                                                           (car (ecc-test-sent-messages))))
                                     (concat expected
                                             "\n\n全体: テストも足すこと")))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-quit-drops-the-comments ()
  "C-c C-k closes the review and its buffers without sending anything."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--setup session directory))
                (let (base now)
                  (with-current-buffer control
                    (ediff-jump-to-difference 1)
                    (ecc-review-ediff-comment "never mind")
                    (setq base (car ecc-review-ediff--buffers)
                          now (cdr ecc-review-ediff--buffers))
                    (ecc-review-quit))
                  (should-not (buffer-live-p control))
                  (should-not (buffer-live-p base))
                  (should-not (buffer-live-p now))
                  (should-not ecc-test-sent)))
            (ecc-review-ediff-test--quit control)))))))

;;;; Notes: Claude's comments, the keys, the reply

(defconst ecc-review-ediff-test--lines
  (mapconcat (lambda (n) (format "line%d\n" n)) (number-sequence 1 10) "")
  "What a.txt holds when the repository is made: line1 to line10.")

(defconst ecc-review-ediff-test--changed
  "line1\nLINE2\nline3\nline4\nline5\nline6\nnew\nline7\nline8\nline10\n"
  "a.txt as the session leaves it: line 2 changed, a line put in after line 6
and line 9 taken out -- three differences, one of each kind.")

(defun ecc-review-ediff-test--rich (session directory)
  "Make DIRECTORY a repository whose a.txt SESSION changed three times.
Open its ediff review and return the control buffer."
  (ecc-review-ediff-test--repository directory)
  (ecc-review-ediff-test--write (concat directory "a.txt") ecc-review-ediff-test--lines)
  (ecc-review-ediff-test--git directory "add" "a.txt")
  (ecc-review-ediff-test--git directory "commit" "-q" "-m" "a")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (ecc-review-ediff-test--write (concat directory "a.txt") ecc-review-ediff-test--changed)
  (ecc-review-ediff-buffer session))

(defun ecc-review-ediff-test--line (side number)
  "Return the line of SIDE, `old' or `new', of a.txt numbered NUMBER."
  (seq-find (lambda (line)
              (and (eq (plist-get line :side) side)
                   (equal (plist-get line :path) "a.txt")
                   (eql (plist-get line :line) number)))
            (ecc-review-lines)))

(defun ecc-review-ediff-test--drawn (buffer)
  "Return what the comment overlays of this review draw in BUFFER, joined."
  (mapconcat (lambda (overlay)
               (if (eq (overlay-buffer overlay) buffer)
                   (or (overlay-get overlay 'after-string)
                       (overlay-get overlay 'before-string) "")
                 ""))
             ecc-review--comments ""))

(ert-deftest ecc-review-ediff-test-differences-are-hunks ()
  "Each difference is a hunk with lines on the side that holds them."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (let ((units (seq-filter (lambda (unit)
                                             (equal (plist-get unit :path) "a.txt"))
                                           (ecc-review-units))))
                    (should (= (length units) 3))
                    (should (equal (mapcar #'ecc-review-unit-description units)
                                   '("difference 1  old L2-L2  new L2-L2"
                                     "difference 2  old none  new L7-L7"
                                     "difference 3  old L9-L9  new none")))
                    (should (equal (plist-get (car units) :text)
                                   "@@ -2,1 +2,1 @@\n-line2\n+LINE2")))
                  ;; The lines are where they are in the two buffers.
                  (let ((old (ecc-review-ediff-test--line 'old 9))
                        (new (ecc-review-ediff-test--line 'new 7)))
                    (should (equal (plist-get old :text) "line9"))
                    (should (eq (plist-get old :buffer) (car ecc-review-ediff--buffers)))
                    (should (equal (plist-get new :text) "new"))
                    (with-current-buffer (plist-get new :buffer)
                      (goto-char (plist-get new :position))
                      (should (looking-at-p "new$"))))
                  ;; A line both sides hold is on no difference.
                  (should-not (ecc-review-ediff-test--line 'new 5))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-claude-comments-and-the-keys ()
  "Claude's comments are drawn on their side; c answers them; a { } d work."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (let ((base (car ecc-review-ediff--buffers))
                        (now (cdr ecc-review-ediff--buffers)))
                    (ecc-review-add-note 'claude "Why the capitals?"
                                         (ecc-review-ediff-test--line 'new 2))
                    (ecc-review-add-note 'claude "line9 was used"
                                         (ecc-review-ediff-test--line 'old 9))
                    (ecc-review--draw-notes)
                    ;; Under their lines, on their own side, as the diff
                    ;; review draws them.
                    (should (string-search "▎ #1 Claude: Why the capitals?"
                                           (ecc-review-ediff-test--drawn now)))
                    (should (string-search "▎ #2 Claude: line9 was used"
                                           (ecc-review-ediff-test--drawn base)))
                    (should-not (string-search "#2" (ecc-review-ediff-test--drawn now)))
                    (let ((overlay (seq-find (lambda (overlay)
                                               (eq (overlay-buffer overlay) now))
                                             ecc-review--comments)))
                      (should (eq (get-text-property
                                   0 'face (overlay-get overlay 'after-string))
                                  'ecc-review-agent-comment-face))
                      (with-current-buffer now
                        (goto-char (overlay-start overlay))
                        (should (looking-at-p "LINE2$"))))
                    ;; The keys of the diff review are here too.
                    (dolist (key '(("a" . ecc-review-toggle-agent)
                                   ("{" . ecc-review-ediff-previous-comment)
                                   ("}" . ecc-review-ediff-next-comment)
                                   ("d" . ecc-review-ediff-remove-comment)
                                   ("l" . ecc-review-ediff-list-comments)
                                   ("!" . ecc-review-refresh)))
                      (should (eq (key-binding (kbd (car key))) (cdr key))))
                    ;; } walks to the comments, difference and line.
                    (ecc-review-ediff-next-comment)
                    (should (= ediff-current-difference 0))
                    (should (= (window-point ediff-window-B)
                               (plist-get (ecc-review-ediff-test--line 'new 2) :position)))
                    (ecc-review-ediff-next-comment)
                    (should (= ediff-current-difference 2))
                    (should (= (window-point ediff-window-A)
                               (plist-get (ecc-review-ediff-test--line 'old 9) :position)))
                    (should-error (ecc-review-ediff-next-comment) :type 'user-error)
                    (ecc-review-ediff-previous-comment)
                    (should (= ediff-current-difference 0))
                    ;; c on a difference Claude spoke on answers it.
                    (should (eq (nth 1 (ecc-review-ediff--comment-plan
                                        (ecc-review-ediff--current-unit)))
                                'reply))
                    (ecc-review-ediff-comment "To stand out")
                    (let ((reply (ecc-review-find-note 3)))
                      (should (equal (ecc-review-note-reply-to reply) 1))
                      (should (string-search "\n    ▎ #3 To stand out"
                                             (ecc-review-ediff-test--drawn now))))
                    (should (string-search "In reply to Claude's #1: Why the capitals?"
                                           (ecc-review-buffer-message)))
                    ;; Claude's are not sent.
                    (should-not (string-search "line9 was used" (ecc-review-buffer-message)))
                    ;; c again does not answer Claude twice: #1 is answered,
                    ;; and the reply is no comment on the whole difference
                    ;; to edit, so it is a comment of its own.
                    (should-not (nth 1 (ecc-review-ediff--comment-plan
                                        (ecc-review-ediff--current-unit))))
                    ;; a hides Claude's and keeps them counted.
                    (ecc-review-toggle-agent)
                    (should-not (string-search "Claude:" (ecc-review-ediff-test--drawn now)))
                    (should-not (string-search "Claude:" (ecc-review-ediff-test--drawn base)))
                    (should (string-search "#3 [reply to #1] To stand out"
                                           (ecc-review-ediff-test--drawn now)))
                    (should (= (length ecc-review--notes) 3))
                    (ecc-review-toggle-agent)
                    ;; d takes the one asked for.
                    (ediff-jump-to-difference 3)
                    (ecc-review-ediff-remove-comment)
                    (should-not (ecc-review-find-note 2))
                    (should-not (string-search "line9" (ecc-review-ediff-test--drawn base))))))
            (ecc-review-ediff-test--quit control)))))))

;;;; Following the files

(defmacro ecc-review-ediff-test--with-watch (&rest body)
  "Run BODY with a timer of the watch of its own, cancelled afterwards."
  (declare (indent 0))
  `(let ((ecc-review--watch-timer nil)
         (ecc-review-auto-refresh t))
     (unwind-protect (progn ,@body)
       (when (timerp ecc-review--watch-timer)
         (cancel-timer ecc-review--watch-timer)))))

(defun ecc-review-ediff-test--fire ()
  "Run the watch timer as it runs with Emacs idle."
  (cl-letf (((symbol-function 'current-idle-time) (lambda () (seconds-to-time 10)))
            ((symbol-function 'input-pending-p) #'ignore))
    (timer-event-handler ecc-review--watch-timer)))

(ert-deftest ecc-review-ediff-test-follows-the-files ()
  "A change marks the ediff review stale and the timer reads it in place.
The comments, the difference being read and the line each side is on
stay; nothing about the windows changes but what they show.  Faces, as
a graphical Emacs has them: without them ediff marks the current
difference by writing flags into the text, which moves the point of the
window that has the keyboard."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (ecc-review-ediff-test--with-watch
          (let ((control nil)
                (ediff-force-faces t))
            (unwind-protect
                (progn
                  (setq control (ecc-review-ediff-test--rich session directory))
                  (with-current-buffer control
                    (ecc-review-ediff-test--as-a-gui)
                    (ecc-review-add-note 'claude "A new line"
                                         (ecc-review-ediff-test--line 'new 7))
                    (ecc-review--draw-notes)
                    (ediff-jump-to-difference 2)
                    (ecc-review-ediff-comment "Name it")
                    (should (ecc-review-shown-window)))
                  ;; Two lines are put in at the top of a.txt.
                  (ecc-review-ediff-test--write
                   (concat directory "a.txt")
                   (concat "zero\nzero2\n" ecc-review-ediff-test--changed))
                  (ecc-review--on-session-change session nil)
                  (should (buffer-local-value 'ecc-review--stale control))
                  (should (timerp ecc-review--watch-timer))
                  (let ((selected (selected-window))
                        (windows (window-list)))
                    (ecc-review-ediff-test--fire)
                    (should (eq (selected-window) selected))
                    (should (equal (window-list) windows)))
                  (with-current-buffer control
                    (should-not ecc-review--stale)
                    (should (string-search "zero2"
                                           (with-current-buffer ediff-buffer-B
                                             (buffer-string))))
                    ;; Still on the line that was put in: difference 3 now.
                    (should (= ediff-current-difference 2))
                    (should (equal (plist-get (nth 2 (ecc-review-units)) :header)
                                   "@@ -7,0 +9,1 @@"))
                    (should (string-search "new"
                                           (ecc-review-ediff-test--drawn ediff-buffer-B)))
                    (dolist (note ecc-review--notes)
                      (should-not (ecc-review-note-outdated note))
                      (should (equal (ecc-review-note-hunk-key note)
                                   '("a.txt" . "@@ -7,0 +9,1 @@"))))
                    (should (= (ecc-review-note-line (ecc-review-find-note 1)) 9))
                    (should (string-search "▎ #1 Claude: A new line"
                                           (ecc-review-ediff-test--drawn ediff-buffer-B)))
                    ;; And its window is on that line.
                    (should (= (window-point ediff-window-B)
                               (plist-get (ecc-review-ediff-test--line 'new 9)
                                          :position)))
                    ;; Read again with nothing new, nothing is written.
                    (let ((tick (with-current-buffer ediff-buffer-B
                                  (buffer-chars-modified-tick))))
                      (ecc-review-reread t)
                      (should (= tick (with-current-buffer ediff-buffer-B
                                        (buffer-chars-modified-tick)))))))
              (ecc-review-ediff-test--quit control))))))))

(ert-deftest ecc-review-ediff-test-follows-the-files-to-nothing ()
  "An ediff review whose changes all go stays open and keeps its comments."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (with-current-buffer control
                  (ediff-jump-to-difference 1)
                  (ecc-review-ediff-comment "Keep this")
                  (ecc-review-ediff-test--write (concat directory "a.txt")
                                                ecc-review-ediff-test--lines)
                  (ecc-review-ediff-test--write (concat directory "x.txt") "one\n")
                  (ecc-review-reread t)
                  (should (buffer-live-p control))
                  (should (= ediff-number-of-differences 0))
                  (should (string-search "Nothing has changed"
                                         (with-current-buffer ediff-buffer-B
                                           (buffer-string))))
                  (should (ecc-review-note-outdated (car ecc-review--notes)))
                  ;; Sent as outdated, with the hunk it was on.
                  (should (string-search "(outdated)" (ecc-review-buffer-message)))
                  ;; And back once the change comes back.
                  (ecc-review-ediff-test--write (concat directory "a.txt")
                                                ecc-review-ediff-test--changed)
                  (ecc-review-reread t)
                  (should (= ediff-number-of-differences 3))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-failed-read-waits-for-bang ()
  "An ediff review that cannot be read says so once and waits for !."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (ecc-review-ediff-test--with-watch
          (let ((control nil)
                (said nil))
            (unwind-protect
                (let ((moved (concat (directory-file-name directory) "-moved")))
                  (setq control (ecc-review-ediff-test--rich session directory))
                  (rename-file (directory-file-name directory) moved)
                  (unwind-protect
                      (progn
                        (ecc-review--on-session-change session)
                        (cl-letf (((symbol-function 'message)
                                   (lambda (&rest args) (push (apply #'format args) said))))
                          (ecc-review--refresh-stale))
                        (should (= (length said) 1))
                        (with-current-buffer control
                          (should ecc-review--failed)
                          (should-not ecc-review--stale)
                          ;; The review is as it was.
                          (should (= ediff-number-of-differences 3)))
                        (ecc-review--on-session-change session)
                        (should-not (buffer-local-value 'ecc-review--stale control)))
                    (rename-file moved (directory-file-name directory)))
                  (with-current-buffer control
                    (ecc-review-refresh)
                    (should-not ecc-review--failed))
                  (ecc-review--on-session-change session)
                  (should (buffer-local-value 'ecc-review--stale control)))
              (ecc-review-ediff-test--quit control))))))))

(ert-deftest ecc-review-ediff-test-a-side-coming-into-view-reads-it ()
  "A window coming to show a side of a stale ediff review asks for the timer."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (ecc-review-ediff-test--with-watch
          (let ((control nil))
            (unwind-protect
                (progn
                  (setq control (ecc-review-ediff-test--rich session directory))
                  (with-current-buffer control
                    (should (eq (buffer-local-value 'ecc-review--part-of ediff-buffer-A)
                                control))
                    (setq ecc-review--stale t))
                  (should-not ecc-review--watch-timer)
                  (ecc-review--on-window-buffer-change (selected-frame))
                  (should (timerp ecc-review--watch-timer)))
              (ecc-review-ediff-test--quit control))))))))

;;;; Findings of the Phase 3 review

(ert-deftest ecc-review-ediff-test-the-read-difference-vanishes ()
  "When the difference being read goes, the one now under the right side is read.
`ediff-diff-at-point' counts from 1; taken as ediff's own index it put
the review on the difference after that one."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ediff-jump-to-difference 1)
                  ;; The change to line 2 is undone: the next difference,
                  ;; the line put in after line 6, is the nearest.
                  (ecc-review-ediff-test--write
                   (concat directory "a.txt")
                   (string-replace "LINE2" "line2" ecc-review-ediff-test--changed))
                  (ecc-review-reread t)
                  (should (= ediff-number-of-differences 2))
                  (should (= ediff-current-difference 0))
                  (should (equal (plist-get (nth 0 (ecc-review-units)) :start) 7))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-ediff-computing-again-is-followed ()
  "ediff's own computing of the differences -- #c here -- redraws the review.
The hunks are made again and the comments put back on them, and the
fingerprint no longer matches, so the next reading is not skipped."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ecc-review-add-note 'claude "A new line"
                                       (ecc-review-ediff-test--line 'new 7))
                  (ecc-review--draw-notes)
                  (should (= (length (ecc-review-units)) 3))
                  (let ((before ecc-review--fingerprint))
                    ;; LINE2 against line2 is no difference with case ignored.
                    (ediff-toggle-ignore-case)
                    (should (= ediff-number-of-differences 2))
                    (should (= (length (ecc-review-units)) 2))
                    (should-not (equal before (ecc-review-ediff--state
                                               (car ecc-review--fingerprint)))))
                  (let ((note (car ecc-review--notes)))
                    (should-not (ecc-review-note-outdated note))
                    (should (equal (ecc-review-note-hunk-key note)
                                   (ecc-review--hunk-key (car (ecc-review-units))))))
                  (should (string-search "#1 Claude: A new line"
                                         (ecc-review-ediff-test--drawn ediff-buffer-B)))
                  (ediff-toggle-ignore-case)))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-comments-on-the-left-are-walked-one-by-one ()
  "Three comments on lines a difference took out are three places to walk to."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (ecc-review-ediff-test--write (concat directory "b.txt") "a\nb\nc\nd\ne\n")
                (ecc-review-ediff-test--git directory "add" "b.txt")
                (ecc-review-ediff-test--git directory "commit" "-q" "-m" "b")
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "b.txt") "a\ne\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (let ((old (lambda (number)
                               (seq-find (lambda (line)
                                           (and (eq (plist-get line :side) 'old)
                                                (eql (plist-get line :line) number)))
                                         (ecc-review-lines)))))
                    ;; Made out of order: the review orders them by line.
                    (dolist (number '(4 2 3))
                      (ecc-review-add-note 'claude (format "line %d" number)
                                           (funcall old number))))
                  (ecc-review--draw-notes)
                  (should (equal (mapcar #'ecc-review-note-text
                                         (ecc-review--ordered ecc-review--notes))
                                 '("line 2" "line 3" "line 4")))
                  (let ((at-a (lambda ()
                                (let ((window ediff-window-A))
                                  (with-current-buffer ediff-buffer-A
                                    (save-excursion
                                      (goto-char (window-point window))
                                      (buffer-substring-no-properties
                                       (line-beginning-position) (line-end-position))))))))
                    (ecc-review-ediff-next-comment)
                    (should (equal (funcall at-a) "b"))
                    (ecc-review-ediff-next-comment)
                    (should (equal (funcall at-a) "c"))
                    (ecc-review-ediff-next-comment)
                    (should (equal (funcall at-a) "d"))
                    (should-error (ecc-review-ediff-next-comment) :type 'user-error)
                    (ecc-review-ediff-previous-comment)
                    (should (equal (funcall at-a) "c")))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-c-answers-what-claude-said-last ()
  "Once you answered Claude, Claude's next comment there is what c answers.
With more than one comment to answer or edit, which is asked."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ediff-jump-to-difference 1)
                  (ecc-review-add-note 'claude "First" (ecc-review-ediff-test--line 'new 2))
                  (ecc-review--draw-notes)
                  (ecc-review-ediff-comment "Answering the first")
                  (should (equal (ecc-review-note-reply-to (ecc-review-find-note 2)) 1))
                  (ecc-review-add-note 'claude "Second" (ecc-review-ediff-test--line 'new 2))
                  (ecc-review--draw-notes)
                  (let ((plan (ecc-review-ediff--comment-plan (ecc-review-ediff--current-unit))))
                    (should (eq (nth 1 plan) 'reply))
                    (should (= (nth 2 plan) 3)))
                  (ecc-review-ediff-comment "Answering the second")
                  (should (equal (ecc-review-note-reply-to (ecc-review-find-note 4)) 3))
                  ;; A comment of your own on the difference, and Claude
                  ;; speaks again: both are offered, the reply first.
                  (ecc-review-add-note 'user "Mine" (car (ecc-review-ediff--unit-lines
                                                          (ecc-review-ediff--current-unit))))
                  (ecc-review-add-note 'claude "Third" (ecc-review-ediff-test--line 'new 2))
                  (ecc-review--draw-notes)
                  (let ((offered nil))
                    (cl-letf (((symbol-function 'completing-read)
                               (lambda (_prompt labels &rest _)
                                 (setq offered labels)
                                 (seq-find (lambda (label) (string-prefix-p "edit" label))
                                           labels))))
                      (let ((choice (ecc-review-ediff--read-choice
                                     (ecc-review-ediff--current-unit))))
                        (should (string-prefix-p "reply to #6" (car offered)))
                        (should (member "new comment" offered))
                        (should (eq (car choice) 'edit))
                        (should (= (ecc-review-note-id (cdr choice)) 5)))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-two-reviews-of-one-session ()
  "Two ediff reviews of one session have two sides each and are read apart."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((one nil) (two nil))
          (unwind-protect
              (progn
                (setq one (ecc-review-ediff-test--rich session directory))
                (setq two (ecc-review-ediff-worktree-buffer session ""))
                (let ((sides (lambda (control)
                               (buffer-local-value 'ecc-review-ediff--buffers control))))
                  (should-not (memq (car (funcall sides one))
                                    (list (car (funcall sides two)) (cdr (funcall sides two)))))
                  (should-not (memq (cdr (funcall sides one))
                                    (list (car (funcall sides two)) (cdr (funcall sides two)))))
                  (should (equal (buffer-name (cdr (funcall sides two)))
                                 "*ecc-review-now: test (unstaged changes)*"))
                  (with-current-buffer one
                    (ecc-review-add-note 'claude "one's" (ecc-review-ediff-test--line 'new 2))
                    (ecc-review--draw-notes))
                  (ecc-review-ediff-test--write (concat directory "a.txt")
                                                (concat "top\n" ecc-review-ediff-test--changed))
                  (let ((tick (with-current-buffer (cdr (funcall sides one))
                                (buffer-chars-modified-tick))))
                    (with-current-buffer two (ecc-review-reread t))
                    ;; Reading the second leaves the first as it was.
                    (should (= tick (with-current-buffer (cdr (funcall sides one))
                                      (buffer-chars-modified-tick)))))
                  (with-current-buffer one (ecc-review-reread t))
                  (dolist (control (list one two))
                    (should (string-search "top\n" (with-current-buffer (cdr (funcall sides control))
                                                     (buffer-string)))))
                  (should (string-search "one's" (with-current-buffer one
                                                   (ecc-review-ediff-test--drawn
                                                    ediff-buffer-B))))
                  (should-not (buffer-local-value 'ecc-review--notes two))))
            ;; Both quit before either's buffers are swept away.
            (dolist (control (list two one))
              (when (buffer-live-p control)
                (ecc-review-ediff-quit control)))
            (ecc-review-ediff-test--kill-buffers)))))))

(ert-deftest ecc-review-ediff-test-d-reaches-every-comment ()
  "Off every difference, or with C-u, d offers every comment of the review."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ediff-jump-to-difference 1)
                  (ecc-review-ediff-comment "On line 2")
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "On the new line")
                  ;; Every change goes: no difference is left to stand on.
                  (ecc-review-ediff-test--write (concat directory "a.txt")
                                                ecc-review-ediff-test--lines)
                  (ecc-review-reread t)
                  (should (= ediff-number-of-differences 0))
                  (let ((asked nil))
                    (cl-letf (((symbol-function 'completing-read)
                               (lambda (_prompt labels &rest _)
                                 (setq asked labels)
                                 (car (last labels)))))
                      (ecc-review-ediff-remove-comment))
                    (should (= (length asked) 2)))
                  (should (equal (mapcar #'ecc-review-note-text ecc-review--notes)
                                 '("On line 2")))
                  ;; And with C-u, even standing on a difference.
                  (ecc-review-ediff-test--write (concat directory "a.txt")
                                                ecc-review-ediff-test--changed)
                  (ecc-review-reread t)
                  (ediff-jump-to-difference 3)
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt labels &rest _) (car labels))))
                    (ecc-review-ediff-remove-comment t))
                  (should-not ecc-review--notes)))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-unchanged-files-are-not-coloured-again ()
  "Reading the review again fontifies only the files that changed, and an
unchanged review reads no file at all."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff-and-no-pane
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (coloured nil)
              (read 0))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (with-current-buffer control
                  (ecc-review-reread t)
                  (cl-letf* ((fontify (symbol-function 'ecc-review-ediff--fontify-buffer))
                             ((symbol-function 'ecc-review-ediff--fontify-buffer)
                              (lambda (text path)
                                (push path coloured)
                                (funcall fontify text path)))
                             (git (symbol-function 'ecc-review--git))
                             ((symbol-function 'ecc-review--git)
                              (lambda (directory &rest args)
                                (when (equal (car args) "cat-file") (cl-incf read))
                                (apply git directory args)))
                             (run (symbol-function 'call-process-region))
                             ((symbol-function 'call-process-region)
                              (lambda (&rest args)
                                (when (member "cat-file" args) (cl-incf read))
                                (apply run args))))
                    (ecc-review-reread t)
                    (should (zerop read))
                    (should-not coloured)
                    (ecc-review-ediff-test--write (concat directory "x.txt") "three\n")
                    (ecc-review-reread t)
                    (should (equal (delete-dups coloured) '("x.txt")))
                    ;; Its size, then its text: two processes.
                    (should (= read 2)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-says-nothing-as-the-diff-review-does ()
  "Both styles of review name a review with nothing in it alike."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-ediff-test--with-directory directory
      (ecc-review-ediff-test--repository directory)
      (setf (ecc-session-project-root session) directory)
      (dolist (range '(staged "" "HEAD"))
        (let ((diff (plist-get (ecc-review--worktree-content session range nil nil)
                               :nothing))
              (ediff (plist-get (ecc-review-ediff--content session range nil nil)
                                :nothing)))
          (should (equal diff ediff))))
      (should (string-prefix-p "Nothing is staged in "
                               (plist-get (ecc-review-ediff--content session 'staged nil nil)
                                          :nothing)))
      (should (ecc-review-ensure-baseline session))
      (should (equal (plist-get (ecc-review--session-content session nil) :nothing)
                     (plist-get (ecc-review-ediff--content session nil nil nil) :nothing))))))

;;;; Findings of the second review

(defun ecc-review-ediff-test--numbered (count &optional edit)
  "Return COUNT lines \"lN\", with EDIT, a function of N, giving other text."
  (mapconcat (lambda (n) (or (and edit (funcall edit n)) (format "l%d\n" n)))
             (number-sequence 1 count) ""))

(ert-deftest ecc-review-ediff-test-a-difference-comment-follows-the-old-side ()
  "Comments on whole differences stay on theirs as lines are put in above.
Fifteen lines put in above a change, a blank line that grows, and a
blank line put in further down that says the same."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (file (concat directory "c.txt")))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (ecc-review-ediff-test--write file (ecc-review-ediff-test--numbered 120))
                (ecc-review-ediff-test--git directory "add" "c.txt")
                (ecc-review-ediff-test--git directory "commit" "-q" "-m" "c")
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 file (ecc-review-ediff-test--numbered
                       120 (lambda (n) (pcase n
                                         (5 "l5\n\n") (40 "l40\n\n") (100 "L100\n")))))
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (ediff-jump-to-difference 1)
                  (ecc-review-ediff-comment "why the blank line?")
                  (ediff-jump-to-difference 3)
                  (ecc-review-ediff-comment "why capitals?")
                  (ecc-review-ediff-test--write
                   file (ecc-review-ediff-test--numbered
                         120 (lambda (n)
                               (pcase n
                                 (5 "l5\n\n(setq x 1)\n")
                                 (40 "l40\n\n")
                                 (89 (concat "l89\n" (ecc-review-ediff-test--numbered 15
                                                                                      (lambda (m) (format "new %d\n" m)))))
                                 (100 "L100\n")))))
                  (ecc-review-reread t)
                  (let ((on (lambda (text)
                              (let ((note (seq-find (lambda (note)
                                                      (equal (ecc-review-note-text note) text))
                                                    ecc-review--notes)))
                                (and (not (ecc-review-note-outdated note))
                                     (ecc-review-note-hunk-text note))))))
                    (should (equal (funcall on "why the blank line?")
                                   "@@ -6,0 +6,2 @@\n+\n+(setq x 1)"))
                    (should (string-search "-l100\n+L100" (funcall on "why capitals?"))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-session-in-a-subdirectory-keeps-its-files ()
  "A review restricted to some files, of a session in a subdirectory, is read again
with the same files: the paths it keeps are relative to the repository."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (sub (concat directory "sub/")))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (make-directory sub)
                (ecc-review-ediff-test--write (concat sub "a.el") "one\n")
                (ecc-review-ediff-test--write (concat sub "b.el") "one\n")
                (ecc-review-ediff-test--git directory "add" ".")
                (ecc-review-ediff-test--git directory "commit" "-q" "-m" "sub")
                (setf (ecc-session-project-root session) sub)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat sub "a.el") "two\n")
                (ecc-review-ediff-test--write (concat sub "b.el") "two\n")
                (setq control (ecc-review-ediff-buffer session (list "a.el")))
                (with-current-buffer control
                  (should (equal ecc-review--paths '("sub/a.el")))
                  (ecc-review-ediff-test--write (concat sub "a.el") "three\n")
                  (ecc-review-reread t)
                  (should (equal (mapcar #'car ecc-review-ediff--sections) '("sub/a.el")))
                  (should (= ediff-number-of-differences 1))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-reading-again-draws-once ()
  "Reading the review again draws its comments once, not on the way as well."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (drawn 0))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ediff-jump-to-difference 1)
                  (ecc-review-ediff-comment "kept")
                  (ecc-review-ediff-test--write (concat directory "a.txt")
                                                (concat "top\n" ecc-review-ediff-test--changed))
                  (cl-letf* ((draw (symbol-function 'ecc-review--draw-notes))
                             ((symbol-function 'ecc-review--draw-notes)
                              (lambda (&rest args) (cl-incf drawn) (apply draw args))))
                    (ecc-review-reread t))
                  (should (= drawn 1))
                  ;; ediff's own computing still draws.
                  (setq drawn 0)
                  (cl-letf* ((draw (symbol-function 'ecc-review--draw-notes))
                             ((symbol-function 'ecc-review--draw-notes)
                              (lambda (&rest args) (cl-incf drawn) (apply draw args))))
                    (ediff-update-diffs))
                  (should (= drawn 1))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-the-last-place-is-forgotten ()
  "Where the view was last moved is forgotten on a reading, on ediff's own
computing and on a comment being removed."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ecc-review-add-note 'claude "one" (ecc-review-ediff-test--line 'new 2))
                  (ecc-review-add-note 'claude "two" (ecc-review-ediff-test--line 'old 9))
                  (ecc-review--draw-notes)
                  (let ((move (lambda ()
                                (ecc-review-move-to (ecc-review-find-note 2) nil)
                                (should ecc-review-ediff--at))))
                    (funcall move)
                    (ecc-review-ediff-test--write
                     (concat directory "a.txt") (concat "top\n" ecc-review-ediff-test--changed))
                    (ecc-review-reread t)
                    (should-not ecc-review-ediff--at)
                    (funcall move)
                    (ediff-update-diffs)
                    (should-not ecc-review-ediff--at)
                    (funcall move)
                    (ecc-review-remove-note (ecc-review-find-note 1))
                    (should-not ecc-review-ediff--at))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-bang-shows-a-changed-setting ()
  "A setting that decides what is shown is part of what a reading compares."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "code.py") "def greet():\n    return 1\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (let ((face-of-def (lambda ()
                                       (with-current-buffer ediff-buffer-B
                                         (goto-char (point-min))
                                         (search-forward "def")
                                         (get-text-property (1- (point)) 'face)))))
                    (should (funcall face-of-def))
                    (let ((ecc-review-ediff-fontify nil))
                      (ecc-review-refresh)
                      (should-not (funcall face-of-def)))
                    (ecc-review-refresh)
                    (should (funcall face-of-def))
                    (let ((ecc-review-max-bytes 5))
                      (ecc-review-refresh)
                      (should (string-search "code.py (" (with-current-buffer ediff-buffer-B
                                                           (buffer-string))))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-file-git-will-not-give-is-named ()
  "A blob git will not give is named, not shown as created or deleted;
a submodule is named as one."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--repository directory)
    (let* ((root (ecc-review-git-root directory))
           (first (string-trim (ecc-review-ediff-test--git directory "rev-parse" "HEAD")))
           (left (ecc-review--head-tree root)))
      (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
      (ecc-review-ediff-test--git directory "add" "x.txt")
      (ecc-review-ediff-test--git directory "update-index" "--add" "--cacheinfo"
                                  (concat "160000," first ",module"))
      (ecc-review-ediff-test--git directory "commit" "-q" "-m" "module")
      (let ((right (ecc-review--head-tree root)))
        (should (equal (assoc "module" (ecc-review-ediff-pairs root left right))
                       '("module" "" "" "submodule, not shown" nil nil "A")))
        (let ((logged nil))
          (cl-letf* ((git (symbol-function 'ecc-review--git))
                     ((symbol-function 'ecc-review--git)
                      (lambda (directory &rest args)
                        (if (equal (car args) "cat-file")
                            '(128 . "fatal: bad object")
                          (apply git directory args))))
                     ;; The one process that reads every blob fails too,
                     ;; and each is then asked for alone.
                     (run (symbol-function 'call-process-region))
                     ((symbol-function 'call-process-region)
                      (lambda (&rest args)
                        (if (member "cat-file" args) 128 (apply run args))))
                     ((symbol-function 'ecc-log)
                      (lambda (&rest args) (push args logged))))
            (let ((pair (assoc "x.txt" (ecc-review-ediff-pairs root left right))))
              (should (string-prefix-p "could not be read: " (nth 3 pair)))
              (should (equal (nth 1 pair) ""))
              (should logged))))))))

;;;; What changed inside a line

(defconst ecc-review-ediff-test--themes
  '(;; NAME DARK CURRENT FINE REFINE DIFF
    ("modus-vivendi, added" t "#00381f" "#034f2f" "#034f2f" "#00381f")
    ("modus-vivendi, removed" t "#4f1119" "#781a1f" "#781a1f" "#4f1119")
    ("modus-operandi, added" nil "#c1f2d1" "#aee5be" "#aee5be" "#c1f2d1")
    ("modus-operandi, removed" nil "#ffd8d5" "#f3b5af" "#f3b5af" "#ffd8d5")
    ("leuven, added" nil "#DDFFDD" "#55FF55" "#97F295" "#DDFFDD")
    ("tango-dark, no diff faces" t "#555753" "#8f5902" unspecified unspecified)
    ("fine the same as current" t "#004f2b" "#004f2b" "#004f2b" "#00381f")
    ("near black" t "#050505" "#000000" unspecified "#020202")
    ("near white" nil "#fafafa" "#ffffff" unspecified "#fdfdfd")
    ("no fine face at all" t "#00381f" unspecified unspecified "#00381f"))
  "Backgrounds a theme gives the faces of a difference, real and made up.
CURRENT is `ediff-current-diff-A\=' and `-B\=', FINE `ediff-fine-diff-A\='
and `-B\=', REFINE `diff-refine-removed\=' and `-added\=', and DIFF
`diff-removed\=' and `diff-added\='.")

(ert-deftest ecc-review-ediff-test-what-changed-in-a-line-stands-apart ()
  "Under any theme the words that changed stand apart from their difference.
The background they are given is a clear step of lightness from the
current difference as the review paints it, and from the differences
around it, whatever the theme gave them; and they are bold."
  (let* ((faces '(ediff-current-diff-A ediff-current-diff-B ediff-fine-diff-A
                  ediff-fine-diff-B diff-refine-removed diff-refine-added
                  diff-removed diff-added))
         (saved (mapcar (lambda (face) (cons face (face-attribute face :background)))
                        faces))
         (wanted (/ ecc-review-ediff-fine-diff-contrast 100.0)))
    (unwind-protect
        (pcase-dolist (`(,name ,dark ,current ,fine ,refine ,diff) ecc-review-ediff-test--themes)
          (cl-letf (((symbol-function 'ecc-review-ediff--dark-p) (lambda () dark)))
            (dolist (pair `((ediff-current-diff-A . ,current) (ediff-current-diff-B . ,current)
                            (ediff-fine-diff-A . ,fine) (ediff-fine-diff-B . ,fine)
                            (diff-refine-removed . ,refine) (diff-refine-added . ,refine)
                            (diff-removed . ,diff) (diff-added . ,diff)))
              (set-face-attribute (car pair) nil :background (cdr pair)))
            (dolist (side '(A B))
              (let* ((attributes (ecc-review-ediff--fine side))
                     (background (plist-get attributes :background))
                     (painted (plist-get (ecc-review-ediff--stronger
                                          (if (eq side 'A) 'ediff-current-diff-A
                                            'ediff-current-diff-B))
                                         :background)))
                (should (eq (plist-get attributes :weight) 'bold))
                (should background)
                (dolist (other (delq nil (list painted (and (stringp diff) diff))))
                  (let ((apart (abs (- (ecc-review-ediff--lightness background)
                                       (ecc-review-ediff--lightness other)))))
                    (unless (>= apart wanted)
                      (ert-fail (list name side background other apart)))))))))
      (pcase-dolist (`(,face . ,background) saved)
        (set-face-attribute face nil :background background)))))

(ert-deftest ecc-review-ediff-test-colours-are-read-as-written ()
  "A colour in hex is read as written, and shaded by points of lightness.
A batch Emacs, like a terminal, answers the nearest colour it can show
when asked for the values of one: green for every dark green."
  (should (equal (ecc-review-ediff--shade "#00381f" 0) "#00381f"))
  (should (< (abs (- (ecc-review-ediff--lightness (ecc-review-ediff--shade "#00381f" 5))
                     (+ (ecc-review-ediff--lightness "#00381f") 0.05)))
             0.005))
  (should (equal (ecc-review-ediff--shade "#ffffff" 10) "#ffffff"))
  (should-not (ecc-review-ediff--shade 'unspecified 5)))

(ert-deftest ecc-review-ediff-test-fine-faces-are-the-reviews-own ()
  "The fine-difference faces are remapped in the two buffers of a review alone,
and not at all with `ecc-review-ediff-fine-diff-faces' off."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (dolist (on '(t nil))
      (ecc-test-with-fake-session session
        (ecc-review-ediff-test--with-directory directory
          (let ((control nil)
                (ecc-review-ediff-fine-diff-faces on))
            (unwind-protect
                (progn
                  (setq control (ecc-review-ediff-test--rich session directory))
                  (with-current-buffer control
                    (should-not (assq 'ediff-fine-diff-B face-remapping-alist))
                    (with-current-buffer (car ecc-review-ediff--buffers)
                      (should (eq on (and (assq 'ediff-fine-diff-A face-remapping-alist) t))))
                    (with-current-buffer (cdr ecc-review-ediff--buffers)
                      (should (eq on (and (assq 'ediff-fine-diff-B face-remapping-alist) t))))))
              (ecc-review-ediff-test--quit control))))))))

(defun ecc-review-ediff-test--long (session directory)
  "Make DIRECTORY a repository with a long a.txt changed near the top and the end.
Lines 3, 6 and 190 of 200 change a word each, and a file b.el comes
after it.  Open its ediff review of SESSION and return the control
buffer."
  (ecc-review-ediff-test--repository directory)
  (ecc-review-ediff-test--write (concat directory "a.txt")
                                (ecc-review-ediff-test--numbered 200))
  (ecc-review-ediff-test--write (concat directory "b.el") "(defun b () 1)\n")
  (ecc-review-ediff-test--git directory "add" "a.txt" "b.el")
  (ecc-review-ediff-test--git directory "commit" "-q" "-m" "long")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (ecc-review-ediff-test--write
   (concat directory "a.txt")
   (ecc-review-ediff-test--numbered
    200 (lambda (n) (and (memq n '(3 6 190)) (format "l%d changed\n" n)))))
  (ecc-review-ediff-test--write (concat directory "b.el") "(defun b () 2)\n")
  (ecc-review-ediff-buffer session))

(defun ecc-review-ediff-test--as-a-gui ()
  "Give this ediff session what a graphical Emacs gives it, and batch does not.
Highlighting with faces, and refining on.  The default of
`ediff-auto-refine' is worked out when ediff is loaded: Emacs 29 makes
it `nix' -- \"Refinements are HIDDEN\" -- where there is no face support,
as in batch, and Emacs 30 made it `on' everywhere.  Run in the control
buffer, with `ediff-force-faces' bound."
  (setq ediff-highlighting-style 'face
        ediff-auto-refine 'on))

(ert-deftest ecc-review-ediff-test-differences-on-the-screen-are-refined ()
  "What changed in the lines of every difference on the screen is marked,
not only in the current one, and nothing off the screen is refined;
the refining is a timer that runs once."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (ediff-force-faces t))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (should (timerp ecc-review-ediff--refine-timer))
                  (should-not (timer--repeat-delay ecc-review-ediff--refine-timer))
                  (ecc-review-ediff-test--as-a-gui)
                  (ediff-jump-to-difference 1)
                  (should (eq (ecc-review-ediff--refine-turn control) nil))
                  (should-not ecc-review-ediff--refine-timer)
                  ;; The second difference, on the screen and not current.
                  (let ((fine (ediff-get-fine-diff-vector 1 'B)))
                    (should (> (length fine) 0))
                    (should (eq (overlay-get (aref fine 0) 'face) 'ediff-fine-diff-B)))
                  ;; The third, 190 lines down, is left alone.
                  (should-not (ediff-get-fine-diff-vector 2 'B))
                  ;; Moving on: ediff unmarks the difference it leaves,
                  ;; which is still on the screen, and the review marks
                  ;; it again at once.
                  (ediff-unselect-and-select-difference 1 nil 'no-recenter)
                  (let ((fine (ediff-get-fine-diff-vector 0 'B)))
                    (should (eq (overlay-get (aref fine 0) 'face) 'ediff-fine-diff-B)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-refining-gives-way-to-the-keyboard ()
  "With input waiting nothing is refined, and the turn is put off."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (ediff-force-faces t))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (ecc-review-ediff-test--as-a-gui)
                  (ediff-jump-to-difference 1)
                  (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
                    (ecc-review-ediff--refine-turn control))
                  (should-not (ediff-get-fine-diff-vector 1 'B))
                  (should (timerp ecc-review-ediff--refine-timer))))
            (ecc-review-ediff-test--quit control)))))))

;;;; Findings of the review of Phase 5

(defun ecc-review-ediff-test--refining (session directory)
  "Open the long review of SESSION in DIRECTORY with faces, as a GUI has them.
Line 3 changes a word, a line is put in after line 6, and line 190
changes a word: the second is a difference ediff will not refine and
says so.  Return the control buffer, standing on the third difference."
  (ecc-review-ediff-test--repository directory)
  (ecc-review-ediff-test--write (concat directory "a.txt")
                                (ecc-review-ediff-test--numbered 200))
  (ecc-review-ediff-test--git directory "add" "a.txt")
  (ecc-review-ediff-test--git directory "commit" "-q" "-m" "long")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (ecc-review-ediff-test--write
   (concat directory "a.txt")
   (ecc-review-ediff-test--numbered
    200 (lambda (n) (pcase n
                      (3 "l3 changed\n")
                      (6 "l6\nput in\n")
                      (190 "l190 changed\n")))))
  (let ((control (ecc-review-ediff-buffer session)))
    (with-current-buffer control
      (ecc-review-ediff-test--as-a-gui)
      (ediff-unselect-and-select-difference 2 nil 'no-recenter))
    control))

(ert-deftest ecc-review-ediff-test-a-difference-is-refined-once ()
  "A difference on the screen is visited once, and what ediff says of it goes
nowhere: two turns over the same screen leave *Messages* as it was."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (ediff-force-faces t)
              (ediff-verbose-p t))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--refining session directory))
                (with-current-buffer control
                  (let ((size (with-current-buffer (messages-buffer) (buffer-size)))
                        (installed 0))
                    (cl-letf* ((install (symbol-function 'ediff-install-fine-diff-if-necessary))
                               ((symbol-function 'ediff-install-fine-diff-if-necessary)
                                (lambda (n) (cl-incf installed) (funcall install n))))
                      (ecc-review-ediff--refine-turn control)
                      (should (= installed 2))
                      (ecc-review-ediff--refine-turn control)
                      (should (= installed 2)))
                    (should (= size (with-current-buffer (messages-buffer) (buffer-size)))))
                  ;; Computed again, they are visited again.
                  (ecc-review-ediff--differences-computed)
                  (should-not ecc-review-ediff--refined)))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-refinements-follow-at-and-h ()
  "`@' at hidden and `h' off the other differences clear what the review
refined outside the current difference; back on, it refines again."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (ediff-force-faces t))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (ecc-review-ediff-test--as-a-gui)
                  (ediff-unselect-and-select-difference 0 nil 'no-recenter)
                  (ecc-review-ediff--refine-turn control)
                  (should (ediff-get-fine-diff-vector 1 'B))
                  (should (eq (lookup-key ediff-mode-map "@")
                              #'ecc-review-ediff-toggle-autorefine))
                  (should (eq (lookup-key ediff-mode-map "h")
                              #'ecc-review-ediff-toggle-hilit))
                  ;; @: on, off -- what is marked stays -- then hidden.
                  (ecc-review-ediff-toggle-autorefine)
                  (should (eq ediff-auto-refine 'off))
                  (should (ediff-get-fine-diff-vector 1 'B))
                  (ecc-review-ediff-toggle-autorefine)
                  (should (eq ediff-auto-refine 'nix))
                  (should-not (ediff-get-fine-diff-vector 1 'B))
                  (ecc-review-ediff--refine-turn control)
                  (should-not (ediff-get-fine-diff-vector 1 'B))
                  ;; And on again.
                  (ecc-review-ediff-toggle-autorefine)
                  (should (timerp ecc-review-ediff--refine-timer))
                  (ecc-review-ediff--refine-turn control)
                  (should (ediff-get-fine-diff-vector 1 'B))
                  ;; h: the other differences unpainted, then ASCII flags,
                  ;; none, and faces on every difference again.
                  (ecc-review-ediff-toggle-hilit)
                  (should-not ediff-highlight-all-diffs)
                  (should-not (ediff-get-fine-diff-vector 1 'B))
                  (ecc-review-ediff--refine-turn control)
                  (should-not (ediff-get-fine-diff-vector 1 'B))
                  (ecc-review-ediff-toggle-hilit)
                  (ecc-review-ediff-toggle-hilit)
                  (ecc-review-ediff-toggle-hilit)
                  (should ediff-highlight-all-diffs)
                  (should (eq ediff-highlighting-style 'face))
                  (ecc-review-ediff--refine-turn control)
                  (should (ediff-get-fine-diff-vector 1 'B))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-large-file-is-coloured-in-slices ()
  "A large file is coloured a chunk at a time: a turn stops at the first
chunk that ends past its slice, the file takes many turns and comes out
coloured, and a file with a line too long to colour is left plain.  The
clock is one that each chunk moves on by a fixed step, so that what is
asserted is the slicing rather than the speed of the machine; the real
times are `scripts/bench-review-ediff.el's."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (clock 1000.0)
              (chunks 0)
              (most 0)
              (turns 0)
              (ecc-review-max-bytes 1000000)
              (ecc-review-ediff-colour-first 0.01)
              (ecc-review-ediff-colour-slice 0.01))
          (unwind-protect
              (cl-letf* ((chunk (symbol-function 'ecc-review-ediff--fontify-chunk))
                         ((symbol-function 'ecc-review-ediff--fontify-chunk)
                          (lambda (buffer from)
                            ;; Each chunk takes 4 ms of this clock.
                            (setq clock (+ clock 0.004)
                                  chunks (1+ chunks))
                            (funcall chunk buffer from)))
                         ((symbol-function 'float-time) (lambda (&rest _) clock))
                         ((symbol-function 'input-pending-p) #'ignore))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "big.el")
                 (mapconcat (lambda (n) (format "(defun f%d (x)\n  \"Doc %d.\"\n  (+ x %d))\n" n n n))
                            (number-sequence 1 6000) ""))
                (ecc-review-ediff-test--write
                 (concat directory "min.el")
                 (concat "(defun m () \"" (make-string 5000 ?x) "\")\n"))
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (while (timerp ecc-review-ediff--colour-timer)
                    (setq chunks 0)
                    (ecc-review-ediff--colour-turn control)
                    (setq most (max most chunks)
                          turns (1+ turns)))
                  ;; 10 ms of 4 ms chunks: the third ends past the slice.
                  (should (= most 3))
                  (should (> turns 5))
                  (with-current-buffer ediff-buffer-B
                    (goto-char (point-max))
                    (search-backward "defun f6000")
                    (should (get-text-property (point) 'face))
                    (goto-char (point-min))
                    (search-forward "(defun m")
                    (should-not (get-text-property (1- (point)) 'face)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-turn-of-colouring-can-be-quit ()
  "C-g in a turn of colouring quits it as `with-local-quit' does: the quit
waits, in `quit-flag', for wherever quitting is allowed, rather than
unwinding into what ran the timer.  The file is taken up again from
where it was."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (calls 0)
              (allowed nil)
              (flagged nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (let ((job (car (buffer-local-value 'ecc-review-ediff--uncoloured
                                                      ediff-buffer-B))))
                    (cl-letf* ((chunk (symbol-function 'ecc-review-ediff--fontify-chunk))
                               ((symbol-function 'ecc-review-ediff--fontify-chunk)
                                (lambda (buffer from)
                                  (setq allowed (not inhibit-quit))
                                  (if (= (cl-incf calls) 1)
                                      (signal 'quit nil)
                                    (funcall chunk buffer from)))))
                      ;; As a timer runs: quitting inhibited around it.
                      (let ((inhibit-quit t))
                        (ecc-review-ediff--colour-turn control)
                        (setq flagged quit-flag
                              quit-flag nil))
                      (should allowed)
                      (should flagged)
                      (should (memq job (buffer-local-value 'ecc-review-ediff--uncoloured
                                                            ediff-buffer-B)))
                      (should (timerp ecc-review-ediff--colour-timer))
                      (ecc-review-ediff--colour nil)
                      (should-not (buffer-local-value 'ecc-review-ediff--uncoloured
                                                      ediff-buffer-B))))))
            (ecc-review-ediff-test--quit control)))))))

(defun ecc-review-ediff-test--fontify-buffers ()
  "Return the buffers colouring fontifies files in that are still there."
  (seq-filter (lambda (buffer)
                (string-prefix-p " *ecc-review-fontify*" (buffer-name buffer)))
              (buffer-list)))

(ert-deftest ecc-review-ediff-test-colouring-gives-way-to-input ()
  "With input waiting, colouring runs one chunk at most -- in a turn of the
timer and in the colouring of what is on the screen as the review opens."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (chunks 0))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (cl-letf* ((chunk (symbol-function 'ecc-review-ediff--fontify-chunk))
                             ((symbol-function 'ecc-review-ediff--fontify-chunk)
                              (lambda (buffer from) (cl-incf chunks) (funcall chunk buffer from)))
                             ((symbol-function 'input-pending-p) (lambda (&rest _) t))
                             (ecc-review-ediff-fontify-chunk 1))
                    ;; The first pass, with b.el brought on the screen.
                    (set-window-start ediff-window-B
                                      (marker-position
                                       (ecc-review-ediff--job-beg
                                        (car (buffer-local-value 'ecc-review-ediff--uncoloured
                                                                 ediff-buffer-B)))))
                    (ecc-review-ediff--colour (+ (float-time) 10) t)
                    (should (= chunks 1))
                    ;; A turn: nothing at all.
                    (setq chunks 0)
                    (ecc-review-ediff--colour-turn control)
                    (should (= chunks 0))
                    (should (timerp ecc-review-ediff--colour-timer)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-no-fontify-buffer-is-left-behind ()
  "The buffers files are fontified in go with the review: when a side is
killed in the middle of colouring, when the review is quit, and when
setting a mode up is quit."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        ;; Two lines at a time, and no time on opening: a.txt is begun
        ;; as the review opens, and left half done, its buffer open.
        (let ((control nil)
              (ecc-review-ediff-fontify-chunk 2)
              (ecc-review-ediff-colour-first 0))
          (unwind-protect
              (progn
                (mapc #'kill-buffer (ecc-review-ediff-test--fontify-buffers))
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (should (ecc-review-ediff-test--fontify-buffers))
                  (let ((now (cdr ecc-review-ediff--buffers))
                        (kill-buffer-query-functions nil))
                    (with-current-buffer now (set-buffer-modified-p nil))
                    (kill-buffer now))
                  (ecc-review-ediff--colour-turn control)
                  (should-not (ecc-review-ediff-test--fontify-buffers))))
            (when (buffer-live-p control)
              (ignore-errors (ecc-review-ediff-quit control)))
            (when (buffer-live-p control)
              (kill-buffer control))
            (ecc-review-ediff-test--kill-buffers))
          ;; Quitting the review, a file half coloured.
          (ecc-review-ediff-test--with-directory second
            (unwind-protect
                (progn
                  (setq control (ecc-review-ediff-test--long session second))
                  (should (ecc-review-ediff-test--fontify-buffers)))
              (ecc-review-ediff-test--quit control)))
          (should-not (ecc-review-ediff-test--fontify-buffers))
          ;; A quit while the mode is set up.
          (cl-letf (((symbol-function 'set-auto-mode) (lambda (&rest _) (signal 'quit nil))))
            (should (eq (condition-case nil
                            (ecc-review-ediff--fontify-buffer "(defun x ())\n" "x.el")
                          (quit 'quit))
                        'quit)))
          (should-not (ecc-review-ediff-test--fontify-buffers)))))))

(ert-deftest ecc-review-ediff-test-a-quit-on-opening-leaves-the-rest-to-the-timers ()
  "A quit of the colouring done as the review opens leaves the colouring and
the refining of the rest set to run."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (dolist (timer (list ecc-review-ediff--colour-timer
                                       ecc-review-ediff--refine-timer))
                    (when (timerp timer) (cancel-timer timer)))
                  (setq ecc-review-ediff--colour-timer nil
                        ecc-review-ediff--refine-timer nil)
                  (cl-letf (((symbol-function 'ecc-review-ediff--colour)
                             (lambda (&rest _) (signal 'quit nil))))
                    (should (eq (condition-case nil
                                    (ecc-review-ediff--after-write)
                                  (quit 'quit))
                                'quit)))
                  (should (timerp ecc-review-ediff--colour-timer))
                  (should (timerp ecc-review-ediff--refine-timer))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-chunks-colour-as-a-whole-does ()
  "Coloured a few lines at a time, with a docstring and a comment block across
the boundaries, a file comes out as it does coloured all at once."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let* ((control nil)
               (ecc-review-ediff-fontify-chunk 2)
               (text (concat ";;; m.el --- x  -*- lexical-binding: t; -*-\n"
                             "(defun f (x)\n  \"A docstring\nover several\nlines,\n"
                             "with (parens) and `quotes'.\"\n  (+ x 1))\n"
                             "#|\n;; a\n;; b\n|#\n(defvar v \"one\ntwo\nthree\")\n")))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "m.el") text)
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (ecc-review-ediff--colour nil)
                  (with-current-buffer ediff-buffer-B
                    (goto-char (point-min))
                    (let ((beg (progn (search-forward "═══ m.el ═══\n") (point))))
                      (should (equal-including-properties
                               (ecc-review-ediff--faces-only
                                (buffer-substring beg (+ beg (length text))))
                               (ecc-review-ediff--fontify text "m.el")))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-difference-left-stays-marked ()
  "The difference ediff leaves keeps the marks of what changed in it, whether
ediff refined it as the current one or the review did; hidden, it does
not."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (ediff-force-faces t))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (ecc-review-ediff-test--as-a-gui)
                  ;; On the first: ediff refines it.
                  (ediff-unselect-and-select-difference 0 nil 'no-recenter)
                  (let ((fine (ediff-get-fine-diff-vector 0 'B)))
                    (should (eq (overlay-get (aref fine 0) 'face) 'ediff-fine-diff-B))
                    ;; Off it: still marked.
                    (ediff-unselect-and-select-difference 1 nil 'no-recenter)
                    (should (eq (overlay-get (aref fine 0) 'face) 'ediff-fine-diff-B))
                    ;; Hidden, then on again: leaving it unmarks it.
                    (ecc-review-ediff-toggle-autorefine)
                    (ecc-review-ediff-toggle-autorefine)
                    (should (eq ediff-auto-refine 'nix))
                    (ecc-review-ediff-toggle-autorefine)
                    (should (eq ediff-auto-refine 'on))
                    (ediff-unselect-and-select-difference 0 nil 'no-recenter)
                    (ecc-review-ediff-toggle-autorefine)
                    (ecc-review-ediff-toggle-autorefine)
                    (ediff-unselect-and-select-difference 1 nil 'no-recenter)
                    (let ((fine (ediff-get-fine-diff-vector 0 'B)))
                      (should-not (and fine (overlay-get (aref fine 0) 'face)))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-colours-are-the-same-read-again ()
  "A file coloured as the review opens and the same file written again from
what was kept carry the same text properties: faces, and nothing a mode
hides or links with."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (text-of (lambda ()
                         (with-current-buffer ediff-buffer-B
                           (goto-char (point-min))
                           (let ((beg (progn (search-forward "═══ notes.org ═══\n") (point))))
                             (buffer-substring beg (progn (search-forward "end\n") (point))))))))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "notes.org")
                 "* Heading\nSee [[https://example.com][the site]] and *bold*.\nend\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (ecc-review-ediff--colour nil)
                  (let ((first (funcall text-of)))
                    (should (text-property-not-all 0 (length first) 'face nil first))
                    (should-not (text-property-not-all 0 (length first) 'invisible nil first))
                    (should-not (text-property-not-all 0 (length first) 'help-echo nil first))
                    ;; Another file changes: notes.org goes in from what was kept.
                    (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                    (ecc-review-reread t)
                    (with-current-buffer ediff-buffer-B
                      (should-not (seq-find (lambda (job)
                                              (equal (ecc-review-ediff--job-path job) "notes.org"))
                                            ecc-review-ediff--uncoloured)))
                    (should (equal-including-properties first (funcall text-of))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-file-is-coloured-where-it-is ()
  "Text put in above a file still to be coloured moves its colours with it,
and a file whose own text changed under it is left as it is."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (with-current-buffer ediff-buffer-B
                    (should (= (length ecc-review-ediff--uncoloured) 1))
                    (let ((inhibit-read-only t))
                      (goto-char (point-min))
                      (insert "put in above\n")))
                  (ecc-review-ediff--colour nil)
                  (with-current-buffer ediff-buffer-B
                    (goto-char (point-max))
                    (search-backward "═══ b.el ═══")
                    (should (eq (get-text-property (point) 'face) 'ecc-heading-face))
                    (search-forward "(defun")
                    (should (get-text-property (1- (point)) 'face))
                    (should (eq (get-text-property (- (point) 5) 'face)
                                (get-text-property (1- (point)) 'face))))
                  ;; Read again, then the file's own text changed under it.
                  (ecc-review-ediff-test--write (concat directory "b.el") "(defun b () 4)\n")
                  (ecc-review-reread t)
                  (with-current-buffer ediff-buffer-B
                    (let ((job (car ecc-review-ediff--uncoloured))
                          (inhibit-read-only t))
                      (goto-char (ecc-review-ediff--job-beg job))
                      (insert "x")))
                  (ecc-review-ediff--colour nil)
                  (with-current-buffer ediff-buffer-B
                    (should-not ecc-review-ediff--uncoloured)
                    (goto-char (point-max))
                    (search-backward "(defun b () 4)")
                    (should-not (get-text-property (point) 'face)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-killed-side-stops-the-timers ()
  "With a side killed under a live control buffer, a turn of colouring or
refining stops without calling into ediff, and sets no timer again."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (ediff-force-faces t))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (ecc-review-ediff-test--as-a-gui)
                  (let ((base (car ecc-review-ediff--buffers)))
                    (with-current-buffer base (set-buffer-modified-p nil))
                    (let ((kill-buffer-query-functions nil))
                      (kill-buffer base)))
                  (cl-letf (((symbol-function 'ediff-install-fine-diff-if-necessary)
                             (lambda (&rest _) (ert-fail "ediff was called"))))
                    (ecc-review-ediff--refine-turn control)
                    (ecc-review-ediff--colour-turn control))
                  (should-not ecc-review-ediff--refine-timer)
                  (should-not ecc-review-ediff--colour-timer)
                  (with-current-buffer (cdr ecc-review-ediff--buffers)
                    (should-not ecc-review-ediff--uncoloured))))
            (when (buffer-live-p control)
              (ignore-errors (ecc-review-ediff-quit control)))
            (when (buffer-live-p control)
              (kill-buffer control))
            (ecc-review-ediff-test--kill-buffers)))))))

(ert-deftest ecc-review-ediff-test-a-blob-too-large-is-not-decoded ()
  "A blob over `ecc-review-max-bytes' is never read: its size comes from
`git cat-file --batch-check', its bytes are not asked of `--batch', and
it is named without being read alone."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--repository directory)
    (let* ((root (ecc-review-git-root directory))
           (left (ecc-review--head-tree root))
           (cache (make-hash-table :test #'equal))
           (alone 0)
           (asked nil))
      (ecc-review-ediff-test--write (concat directory "x.txt") (make-string 400 ?y))
      (ecc-review-ediff-test--write (concat directory "small.txt") "small\n")
      (ecc-review-ediff-test--git directory "add" ".")
      (ecc-review-ediff-test--git directory "commit" "-q" "-m" "big")
      (cl-letf* ((git (symbol-function 'ecc-review--git))
                 ((symbol-function 'ecc-review--git)
                  (lambda (directory &rest args)
                    (when (equal (car args) "cat-file") (cl-incf alone))
                    (apply git directory args)))
                 (run (symbol-function 'call-process-region))
                 ((symbol-function 'call-process-region)
                  (lambda (start end &rest args)
                    (when (member "--batch" args)
                      (push (buffer-substring start end) asked))
                    (apply run start end args))))
        (let* ((ecc-review-max-bytes 100)
               (pairs (ecc-review-ediff-pairs root left (ecc-review--head-tree root) nil cache))
               (big (assoc "x.txt" pairs))
               (blob (string-trim (ecc-review-ediff-test--git directory "rev-parse" "HEAD:x.txt"))))
          (should (equal (nth 3 big) "400, not shown"))
          (should (equal (nth 2 (assoc "small.txt" pairs)) "small\n"))
          (should (zerop alone))
          (should (= (gethash (cons 'size blob) cache) 400))
          (should-not (gethash (cons 'raw blob) cache))
          ;; Its bytes were never asked for.
          (should (= (length asked) 1))
          (should-not (string-search blob (car asked))))))))

;;;; Opening faster

(ert-deftest ecc-review-ediff-test-colours-come-after-the-review-opens ()
  "A review opens with what is on the screen coloured and the rest plain,
and colours the rest a slice at a time on a timer that runs once,
giving way to the keyboard.  The colours touch neither the text nor the
comments, and each of two reviews colours its own."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session one
      (ecc-test-with-fake-session two
        (ecc-review-ediff-test--with-directory first
          (ecc-review-ediff-test--with-directory second
            (let ((controls nil)
                  (face-of-defun
                   (lambda ()
                     (with-current-buffer ediff-buffer-B
                       (goto-char (point-max))
                       (search-backward "defun")
                       (get-text-property (point) 'face)))))
              (unwind-protect
                  (progn
                    (push (ecc-review-ediff-test--long one first) controls)
                    (push (ecc-review-ediff-test--long two second) controls)
                    (with-current-buffer (car controls)
                      ;; On the screen: the top of a.txt.  Off it: b.el.
                      (with-current-buffer ediff-buffer-B
                        (goto-char (point-min))
                        (should (eq (get-text-property (point) 'face) 'ecc-heading-face)))
                      (should-not (funcall face-of-defun))
                      (should (timerp ecc-review-ediff--colour-timer))
                      (should-not (timer--repeat-delay ecc-review-ediff--colour-timer))
                      ;; Input waiting: nothing is coloured, the turn is put off.
                      (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
                        (ecc-review-ediff--colour-turn (current-buffer)))
                      (should-not (funcall face-of-defun))
                      (should (timerp ecc-review-ediff--colour-timer))
                      (ecc-review-add-note 'user "A comment" (ecc-review-ediff-test--line 'new 3))
                      (ecc-review--draw-notes)
                      (let ((ticks (ecc-review-ediff--ticks))
                            (drawn (ecc-review-ediff-test--drawn ediff-buffer-B)))
                        (while (timerp ecc-review-ediff--colour-timer)
                          (ecc-review-ediff--colour-turn (current-buffer)))
                        (should (funcall face-of-defun))
                        (should (equal ticks (ecc-review-ediff--ticks)))
                        (should (equal drawn (ecc-review-ediff-test--drawn ediff-buffer-B)))
                        (should-not (buffer-modified-p ediff-buffer-B))))
                    ;; The other review is still waiting for its own turn.
                    (with-current-buffer (cadr controls)
                      (should-not (funcall face-of-defun))
                      (should (timerp ecc-review-ediff--colour-timer))))
                (dolist (control controls)
                  (when (buffer-live-p control)
                    (ecc-review-ediff-quit control)))
                (ecc-review-ediff-test--kill-buffers)))))))))

(ert-deftest ecc-review-ediff-test-a-file-read-again-is-coloured-again ()
  "A file that changed while the review was open goes in plain, and is
coloured once it is on the screen; the files that did not change keep
their colours."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--long session directory))
                (with-current-buffer control
                  (ecc-review-ediff--colour nil)
                  (ecc-review-ediff-test--write (concat directory "b.el") "(defun b () 3)\n")
                  (ecc-review-reread t)
                  (with-current-buffer ediff-buffer-B
                    (should (equal (mapcar #'ecc-review-ediff--job-path
                                           ecc-review-ediff--uncoloured)
                                   '("b.el"))))
                  (ecc-review-ediff--colour nil)
                  (with-current-buffer ediff-buffer-B
                    (should-not ecc-review-ediff--uncoloured)
                    (goto-char (point-max))
                    (search-backward "defun")
                    (should (get-text-property (point) 'face)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-ediff-progress-is-not-shown ()
  "ediff's progress messages are not shown while a review is built or read
again; every other message goes on to the function that shows it."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let* ((control nil)
               (shown nil)
               (set-message-function (lambda (message) (push message shown) nil))
               (answers nil)
               (ask (lambda ()
                      (push (list (funcall set-message-function
                                           "Buffer A: Processing difference region 10 of 30")
                                  (funcall set-message-function "Processing difference regions ... done")
                                  (funcall set-message-function "Computing differences ...")
                                  (funcall set-message-function "Something else"))
                            answers))))
          (unwind-protect
              (cl-letf* ((buffers (symbol-function 'ediff-buffers))
                         ((symbol-function 'ediff-buffers)
                          (lambda (&rest args) (funcall ask) (apply buffers args)))
                         (compute (symbol-function 'ecc-review-ediff--compute-differences))
                         ((symbol-function 'ecc-review-ediff--compute-differences)
                          (lambda () (funcall ask) (funcall compute))))
                (setq control (ecc-review-ediff-test--rich session directory))
                (ecc-review-ediff-test--write (concat directory "a.txt") "other\n")
                (with-current-buffer control
                  (ecc-review-reread t))
                (should (= (length answers) 2))
                (dolist (answer answers)
                  (should (equal answer '(t t t nil))))
                (should (equal shown '("Something else" "Something else"))))
            (ecc-review-ediff-test--quit control)))))))

;;;; Opening faster

(ert-deftest ecc-review-ediff-test-every-blob-in-one-process ()
  "Both sides of every file are read by one `git cat-file --batch'.
Each text is what reading the blob alone gives; a blob that process
does not give is read alone, and a blob read before is not read again."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--repository directory)
    (let* ((root (ecc-review-git-root directory))
           (left (ecc-review--head-tree root)))
      (ecc-review-ediff-test--write (concat directory "x.txt") "two\nえ\n")
      (ecc-review-ediff-test--write (concat directory "gone.txt") "still here\n")
      (ecc-review-ediff-test--write (concat directory "new.txt") "")
      (ecc-review-ediff-test--write (concat directory "crlf.txt") "a\r\nb\r\n")
      (ecc-review-ediff-test--git directory "add" ".")
      (ecc-review-ediff-test--git directory "commit" "-q" "-m" "more")
      (let ((right (ecc-review--head-tree root))
            (batches 0)
            (alone 0)
            (cache (make-hash-table :test #'equal)))
        (cl-letf* ((git (symbol-function 'ecc-review--git))
                   ((symbol-function 'ecc-review--git)
                    (lambda (directory &rest args)
                      (when (equal (car args) "cat-file") (cl-incf alone))
                      (apply git directory args)))
                   (run (symbol-function 'call-process-region))
                   ((symbol-function 'call-process-region)
                    (lambda (&rest args)
                      (when (member "--batch" args) (cl-incf batches))
                      (apply run args))))
          (let ((pairs (ecc-review-ediff-pairs root left right nil cache)))
            (should (= batches 1))
            (should (zerop alone))
            (pcase-dolist (`(,path ,before ,after ,_ ,before-blob ,after-blob) pairs)
              (should (equal before (if before-blob
                                        (cdr (ecc-review--git root "cat-file" "blob" before-blob))
                                      "")))
              (should (equal after (if after-blob
                                       (cdr (ecc-review--git root "cat-file" "blob" after-blob))
                                     "")))
              (when (equal path "x.txt") (should (equal after "two\nえ\n")))
              (when (equal path "crlf.txt") (should (equal after "a\r\nb\r\n")))))
          ;; Read again through the same cache: nothing is read.
          (setq batches 0 alone 0)
          (ecc-review-ediff-pairs root left right nil cache)
          (should (zerop batches))
          (should (zerop alone))
          ;; A blob the one process leaves out is asked for alone.
          (cl-letf (((symbol-function 'call-process-region)
                     (lambda (&rest _) 0)))
            (should (equal (nth 2 (assoc "x.txt" (ecc-review-ediff-pairs root left right)))
                           "two\nえ\n")))
          (should (> alone 0)))))))

(ert-deftest ecc-review-ediff-test-hidden-comments-are-not-offered ()
  "C-u d leaves out Claude's comments while they are hidden, in both reviews."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (offered nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ecc-review-add-note 'claude "Claude's" (ecc-review-ediff-test--line 'new 2))
                  (ediff-jump-to-difference 3)
                  (ecc-review-ediff-comment "mine")
                  (ecc-review-toggle-agent)
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt labels &rest _) (setq offered labels) (car labels))))
                    (ecc-review-ediff-remove-comment t))
                  (should (= (length offered) 1))
                  (should (string-search "mine" (car offered))))
                (ecc-review-ediff-test--quit control)
                (setq control nil)
                (with-current-buffer
                    (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                                      session "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n"
                                      temporary-file-directory)
                  (goto-char (point-min))
                  (re-search-forward "^\\+b")
                  (beginning-of-line)
                  (ecc-review-add-note 'claude "Claude's" (ecc-review--line-at-point))
                  (ecc-review-comment "mine")
                  (ecc-review-toggle-agent)
                  (setq offered nil)
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt labels &rest _) (setq offered labels) (car labels))))
                    (ecc-review-remove-comment t))
                  (should (= (length offered) 1))
                  (should (string-search "mine" (car offered)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-c-asks-whenever-there-is-a-choice ()
  "With one comment of Claude's to answer, c still offers a new comment;
RET answers Claude.  With nothing to answer or edit, nothing is asked."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (asked nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt labels _ _ _ _ default)
                               (push labels asked)
                               default)))
                    (ediff-jump-to-difference 2)
                    (should (equal (ecc-review-ediff--read-choice
                                    (ecc-review-ediff--current-unit))
                                   '(nil)))
                    (should-not asked)
                    (ecc-review-add-note 'claude "Why?" (ecc-review-ediff-test--line 'new 2))
                    (ecc-review--draw-notes)
                    (ediff-jump-to-difference 1)
                    (let ((choice (ecc-review-ediff--read-choice
                                   (ecc-review-ediff--current-unit))))
                      (should (= (length (car asked)) 2))
                      (should (member "new comment" (car asked)))
                      (should (eq (car choice) 'reply))))))
            (ecc-review-ediff-test--quit control)))))))

;;;; The setting

(ert-deftest ecc-review-ediff-test-style-chooses-the-review ()
  "`ecc-review-style' decides which of the two `ecc-review' opens."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                ;; The default is the one diff-mode buffer.
                (should (eq ecc-review-style 'diff))
                (ecc-review session)
                (should (buffer-live-p (get-buffer "*ecc-review: test*")))
                (ecc-review-ediff-test--kill-buffers)
                (let ((ecc-review-style 'ediff))
                  (setq control (ecc-review session))
                  (should (buffer-live-p control))
                  (should (with-current-buffer control (derived-mode-p 'ediff-mode)))
                  (should-not (get-buffer "*ecc-review: test*"))))
            (ecc-review-ediff-test--quit control)))))))

(provide 'ecc-review-ediff-test)

;;; ecc-review-ediff-test.el ends here
