;;; ecc-review-ediff-test.el --- Tests for ecc-review-ediff  -*- lexical-binding: t; -*-

;;; Commentary:

;; The concatenated buffers, the trees each review compares, a comment
;; on a difference turned into the prompt, sending it, and the keys
;; and point of the two windows.  Every test drives ediff by hand with
;; `ediff-setup-windows-plain', which works in batch; the git cases
;; build a throwaway repository the way `ecc-review-test' does.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-files)
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
  (let ((result (apply #'ecc-git-run directory args)))
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
  `(let ((ediff-window-setup-function #'ediff-setup-windows-plain)
         (ecc-review-ediff-layout 'side-by-side))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
        (should (ecc-git-ensure-baseline session))
        (should-error (ecc-review-ediff-buffer session) :type 'user-error)))))

(ert-deftest ecc-review-ediff-test-layout-can-be-set-back ()
  "The spacing can be undone, and the split is the review's own."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((ecc-review-ediff-file-spacing 0))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-git-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (ecc-review-ediff-test--write (concat directory "made.txt") "new\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  ;; No blank line between the files.
                  (should (equal (with-current-buffer (cdr ecc-review-ediff--buffers)
                                   (buffer-string))
                                 "═══ made.txt ═══\nnew\n═══ x.txt ═══\ntwo\n"))
                  ;; Side by side, as asked, in this review alone.
                  (should (eq ediff-split-window-function #'split-window-horizontally))
                  (should (eq (default-value 'ediff-split-window-function)
                              #'split-window-vertically))
                  (should (< (car (window-edges ediff-window-A))
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
                (should (ecc-git-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (dolist (key '("c -comment" "x -remove" "l -list"
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
                  ;; One line, and no key but ?: the keys, and where the
                  ;; review is, are on the header lines of the two
                  ;; windows.
                  (should (equal ediff-brief-help-message " ? all keys"))
                  ;; And it is in the panel, not only in the variable:
                  ;; `ediff-setup' writes the help out before it runs
                  ;; the startup hooks.
                  (should (equal ediff-help-message ediff-brief-help-message))
                  (should (equal (string-trim (buffer-string)) "? all keys"))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
               (should (ecc-git-ensure-baseline ,session))
               (ecc-review-ediff-test--write (concat directory "x.txt") ,new)
               (setq ,control (ecc-review-ediff-buffer ,session))
               (with-current-buffer ,control
                 ,@body))
           (ecc-review-ediff-test--quit ,control))))))

(ert-deftest ecc-review-ediff-test-the-watch-goes-on-with-a-review ()
  "An ediff review puts the watch of the files on, as a diff review does.
Its control buffer is in `ediff-mode\=', so `ecc-review-mode\=' installing
it is not enough."
  (skip-unless (and (executable-find "git") (executable-find ediff-diff-program)))
  (let ((hooks '(after-save-hook window-buffer-change-functions)))
    (ecc-test-with-global-hooks hooks
      (ecc-test-with-fake-session session
        (ecc-review-ediff-test--with-one-file session control "one\n" "two\n"
          (should (derived-mode-p 'ediff-mode))
          (should (memq #'ecc-review--on-save (default-value 'after-save-hook)))
          (should (memq #'ecc-review--on-window-buffer-change
                        (default-value 'window-buffer-change-functions))))))))

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
  ;; It goes around ediff's own when a review opens, before Emacs 31.
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-ediff-test--with-one-file session _control "one\n" "two\n"
      (should (eq (< emacs-major-version 31)
                  (and (advice-member-p #'ecc-review-ediff--recenter-one-window
                                        'ediff-recenter-one-window)
                       t))))))

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
                (should (ecc-git-ensure-baseline session))
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
  "Every range `ecc-review-range' takes resolves to two trees."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--repository directory)
    (ecc-review-ediff-test--write (concat directory "x.txt") "second\n")
    (ecc-review-ediff-test--git directory "commit" "-q" "-a" "-m" "second")
    (let* ((root (ecc-git-root directory))
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
        (should (equal (car trees) (ecc-git-snapshot root t)))
        (should-not (equal (car trees) head)))
      (should-error (ecc-review-ediff--trees root "no-such-revision")
                    :type 'user-error))))

(ert-deftest ecc-review-ediff-test-trees-without-commits ()
  "HEAD in a repository with no commit is the empty tree."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--git directory "init" "-q")
    (ecc-review-ediff-test--write (concat directory "x.txt") "one\n")
    (let* ((root (ecc-git-root directory))
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
                (setq control (ecc-review-ediff-range-buffer session))
                (with-current-buffer control
                  (should (equal ecc-review--range "HEAD"))
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("gone.txt" "new.txt" "x.txt")))
                  (should (= ediff-number-of-differences 3)))
                (ecc-review-ediff-test--quit control)
                ;; Without a revision only what is not staged is shown.
                (setq control (ecc-review-ediff-range-buffer session ""))
                (with-current-buffer control
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("new.txt" "x.txt")))))
            (ecc-review-ediff-test--quit control)))))))

;;;; Comments and the prompt

(defun ecc-review-ediff-test--setup (session directory)
  "Make DIRECTORY a repository SESSION changed two files of, and open it."
  (ecc-review-ediff-test--repository directory)
  (setf (ecc-session-project-root session) directory)
  (should (ecc-git-ensure-baseline session))
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

;; d scrolls the reply pane in an ediff review, and x removes a comment.
(ert-deftest ecc-review-ediff-test-no-comment-here-names-x ()
  "Off any comment, removing one says C-u x offers them all: the key it is bound to."
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
                  (let ((message (cadr (should-error (ecc-review-ediff-remove-comment)
                                                     :type 'user-error))))
                    (should (string-search "C-u x offers them all" message))
                    (should-not (string-search "C-u d" message)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-send ()
  "C-c C-c sends the comments as the diff review would and keeps the ediff open."
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
                  (should (eq (key-binding (kbd "x"))
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
                    ;; The control buffer and both sides are still there,
                    ;; the comment in them marked sent.
                    (should (buffer-live-p control))
                    (should (buffer-live-p base))
                    (should (buffer-live-p now))
                    (should (ecc-review-note-sent (car ecc-review--notes)))
                    (should-not (ecc-review-comments))
                    ;; Drawn dimmed in the side it is on.
                    (let* ((overlay (car (ecc-review-comment-overlays)))
                           (string (or (overlay-get overlay 'after-string)
                                       (overlay-get overlay 'before-string))))
                      (should (eq (get-text-property (string-search "#" string) 'face string)
                                  'ecc-review-sent-comment-face)))
                    ;; Nothing is left to send, and a new comment is
                    ;; all the next send carries.
                    (should-error (ecc-review-send) :type 'user-error)
                    (ediff-jump-to-difference 1)
                    (ecc-review-ediff-comment "and here")
                    (let ((text (ecc-review-send)))
                      (should (string-search "Comment: and here" text))
                      (should-not (string-search "use a word" text)))
                    ;; C-c C-k still closes it, and the screen is what it was.
                    (ecc-review-quit)
                    (should-not (buffer-live-p control))
                    (should (compare-window-configurations
                             (current-window-configuration) windows)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-sent-mark-survives-a-refill ()
  "A sent comment is still sent after the two sides are read again."
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
                  (ecc-review-send)
                  (ecc-review-ediff-test--write (concat directory "x.txt")
                                                "two\nthree\n")
                  (ecc-review-reread)
                  (should (string-search "three" (with-current-buffer ediff-buffer-B
                                                   (buffer-string))))
                  (should (= (length ecc-review--notes) 1))
                  (should (ecc-review-note-sent (car ecc-review--notes)))
                  (should-not (ecc-review-comments))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-send-editing-first ()
  "C-u C-c C-c shows the prompt; cancelling or sending leaves the ediff open."
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
                      ;; And sending from there goes back to it as well.
                      (with-current-buffer control (ecc-review-send t))
                      (with-current-buffer (get-buffer "*ecc-review-message: test*")
                        (goto-char (point-max))
                        (insert "\n\n全体: テストも足すこと")
                        (ecc-review-message-send))
                      (should (buffer-live-p control))
                      (should-not (get-buffer "*ecc-review-message: test*"))
                      (should (ecc-review-note-sent
                               (car (buffer-local-value 'ecc-review--notes control))))
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
  (should (ecc-git-ensure-baseline session))
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
                                   ("x" . ecc-review-ediff-remove-comment)
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
                    ;; Taken when ediff computed the differences of what
                    ;; was written: the reading is of what the review shows.
                    (should (ecc-review--reading-current-p))
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

(ert-deftest ecc-review-ediff-test-a-line-comment-follows-lines-put-in-above-it ()
  "Lines put in right above a commented line of a difference move the comment.
The line is unchanged, two lines further down in the same difference,
and the ediff review read again puts the comment there."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil)
              (three (string-replace "new\n" "new\nnewer\nnewest\n"
                                     ecc-review-ediff-test--changed)))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (ecc-review-ediff-test--write (concat directory "a.txt") three)
                (with-current-buffer control
                  (ecc-review-reread t)
                  (ecc-review-add-note 'claude "Why newest?"
                                       (ecc-review-ediff-test--line 'new 9))
                  (ecc-review--draw-notes)
                  (should (equal (ecc-review-note-line-text (car ecc-review--notes))
                                 "newest"))
                  (ecc-review-ediff-test--write
                   (concat directory "a.txt")
                   (string-replace "newer\n" "newer\nput\nin\n" three))
                  (ecc-review-reread t)
                  (let ((note (car ecc-review--notes)))
                    (should-not (ecc-review-note-outdated note))
                    (should (= (ecc-review-note-line note) 11)))
                  (should (string-search "#1 Claude: Why newest?"
                                         (ecc-review-ediff-test--drawn ediff-buffer-B)))))
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
                (should (ecc-git-ensure-baseline session))
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
                (setq two (ecc-review-ediff-range-buffer session ""))
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
                             (git (symbol-function 'ecc-git-run))
                             ((symbol-function 'ecc-git-run)
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
        (let ((diff (plist-get (ecc-review--range-content session range nil nil)
                               :nothing))
              (ediff (plist-get (ecc-review-ediff--content session range nil nil)
                                :nothing)))
          (should (equal diff ediff))))
      (should (string-prefix-p "Nothing is staged in "
                               (plist-get (ecc-review-ediff--content session 'staged nil nil)
                                          :nothing)))
      (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
    (let* ((root (ecc-git-root directory))
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
          (cl-letf* ((git (symbol-function 'ecc-git-run))
                     ((symbol-function 'ecc-git-run)
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
  (should (ecc-git-ensure-baseline session))
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
  (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
                (should (ecc-git-ensure-baseline session))
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
    (let* ((root (ecc-git-root directory))
           (left (ecc-review--head-tree root))
           (cache (make-hash-table :test #'equal))
           (alone 0)
           (asked nil))
      (ecc-review-ediff-test--write (concat directory "x.txt") (make-string 400 ?y))
      (ecc-review-ediff-test--write (concat directory "small.txt") "small\n")
      (ecc-review-ediff-test--git directory "add" ".")
      (ecc-review-ediff-test--git directory "commit" "-q" "-m" "big")
      (cl-letf* ((git (symbol-function 'ecc-git-run))
                 ((symbol-function 'ecc-git-run)
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
    (let* ((root (ecc-git-root directory))
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
        (cl-letf* ((git (symbol-function 'ecc-git-run))
                   ((symbol-function 'ecc-git-run)
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
                                        (cdr (ecc-git-run root "cat-file" "blob" before-blob))
                                      "")))
              (should (equal after (if after-blob
                                       (cdr (ecc-git-run root "cat-file" "blob" after-blob))
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
  "C-u x leaves out Claude's comments while they are hidden, in both reviews."
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

(ert-deftest ecc-review-ediff-test-c-keeps-its-difference-across-a-reading ()
  "c takes the difference before it asks anything: a reading during the question moves it.
Claude's comment is on the first difference; while c asks whether to
answer it, two lines are put in at the top and the review is read
again.  The new comment goes on the difference it was pressed on, where
it is now."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--rich session directory))
                (with-current-buffer control
                  (ecc-review-add-note 'claude "Why upper case?"
                                       (ecc-review-ediff-test--line 'new 2))
                  (ecc-review--draw-notes)
                  (ediff-jump-to-difference 1)
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt labels &rest _)
                               (ecc-review-ediff-test--write
                                (concat directory "a.txt")
                                (concat "zero\nzero2\n" ecc-review-ediff-test--changed))
                               (ecc-review-reread t)
                               (seq-find (lambda (label) (string-search "new comment" label))
                                         labels)))
                            ((symbol-function 'read-string) (lambda (&rest _) "Mine")))
                    (call-interactively #'ecc-review-ediff-comment))
                  (let ((claude (ecc-review-find-note 1))
                        (mine (ecc-review-find-note 2)))
                    (should (equal (ecc-review-note-text mine) "Mine"))
                    (should-not (ecc-review-note-reply-to mine))
                    (should-not (ecc-review-note-outdated claude))
                    (should-not (ecc-review-note-outdated mine))
                    (should (equal (ecc-review-note-hunk-key mine)
                                   (ecc-review-note-hunk-key claude)))
                    (should (equal (cdr (ecc-review-note-hunk-key mine)) "@@ -2,1 +4,1 @@")))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-reading-that-failed-is-read-again ()
  "An ediff review whose reading failed halfway is read whole by the next g.
Its comments are carried from the reading they were last on."
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
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-test--write
                   (concat directory "a.txt")
                   (concat "zero\nzero2\n" ecc-review-ediff-test--changed))
                  (cl-letf (((symbol-function 'ecc-review-ediff--write)
                             (lambda (&rest _) (error "The disk is full"))))
                    (should-error (ecc-review-reread t)))
                  ;; A difference is selected again, as n would; what
                  ;; draws on it may say the review has to be read again.
                  (ignore-errors (ediff-jump-to-difference 1))
                  (should (ediff-valid-difference-p ediff-current-difference))
                  ;; g reads it again, whole.
                  (ecc-review-refresh)
                  (should (ecc-review--reading-current-p))
                  (let ((note (ecc-review-find-note 1)))
                    (should-not (ecc-review-note-outdated note))
                    (should (= (ecc-review-note-line note) 9)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-reading-failing-at-any-step-recovers ()
  "Whatever step of an ediff reading fails or is quit, nothing typed is lost and g recovers."
  (skip-unless (executable-find "git"))
  (dolist (step '(ecc-review-ediff--write ecc-review-ediff--compute-differences
                  ecc-review--take-reading ecc-review--diff-moved-blobs ecc-review--cat-file
                  ecc-review--carry-file ecc-review--draw-notes ecc-review-ediff--restore-views))
    (dolist (kind '(error quit))
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
                      (ecc-review-ediff-test--write
                       (concat directory "a.txt")
                       (concat "zero\nzero2\n" ecc-review-ediff-test--changed))
                      (ecc-review-test--failing-once step kind
                        (condition-case nil (ecc-review-reread t) ((error quit) nil)))
                      ;; Drawn before any g, as a comment of Claude's draws:
                      ;; on its own line of the text shown, or not at all.
                      (condition-case nil (ecc-review--draw-notes) (error nil))
                      (let ((note (ecc-review-find-note 1)))
                        (should (or (ecc-review-note-outdated note)
                                    (not (ecc-review--reading-current-p))
                                    (= (ecc-review-note-line note)
                                       (if (string-search "zero2" (with-current-buffer ediff-buffer-B
                                                                     (buffer-string)))
                                           9 7)))))
                      (ignore-errors (ediff-jump-to-difference 1))
                      (ecc-review-test--typing-loses-nothing #'ecc-review-ediff-comment)
                      (ecc-review-refresh)
                      (should (ecc-review--reading-current-p))
                      (let ((note (ecc-review-find-note 1)))
                        (should-not (ecc-review-note-outdated note))
                        (should (= (ecc-review-note-line note) 9)))))
                (ecc-review-ediff-test--quit control)))))))))

(ert-deftest ecc-review-ediff-test-c-edits-a-comment-whatever-the-reading ()
  "c in an ediff review that edits a comment of yours edits it on a stale reading too."
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
                  (ecc-review-ediff-comment "first")
                  (let ((kill-ring nil))
                    (cl-letf (((symbol-function 'completing-read)
                               (lambda (_prompt labels &rest _)
                                 (or (seq-find (lambda (label) (string-search "#1" label)) labels)
                                     (car labels))))
                              ((symbol-function 'read-string)
                               (lambda (&rest _) (ecc-review--begin-reading) "second")))
                      (call-interactively #'ecc-review-ediff-comment))
                    (should-not kill-ring)
                    (should (equal (mapcar #'ecc-review-note-text ecc-review--notes)
                                   '("second"))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-c-keeps-what-was-typed-when-it-fails ()
  "c in an ediff review that cannot put its comment anywhere keeps what was typed."
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
                  (let ((kill-ring nil))
                    (cl-letf (((symbol-function 'read-string)
                               (lambda (&rest _) (ecc-review--begin-reading) "about LINE2")))
                      (should-error (call-interactively #'ecc-review-ediff-comment)
                                    :type 'user-error))
                    (should (equal (car kill-ring) "about LINE2")))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-c-that-fails-after-the-comment-is-in-keeps-nothing ()
  "c in an ediff review that fails once its comment is in leaves the kill ring alone."
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
                  (let ((kill-ring nil))
                    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "about LINE2"))
                              ((symbol-function 'ecc-review--draw-notes)
                               (lambda (&rest _) (error "No room to draw"))))
                      (let ((message (error-message-string
                                      (should-error
                                       (call-interactively #'ecc-review-ediff-comment)))))
                        (should (string-search "No room to draw" message))
                        (should-not (string-search "kill ring" message))))
                    (should-not kill-ring)
                    (should (equal (mapcar #'ecc-review-note-text ecc-review--notes)
                                   '("about LINE2"))))))
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
                (should (ecc-git-ensure-baseline session))
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

(ert-deftest ecc-review-ediff-test-the-style-is-a-method ()
  "`ecc-review' and `ecc-review-range' open the style through generics.
`ecc-review--open' and `ecc-review--open-range' are generics of
`ecc-review' on `ecc-review-style' whose default is the diff review;
`ecc-review-ediff' has the methods of `ediff'.  Outside git the review
of a session is a diff whatever the style."
  (ecc-test-with-fake-session session
    (let ((calls nil)
          (repository "/repo/"))
      (cl-letf (((symbol-function 'ecc-review-buffer)
                 (lambda (_session paths) (push (list 'diff paths) calls) 'buffer))
                ((symbol-function 'ecc-review-range-buffer)
                 (lambda (_session range root paths)
                   (push (list 'diff range root paths) calls)
                   'buffer))
                ((symbol-function 'ecc-review--display)
                 (lambda (buffer _session) (push (list 'display buffer) calls) 'window))
                ((symbol-function 'ecc-review-ediff-buffer)
                 (lambda (_session paths) (push (list 'ediff paths) calls) 'control))
                ((symbol-function 'ecc-review-ediff-range-buffer)
                 (lambda (_session range root paths)
                   (push (list 'ediff range root paths) calls)
                   'control))
                ((symbol-function 'ecc-git-root) (lambda (_path) repository)))
        (should (eq (ecc-review--open 'diff session '("a")) 'window))
        (should (eq (ecc-review--open 'ediff session '("a")) 'control))
        (should (eq (ecc-review--open-range 'diff session "HEAD" "/r/" '("a")) 'window))
        (should (eq (ecc-review--open-range 'ediff session "HEAD" "/r/" '("a")) 'control))
        (should (equal (nreverse calls)
                       '((diff ("a")) (display buffer)
                         (ediff ("a"))
                         (diff "HEAD" "/r/" ("a")) (display buffer)
                         (ediff "HEAD" "/r/" ("a")))))
        ;; The commands dispatch on the setting.
        (let ((ecc-review-style 'ediff))
          (should (eq (ecc-review session) 'control))
          (should (eq (ecc-review-range session "HEAD" "/r/") 'control)))
        (let ((ecc-review-style 'diff))
          (should (eq (ecc-review session) 'window))
          (should (eq (ecc-review-range session "HEAD" "/r/") 'window)))
        ;; No repository: no two trees to lay side by side.
        (setq calls nil repository nil)
        (should (eq (ecc-review--open 'ediff session nil) 'window))
        (should (equal (nreverse calls) '((diff nil) (display buffer))))))))

;;;; The two windows: their keys, and point driving the review

;; The keys of an ediff review in its two windows, point driving the
;; review, and RET opening the file.  Keys are typed with
;; `execute-kbd-macro', which runs the command loop and so the hooks a
;; key runs; a move of point is a `goto-char' and the hook the command
;; loop would run after it.
;;
;; ediff is given faces, as a graphical Emacs has them: without face
;; support it marks the current difference by writing flags into the
;; text, which moves the point of the window that has the keyboard.

;;;;; Helpers

(defun ecc-review-direct-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-git-run directory args)))
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
  (should (ecc-git-ensure-baseline session))
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

;;;;; The keys

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
          (should (string-search "n/p diff  c comment  j jump  { } comments" left))
          (should (string-search "C-c C-c send  q quit  RET open  T tour"
                                 (ecc-review-direct--keys 'B)))
          ;; A window of 40 columns keeps the first keys and the help.
          (should (string-search "C-c C-c send  q quit" right))
          (should (string-search "? all keys" right))
          ;; Keys and nothing else: where the review is is on the mode
          ;; line of the right one, after the file at point.
          (should-not (string-search "/4" right))
          (should (equal (substring-no-properties
                          (ecc-review-direct-mode-line-text ediff-buffer-B))
                         "a.txt  -/4"))
          (should (equal (substring-no-properties
                          (ecc-review-direct-mode-line-text ediff-buffer-A))
                         "a.txt"))
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

;;;;; Comments on a line

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

;;;;; Point drives the review

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

;;;;; Opening the file

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
            (setq control (ecc-review-ediff-range-buffer session "HEAD^!" directory))
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

;;;;; Review round 1

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

(ert-deftest ecc-review-direct-test-the-mode-line-says-the-difference-after-any-change ()
  "Where the review is follows a reading again and a quiet change of difference.
It is on the mode line of the right window, after the file at point."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-review session control
      (let ((status (lambda ()
                      (ecc-review-direct-mode-line-text
                       (buffer-local-value 'ediff-buffer-B control)))))
        (ecc-review-direct-test--move control 'B 55)
        (should (string-suffix-p "  4/4" (funcall status)))
        ;; Off the difference, n goes from point: the mode line is told
        ;; of the one n starts from, and then of where n went.
        (ecc-review-direct-test--move control 'B 10)
        (ecc-review-direct-test--type control 'B "n")
        (should (string-suffix-p "  2/4" (funcall status)))
        ;; A fifth difference, read again: the count follows.
        (ecc-review-direct-test--write
         (concat directory "a.txt")
         (replace-regexp-in-string "^l58$" "l58 changed" ecc-review-direct-test--changed))
        (with-current-buffer control
          (ecc-review-reread t))
        (should (string-match-p "/5\\'" (funcall status)))))))

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

;;;;; Review round 2

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

;;;;; Two sessions

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

;;;;; The layouts

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
  "Side by side the left header is at the right edge; stacked, both are the same.
One above the other, both windows show every key, fitted to the width.
| from a window changes it, and keeps the keyboard there."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((ecc-review-direct-test--layout 'stacked))
      (ecc-review-direct-test--with-review session control
        (let ((header (lambda (side)
                        (ecc-review-direct-header-text
                         (buffer-local-value (if (eq side 'A) 'ediff-buffer-A 'ediff-buffer-B)
                                             control)))))
          (should (string-prefix-p " n/p diff  c comment  C-c C-c send" (funcall header 'A)))
          (should (string-suffix-p "? all keys" (funcall header 'A)))
          (should (equal-including-properties (funcall header 'A) (funcall header 'B)))
          (should-not (ecc-review-direct-test--align-to (funcall header 'A)))
          (ecc-review-direct-test--type control 'B "|")
          (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
          (should (< (car (window-edges (ecc-review-direct-test--window control 'A)))
                     (car (window-edges (ecc-review-direct-test--window control 'B)))))
          (let ((left (funcall header 'A)))
            (should (equal (ecc-review-direct-test--align-to left)
                           `(- right ,(1+ (string-width (ecc-review-direct--keys 'A))))))
            (should (string-suffix-p "/ filter " left)))
          ;; The right one is not moved, and has the other half.
          (should (string-prefix-p " C-c C-c send" (funcall header 'B)))
          (should-not (string-search "n/p diff" (funcall header 'B)))
          (ecc-review-direct-test--type control 'B "|")
          (should-not (ecc-review-direct-test--align-to (funcall header 'A)))
          (should (equal-including-properties (funcall header 'A) (funcall header 'B))))))))

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

;;;;; Fixes after review

(ert-deftest ecc-review-direct-test-a-narrow-window-keeps-the-help ()
  "Too narrow for every key, the right header keeps ?, dropping keys before it.
Too narrow even for ?, it is ? alone.  Keys and nothing else, at any width."
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
            (should (string-prefix-p " C-c C-c send" text))
            (should (string-suffix-p "! reread  ? all keys" text))))
        (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 40)))
          (should (equal (ecc-review-direct-header-text buffer window)
                         " C-c C-c send  q quit  ? all keys")))
        (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 8)))
          (should (equal (ecc-review-direct-header-text buffer window) " ? all keys")))))))

(ert-deftest ecc-review-direct-test-a-stacked-160-column-frame-keeps-the-help ()
  "Stacked in a frame of 160 columns, beside the reply pane, both headers keep ?.
They are the same line of every key, as many as fit, the most used
first.  Batch has a frame of 80 columns: the width the windows have
there is given to the header lines."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (let ((ecc-review-direct-test--layout 'stacked))
      (ecc-review-direct-test--with-review session control
        (let* ((left (buffer-local-value 'ediff-buffer-A control))
               (right (buffer-local-value 'ediff-buffer-B control))
               ;; The frame less the pane and the scroll bar of the window.
               (width (- 160 (default-value 'ecc-review-talk-reply-width) 1)))
          (cl-letf (((symbol-function 'window-width) (lambda (&rest _) width)))
            (let ((text (ecc-review-direct-header-text
                         right (ecc-review-direct-test--window control 'B))))
              (should (equal-including-properties
                       (ecc-review-direct-header-text
                        left (ecc-review-direct-test--window control 'A))
                       text))
              (should (string-prefix-p " n/p diff  c comment  C-c C-c send  q quit" text))
              (should (string-suffix-p "? all keys" text))
              (should-not (string-search "/4" text))
              (should (<= (string-width text) width)))))))))

(ert-deftest ecc-review-direct-test-the-right-header-is-fitted-once-a-width ()
  "Drawing the right header line again at the same width fits the keys no more.
Another width or other keys fit them again, another difference does not,
and at any width what is drawn is no wider than the window."
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
            ;; The difference changes: the header line does not.
            (ecc-review-direct-test--move control 'B 55)
            (ecc-review-direct-header-text buffer window)
            (should (= fitted 2))
            ;; The keys change.
            (with-current-buffer buffer
              (setq ecc-review-direct--header-keys
                    (ecc-review-direct--key-pieces)))
            (ecc-review-direct-header-text buffer window)
            (should (= fitted 3))))
        (dolist (columns (number-sequence 25 120 5))
          (cl-letf (((symbol-function 'window-width) (lambda (&rest _) columns)))
            (let ((text (ecc-review-direct-header-text buffer window)))
              (should (string-search "? all keys" text))
              (should (<= (string-width text) columns)))))))))

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
C-c C-c there sends and goes back the same way, the review left open."
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
      (should (buffer-live-p control))
      (should-not (get-buffer-window control))
      (should (eq (selected-window) (ecc-review-direct-test--window control 'B)))
      (with-current-buffer control
        (should (ecc-review-note-sent (car ecc-review--notes)))))))

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
  "Each change of what the right window's lines read asks for them to be drawn again.
The keys and the construct of the header line, and the status of the
mode line; nothing changed asks for nothing."
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
            (setq ecc-review-direct--mode-line-status nil))
          (ecc-review-direct-refresh-headers control)
          (should (= asked 3)))))))

;;;;; The file at point, on the mode line

(defun ecc-review-direct-test--paths (control)
  "Return the paths the mode lines of the review CONTROL say, left and right."
  (mapcar (lambda (buffer)
            (car (buffer-local-value 'ecc-review-direct--mode-line buffer)))
          (with-current-buffer control (list ediff-buffer-A ediff-buffer-B))))

(defun ecc-review-direct-test--move-to (control side path line)
  "Put point on LINE of PATH on SIDE of CONTROL, as `next-line' would."
  (select-window (ecc-review-direct-test--window control side))
  (goto-char (with-current-buffer control
               (ecc-review-ediff--file-position side (cons path line))))
  (let ((this-command 'next-line))
    (run-hooks 'post-command-hook)))

(ert-deftest ecc-review-direct-test-the-mode-line-says-the-file-at-point ()
  "Each mode line says the file its window's point is in, the right one then the status.
A move in one window moves the other, and both say the file they are in
afterwards; n and p into another file, too, and a move of Claude's."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-files session control
        (list (list "b.txt" (ecc-review-direct-test--lines)
                    (ecc-review-direct-test--lines (lambda (n) (and (= n 5) "l5 b\n")))))
      (dolist (buffer (with-current-buffer control (list ediff-buffer-A ediff-buffer-B)))
        (should (equal (buffer-local-value 'mode-line-buffer-identification buffer)
                       '(:eval (ecc-review-direct--mode-line-id)))))
      (ecc-review-direct-test--move-to control 'B "a.txt" 30)
      (should (equal (ecc-review-direct-test--paths control) '("a.txt" "a.txt")))
      (ecc-review-direct-test--move-to control 'B "b.txt" 3)
      (should (equal (ecc-review-direct-test--paths control) '("b.txt" "b.txt")))
      (should (string-match-p "\\`b\\.txt  [-0-9]+/5\\'"
                              (substring-no-properties
                               (ecc-review-direct-mode-line-text
                                (buffer-local-value 'ediff-buffer-B control)))))
      (should (equal (substring-no-properties
                      (ecc-review-direct-mode-line-text
                       (buffer-local-value 'ediff-buffer-A control)))
                     "b.txt"))
      ;; From the left window.
      (ecc-review-direct-test--move-to control 'A "a.txt" 10)
      (should (equal (ecc-review-direct-test--paths control) '("a.txt" "a.txt")))
      ;; n from the last line of a.txt goes into b.txt, and p back.
      (ecc-review-direct-test--move-to control 'B "a.txt" 58)
      (ecc-review-direct-test--type control 'B "n")
      (should (equal (ecc-review-direct-test--paths control) '("b.txt" "b.txt")))
      (ecc-review-direct-test--type control 'B "p")
      (should (equal (ecc-review-direct-test--paths control) '("a.txt" "a.txt")))
      ;; Moved with no command, as Claude's review_navigate moves it.
      (with-current-buffer control
        (ecc-review-move-to
         (car (ecc-review-ediff--unit-lines
               (seq-find (lambda (unit) (equal (plist-get unit :path) "b.txt"))
                         (ecc-review-units))))
         nil))
      (should (equal (ecc-review-direct-test--paths control) '("b.txt" "b.txt"))))))

(ert-deftest ecc-review-direct-test-the-blank-line-before-a-file-is-the-file-above ()
  "The blank line in front of a separator says the file above; the separator its own.
The end of the buffer says the last file.  With no path, the mode line
says the buffer's name, and a `%' in a path is no %-construct."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-direct-test--with-files session control
        (list (list "b.txt" (ecc-review-direct-test--lines)
                    (ecc-review-direct-test--lines (lambda (n) (and (= n 5) "l5 b\n")))))
      (dolist (buffer (with-current-buffer control (list ediff-buffer-A ediff-buffer-B)))
        (with-current-buffer buffer
          (goto-char (point-min))
          (should (equal (ecc-review-direct-path-at (point)) "a.txt"))
          (re-search-forward "^═══ b\\.txt")
          (let ((separator (line-beginning-position)))
            (should (equal (ecc-review-direct-path-at separator) "b.txt"))
            (should (equal (ecc-review-direct-path-at (1- separator)) "a.txt")))
          (should (equal (ecc-review-direct-path-at (point-max)) "b.txt"))))))
  (with-temp-buffer
    (rename-buffer "no review here" t)
    (should (equal (ecc-review-direct--mode-line-text nil nil) (buffer-name)))
    (should (equal (substring-no-properties (ecc-review-direct--mode-line-text "50%.txt" "1/2"))
                   "50%%.txt  1/2"))))

(provide 'ecc-review-ediff-test)

;;; ecc-review-ediff-test.el ends here
