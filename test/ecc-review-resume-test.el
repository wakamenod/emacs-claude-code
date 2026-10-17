;;; ecc-review-resume-test.el --- Tests for ecc-review-resume  -*- lexical-binding: t; -*-

;;; Commentary:

;; Saving a review as it closes and opening it again: the file and what
;; it holds, the two styles landing on the saved line, the comments put
;; back and carried, the baseline, and the cases that refuse.  Every
;; case builds a throwaway repository as `ecc-review-test' does, and
;; saves to a file of its own.  An Emacs restart is a review saved,
;; closed, and every buffer of it gone before it is resumed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-resume)
(require 'ecc-review-files)
(require 'ecc-session)

;;;; Helpers

(defvar ecc-review-resume-test--said nil
  "What the echo area was told last, in the case running.")

(defmacro ecc-review-resume-test--with-world (&rest body)
  "Run BODY with saving on, to a file of its own, and nothing left after.
Whatever BODY schedules is cancelled, `kill-emacs-hook' is put back, and
every review buffer is killed.  What is said in the echo area is kept in
`ecc-review-resume-test--said'."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ecc-review-resume" t)))
          (ecc-review-resume-file (expand-file-name "ecc-reviews.eld" dir))
          (ecc-review-resume-enabled t)
          (ecc-review-resume--pending nil)
          (ecc-review-resume--timer nil)
          (ecc-review-resume-test--said nil))
     (ecc-test-with-global-hooks '(kill-emacs-hook)
       (unwind-protect
           (cl-letf (((symbol-function 'message)
                      (lambda (format &rest args)
                        (when format
                          (setq ecc-review-resume-test--said
                                (apply #'format-message format args))))))
             ,@body)
         (when (timerp ecc-review-resume--timer)
           (cancel-timer ecc-review-resume--timer))
         (let ((ecc-review-resume-enabled nil))
           (ecc-review-resume-test--kill-reviews))
         (delete-directory dir t)))))

(defun ecc-review-resume-test--kill-reviews ()
  "Kill every buffer a review left behind, quitting an ediff one through ediff."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer (derived-mode-p 'ediff-mode))
               (buffer-local-value 'ecc-review--session buffer))
      (ecc-review-ediff-quit buffer)))
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defun ecc-review-resume-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-resume-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defmacro ecc-review-resume-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-review-resume-repo" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-resume-test--repo (session directory)
  "Make DIRECTORY a repository SESSION started in, and change two files.
x.txt and y.txt are committed, the baseline is taken, and then the
session changes both: y.txt is changed first in the review."
  (ecc-review-resume-test--git directory "init" "-q")
  (ecc-review-resume-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-resume-test--git directory "config" "user.name" "t")
  (ecc-review-resume-test--write (concat directory "x.txt") "one\ntwo\nthree\n")
  (ecc-review-resume-test--write (concat directory "y.txt") "a\nb\nc\n")
  (ecc-review-resume-test--git directory "add" "x.txt" "y.txt")
  (ecc-review-resume-test--git directory "commit" "-q" "-m" "init")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (ecc-review-resume-test--write (concat directory "x.txt") "one\n2\nthree\n")
  (ecc-review-resume-test--write (concat directory "y.txt") "a\nB\nc\n"))

(defun ecc-review-resume-test--goto (line)
  "Move to the start of the first line that is LINE exactly."
  (goto-char (point-min))
  (re-search-forward (concat "^" (regexp-quote line) "$"))
  (beginning-of-line))

(defun ecc-review-resume-test--line ()
  "Return the text of the line at point."
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun ecc-review-resume-test--entries ()
  "Return the reviews the file holds, as saved."
  (plist-get (ecc-review-resume--read) :reviews))

(defun ecc-review-resume-test--entry (session)
  "Return the review saved for SESSION."
  (seq-find (lambda (entry) (equal (plist-get entry :session) (ecc-session-id session)))
            (ecc-review-resume-test--entries)))

(defun ecc-review-resume-test--texts (review)
  "Return the texts of the comments of REVIEW, in the order made."
  (mapcar #'ecc-review-note-text (buffer-local-value 'ecc-review--notes review)))

(defun ecc-review-resume-test--diff-review (session)
  "Open the diff review of what SESSION changed, comment on x.txt and close it.
The comment is on the line +2, point is left on +B and the review is
closed with \\[ecc-review-close]."
  (let ((ecc-review-style 'diff))
    (with-current-buffer (ecc-review-buffer session)
      (ecc-review-resume-test--goto "+2")
      (ecc-review-comment "why 2")
      (ecc-review-resume-test--goto "+B")
      (ecc-review-close))))

;;;; The file

(ert-deftest ecc-review-resume-test-a-review-is-saved-as-it-closes ()
  "Closing a review saves its session, what it compared and its comments."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (should-not (get-buffer (ecc-review-buffer-name session)))
        (let ((entry (ecc-review-resume-test--entry session)))
          (should entry)
          (should (equal (plist-get entry :name) "test"))
          (should (equal (plist-get entry :root) directory))
          (should (eq (plist-get entry :style) 'diff))
          (should-not (plist-get entry :range))
          (should (equal (plist-get entry :baseline) (ecc-session-baseline session)))
          (should (numberp (plist-get entry :time)))
          (let ((note (car (plist-get entry :notes))))
            (should (= 1 (length (plist-get entry :notes))))
            (should (equal (plist-get note :text) "why 2"))
            (should (equal (plist-get note :path) "x.txt"))
            (should (eq (plist-get note :side) 'new))
            (should (eql (plist-get note :line) 2))
            (should (integerp (plist-get note :shape))))
          (should (equal (plist-get (plist-get entry :place) :path) "y.txt"))
          (should (equal (ecc-review-resume--where entry) "y.txt:2"))
          (should (string-search "test · since the session started · y.txt:2 · 1 unsent comment"
                                 (ecc-review-resume-describe entry))))
        ;; The file is Lisp data of a version, read back as it was written.
        (let ((state (with-temp-buffer
                       (insert-file-contents ecc-review-resume-file)
                       (read (current-buffer)))))
          (should (eql (plist-get state :version) ecc-review-resume--version))
          (should (equal (plist-get state :reviews) (ecc-review-resume-test--entries))))))))

(ert-deftest ecc-review-resume-test-a-shape-reads-back-as-it-was ()
  "A shape saved as data is the same shape once read back."
  (let* ((lines (list (list :path "a" :side nil :line nil :text "@@ -2 +2 @@"
                            :hunk (list :header "@@ -2 +2 @@"))
                      (list :path "a" :side 'old :line 2 :text "two"
                            :hunk (list :header "@@ -2 +2 @@"))
                      (list :path "a" :side 'new :line 2 :text "2"
                            :hunk (list :header "@@ -2 +2 @@"))))
         (shape (ecc-review-map-shape lines '(blob "/r/" "abc")))
         (back (ecc-review-map-shape-from-data
                (car (read-from-string
                      (prin1-to-string (ecc-review-map-shape-data shape)))))))
    (dolist (slot '(base removed added added-at hunks order texts gone))
      (should (equal (cl-struct-slot-value 'ecc-review-map-shape slot back)
                     (cl-struct-slot-value 'ecc-review-map-shape slot shape))))
    (should (ecc-review-map-changed-p back 'new 2 0))))

(ert-deftest ecc-review-resume-test-nothing-is-saved-when-off ()
  "With saving off, as in a batch Emacs, closing a review writes nothing."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (let ((ecc-review-resume-enabled nil))
          (ecc-review-resume-test--diff-review session))
        (should-not (file-exists-p ecc-review-resume-file))))))

(ert-deftest ecc-review-resume-test-sent-comments-are-not-saved ()
  "A comment a prompt carried is not saved; Claude's are, and not as yours."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (with-current-buffer (ecc-review-buffer session)
          (ecc-review-resume-test--goto "+2")
          (ecc-review-comment "sent already")
          (setf (ecc-review-note-sent (car ecc-review--notes)) t)
          (ecc-review-resume-test--goto "+B")
          (ecc-review-add-note 'claude "B is odd" (ecc-review--line-at-point))
          (ecc-review-comment "not yet")
          (ecc-review-close))
        (let ((entry (ecc-review-resume-test--entry session)))
          (should (equal (mapcar (lambda (note) (plist-get note :text))
                                 (plist-get entry :notes))
                         '("B is odd" "not yet")))
          (should (= 1 (ecc-review-resume--unsent entry)))
          (should (string-search "1 unsent comment, 1 of Claude's"
                                 (ecc-review-resume-describe entry))))))))

(ert-deftest ecc-review-resume-test-old-and-orphaned-reviews-are-dropped ()
  "A review older than its baseline lives, or of a project gone, is not kept."
  (ecc-review-resume-test--with-world
    (let* ((now (float-time))
           (here temporary-file-directory)
           (entries (list (list :session "new" :root here :time now)
                          (list :session "old" :root here
                                :time (- now ecc-review-resume-max-age 60))
                          (list :session "gone" :root "/nonexistent/ecc/" :time now))))
      (should (equal (mapcar (lambda (entry) (plist-get entry :session))
                             (ecc-review-resume--prune entries))
                     '("new"))))))

(ert-deftest ecc-review-resume-test-a-file-it-cannot-read-is-left-alone ()
  "A file of another layout is an error, and closing a review still closes it."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (with-temp-file ecc-review-resume-file
          (prin1 '(:version 99 :reviews nil) (current-buffer)))
        (ecc-review-resume-test--diff-review session)
        ;; Closed all the same, said so, and the file is as it was.
        (should-not (get-buffer (ecc-review-buffer-name session)))
        (should (string-search "not saved" ecc-review-resume-test--said))
        (should (equal (with-temp-buffer
                         (insert-file-contents ecc-review-resume-file)
                         (read (current-buffer)))
                       '(:version 99 :reviews nil)))
        (should-error (ecc-review-resume-entries))))))

;;;; Resuming

(ert-deftest ecc-review-resume-test-a-diff-review-comes-back-where-it-was ()
  "Resuming opens the diff again, with the comment on its line and point on the place."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (let* ((entry (ecc-review-resume-test--entry session))
               (review (ecc-review-resume entry)))
          (should (buffer-live-p review))
          (should (string-search "Resumed the review of test at y.txt:2: 1 comment not sent yet"
                                 ecc-review-resume-test--said))
          (with-current-buffer review
            (should (derived-mode-p 'ecc-review-mode))
            (should (equal (ecc-review-resume-test--line) "+B"))
            (let ((note (car ecc-review--notes)))
              (should (equal (ecc-review-note-text note) "why 2"))
              (should-not (ecc-review-note-outdated note))
              (should (equal (buffer-substring-no-properties
                              (ecc-review-note-position note)
                              (save-excursion (goto-char (ecc-review-note-position note))
                                              (line-end-position)))
                             "+2")))
            ;; The next comment gets an id of its own.
            (should (> ecc-review--next-id (ecc-review-note-id (car ecc-review--notes)))))
          (when-let* ((window (get-buffer-window review)))
            (should (equal (with-current-buffer review
                             (save-excursion (goto-char (window-point window))
                                             (ecc-review-resume-test--line)))
                           "+B"))))))))

(ert-deftest ecc-review-resume-test-a-comment-whose-line-went-is-outdated ()
  "A line changed while the review was closed leaves its comment outdated."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        ;; The line commented on is a different line now; another one
        ;; is put above the place being read.
        (ecc-review-resume-test--write (concat directory "x.txt") "one\n22\nthree\n")
        (ecc-review-resume-test--write (concat directory "y.txt") "a\nA\nB\nc\n")
        (let ((review (ecc-review-resume (ecc-review-resume-test--entry session))))
          (should (string-search "1 outdated" ecc-review-resume-test--said))
          (with-current-buffer review
            (let ((note (car ecc-review--notes)))
              (should (equal (ecc-review-note-text note) "why 2"))
              (should (ecc-review-note-outdated note)))
            (should (string-search "[outdated, was L2 (new)]"
                                   (mapconcat (lambda (overlay)
                                                (or (overlay-get overlay 'before-string)
                                                    (overlay-get overlay 'after-string) ""))
                                              ecc-review--comments "")))
            ;; The place moved down with its line.
            (should (equal (ecc-review-resume-test--line) "+B"))))))))

(ert-deftest ecc-review-resume-test-an-ediff-review-comes-back-in-ediff ()
  "An ediff review is resumed in ediff, on the saved line, with its comment."
  (skip-unless (executable-find "git"))
  (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
        (ecc-review-ediff-layout 'side-by-side)
        (ecc-review-talk-reply-height nil)
        (ecc-review-style 'ediff))
    (ecc-review-resume-test--with-world
      (ecc-test-with-fake-session session
        (ecc-review-resume-test--with-directory directory
          (ecc-review-resume-test--repo session directory)
          (let ((control (ecc-review session)))
            (with-current-buffer control
              (let ((two (seq-find (lambda (line)
                                     (and (equal (plist-get line :path) "x.txt")
                                          (eq (plist-get line :side) 'new)))
                                   (ecc-review-lines)))
                    (b (seq-find (lambda (line)
                                   (and (equal (plist-get line :path) "y.txt")
                                        (eq (plist-get line :side) 'new)))
                                 (ecc-review-lines))))
                (ecc-review-add-note 'user "why 2" two)
                (ecc-review--draw-notes)
                (ecc-review-move-to b nil))
              (ecc-review-close)))
          (let ((entry (ecc-review-resume-test--entry session)))
            (should (eq (plist-get entry :style) 'ediff))
            (should (equal (ecc-review-resume--where entry) "y.txt:2"))
            (let ((control (ecc-review-resume entry)))
              (with-current-buffer control
                (should (derived-mode-p 'ediff-mode))
                (should (equal (ecc-review-resume-test--texts control) '("why 2")))
                (should-not (ecc-review-note-outdated (car ecc-review--notes)))
                (let ((place (ecc-review-place-at-point)))
                  (should (equal (plist-get place :path) "y.txt"))
                  (should (eql (plist-get place :line) 2))
                  (should (eq (plist-get place :side) 'new)))))))))))

(ert-deftest ecc-review-resume-test-a-range-review-comes-back-as-a-range ()
  "A review of a range opens that range again, not what the session changed."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (with-current-buffer (ecc-review-range-buffer session "HEAD" directory
                                                      (list (concat directory "y.txt")))
          (ecc-review-resume-test--goto "+B")
          (ecc-review-comment "on B")
          (ecc-review-close))
        (let ((entry (ecc-review-resume-test--entry session)))
          (should (equal (plist-get entry :range) "HEAD"))
          (should-not (plist-get entry :baseline))
          (should (equal (plist-get entry :paths) '("y.txt")))
          (should (string-search "HEAD (y.txt)" (ecc-review-resume-describe entry)))
          (with-current-buffer (ecc-review-resume entry)
            (should (equal ecc-review--range "HEAD"))
            (should (equal ecc-review--paths '("y.txt")))
            (should-not (string-search "x.txt" (buffer-string)))
            (should (equal (ecc-review-resume-test--texts (current-buffer)) '("on B")))))))))

(ert-deftest ecc-review-resume-test-an-open-review-is-gone-to ()
  "Resuming a review that is open already goes to it and opens no other."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (let* ((entry (ecc-review-resume-test--entry session))
               (first (ecc-review-resume entry)))
          (should (eq (ecc-review-resume entry) first))
          (should (string-search "open already" ecc-review-resume-test--said))
          (should (equal (ecc-review-resume-test--texts first) '("why 2"))))))))

(ert-deftest ecc-review-resume-test-a-fresh-review-keeps-the-saved-comments ()
  "A review opened the ordinary way does not replace one with comments, until it has its own."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        ;; Opened again by hand, nothing written in it, closed.
        (with-current-buffer (ecc-review-buffer session)
          (should-not ecc-review--notes)
          (ecc-review-close))
        (should (equal (mapcar (lambda (note) (plist-get note :text))
                               (plist-get (ecc-review-resume-test--entry session) :notes))
                       '("why 2")))
        ;; A comment of its own, and it is the review kept.
        (with-current-buffer (ecc-review-buffer session)
          (ecc-review-resume-test--goto "+B")
          (ecc-review-comment "a new one")
          (ecc-review-close))
        (should (equal (mapcar (lambda (note) (plist-get note :text))
                               (plist-get (ecc-review-resume-test--entry session) :notes))
                       '("a new one")))
        ;; The one resumed carries on: sending its comments saves it
        ;; with none.
        (with-current-buffer (ecc-review-resume (ecc-review-resume-test--entry session))
          (dolist (note ecc-review--notes)
            (setf (ecc-review-note-sent note) t))
          (ecc-review-close))
        (should-not (plist-get (ecc-review-resume-test--entry session) :notes))))))

(ert-deftest ecc-review-resume-test-comments-are-saved-once-idle ()
  "A comment made schedules a save, and Emacs exiting saves what is open."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (let ((review (ecc-review-buffer session)))
          (with-current-buffer review
            (ecc-review-resume-test--goto "+2")
            (ecc-review-comment "typed"))
          (should (memq review ecc-review-resume--pending))
          (should (timerp ecc-review-resume--timer))
          (should (memq #'ecc-review-resume--save-at-exit kill-emacs-hook))
          (ecc-review-resume--save-pending)
          (should-not ecc-review-resume--pending)
          (should (equal (mapcar (lambda (note) (plist-get note :text))
                                 (plist-get (ecc-review-resume-test--entry session) :notes))
                         '("typed")))
          (with-current-buffer review
            (ecc-review-resume-test--goto "+B")
            (ecc-review-comment "at exit"))
          (ecc-review-resume--save-at-exit)
          (should (equal (mapcar (lambda (note) (plist-get note :text))
                                 (plist-get (ecc-review-resume-test--entry session) :notes))
                         '("typed" "at exit"))))))))

;;;; Scopes

(ert-deftest ecc-review-resume-test-two-scopes-of-one-session-are-both-kept ()
  "Two reviews of one session comparing different things keep their comments each."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (with-current-buffer (ecc-review-range-buffer session "HEAD" directory
                                                      (list (concat directory "y.txt")))
          (ecc-review-resume-test--goto "+B")
          (ecc-review-comment "on B, against HEAD")
          (ecc-review-close))
        (let ((entries (ecc-review-resume-entries)))
          (should (= 2 (length entries)))
          (should (equal (mapcar (lambda (entry) (plist-get entry :range)) entries)
                         '("HEAD" nil)))
          (should (= 2 (length (seq-uniq (mapcar #'car (ecc-review-resume--choices
                                                       entries))))))
          (should (string-search "HEAD (y.txt)" (ecc-review-resume-describe (car entries))))
          (with-current-buffer (ecc-review-resume (cadr entries))
            (should-not ecc-review--range)
            (should (equal (ecc-review-resume-test--texts (current-buffer)) '("why 2"))))
          (with-current-buffer (ecc-review-resume (car entries))
            (should (equal ecc-review--range "HEAD"))
            (should (equal (ecc-review-resume-test--texts (current-buffer))
                           '("on B, against HEAD")))))))))

(ert-deftest ecc-review-resume-test-the-files-are-part-of-the-scope ()
  "The same range kept to other files is another review, and blocks the buffer."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (dolist (file '("x.txt" "y.txt"))
          (with-current-buffer (ecc-review-range-buffer session "HEAD" directory
                                                        (list (concat directory file)))
            (ecc-review-resume-test--goto (if (equal file "x.txt") "+2" "+B"))
            (ecc-review-comment (concat "in " file))
            (ecc-review-close)))
        (should (= 2 (length (ecc-review-resume-entries))))
        ;; The same files, given another way, are the same scope.
        (should (equal (ecc-review-resume--scope-key "s" "HEAD" '("b" "a") "/r/")
                       (ecc-review-resume--scope-key "s" "HEAD" '("/r/a" "b") "/r/")))
        (let ((y (car (ecc-review-resume-entries)))
              (x (cadr (ecc-review-resume-entries))))
          (ecc-review-resume x)
          (should-error (ecc-review-resume y) :type 'user-error)
          (should (equal (ecc-review-resume-test--texts
                          (get-buffer (ecc-review-buffer-name session nil "HEAD")))
                         '("in x.txt"))))))))

;;;; Dropping

(defmacro ecc-review-resume-test--answering (answer &rest body)
  "Run BODY with `yes-or-no-p' answering ANSWER, and return what it asked.
ANSWER `fail' fails the test when anything is asked."
  (declare (indent 1))
  `(let ((asked nil))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt)
                  (when (eq ,answer 'fail) (ert-fail (format "asked: %s" prompt)))
                  (push prompt asked)
                  ,answer)))
       ,@body)
     asked))

(ert-deftest ecc-review-resume-test-c-c-c-k-drops-the-saved-review ()
  "C-c C-k asks when comments are not sent; no keeps everything, yes drops it for good."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (let ((review (ecc-review-resume (ecc-review-resume-test--entry session))))
          (with-current-buffer review
            (should (eq (key-binding (kbd "C-c C-k")) #'ecc-review-quit))
            (let ((asked (ecc-review-resume-test--answering nil (ecc-review-quit))))
              (should (string-search "1 comment not sent yet" (car asked)))))
          (should (buffer-live-p review))
          (should (ecc-review-resume-test--entry session))
          ;; Another comment: a save waits for an idle moment.
          (with-current-buffer review
            (ecc-review-resume-test--goto "+B")
            (ecc-review-comment "and B"))
          (should (memq review ecc-review-resume--pending))
          (with-current-buffer review
            (should (ecc-review-resume-test--answering t (ecc-review-quit))))
          (should-not (buffer-live-p review))
          (should-not (ecc-review-resume-test--entry session))
          (should-not (memq review ecc-review-resume--pending))
          ;; Nothing that comes after brings it back.
          (ecc-review-resume--save-pending)
          (ecc-review-resume--save-at-exit)
          (should-not (ecc-review-resume-test--entry session))
          (should-not (ecc-review-resume-entries)))))))

(ert-deftest ecc-review-resume-test-c-c-c-k-without-comments-asks-nothing ()
  "A review with none of your comments not sent is dropped without a question."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (let ((review (ecc-review-buffer session)))
          (with-current-buffer review
            (ecc-review-resume-test--goto "+2")
            (ecc-review-comment "sent")
            (setf (ecc-review-note-sent (car ecc-review--notes)) t)
            (ecc-review-add-note 'claude "Claude's" (ecc-review--line-at-point))
            (ecc-review--draw-notes))
          (ecc-review-resume--save-pending)
          (should (ecc-review-resume-test--entry session))
          (with-current-buffer review
            (ecc-review-resume-test--answering 'fail (ecc-review-quit)))
          (should-not (buffer-live-p review))
          (should-not (ecc-review-resume-test--entry session)))))))

(ert-deftest ecc-review-resume-test-dropping-a-fresh-review-leaves-the-saved-one ()
  "C-c C-k drops what this review saved, not a saved review it never replaced."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (let ((review (ecc-review-buffer session)))
          (ecc-review-resume--save-pending)
          (with-current-buffer review
            (ecc-review-resume-test--answering 'fail (ecc-review-quit)))
          (should (equal (mapcar (lambda (note) (plist-get note :text))
                                 (plist-get (ecc-review-resume-test--entry session) :notes))
                         '("why 2"))))))))

(ert-deftest ecc-review-resume-test-other-endings-still-save ()
  "Killing a diff review, and q in an ediff review, save as before."
  (skip-unless (executable-find "git"))
  (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
        (ecc-review-ediff-layout 'side-by-side)
        (ecc-review-talk-reply-height nil))
    (ecc-review-resume-test--with-world
      (ecc-test-with-fake-session session
        (ecc-review-resume-test--with-directory directory
          (ecc-review-resume-test--repo session directory)
          (let ((review (ecc-review-buffer session)))
            (with-current-buffer review
              (ecc-review-resume-test--goto "+2")
              (ecc-review-comment "killed"))
            (ecc-review-resume-test--answering 'fail (kill-buffer review)))
          (should (equal (mapcar (lambda (note) (plist-get note :text))
                                 (plist-get (ecc-review-resume-test--entry session) :notes))
                         '("killed")))
          (let ((control (ecc-review-ediff-range-buffer session "HEAD" directory)))
            (with-current-buffer control
              (ecc-review-add-note 'user "in ediff" (car (ecc-review-lines)))
              (ecc-review--draw-notes)
              (should (eq (key-binding (kbd "q")) #'ecc-review-close))
              (ecc-review-resume-test--answering 'fail (ecc-review-close))))
          (let ((entry (seq-find (lambda (entry) (equal (plist-get entry :range) "HEAD"))
                                 (ecc-review-resume-entries))))
            (should (eq (plist-get entry :style) 'ediff))
            (should (equal (mapcar (lambda (note) (plist-get note :text))
                                   (plist-get entry :notes))
                           '("in ediff")))))))))

(ert-deftest ecc-review-resume-test-c-c-c-k-drops-an-ediff-review ()
  "C-c C-k in an ediff review asks, and drops what was saved of it."
  (skip-unless (executable-find "git"))
  (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
        (ecc-review-ediff-layout 'side-by-side)
        (ecc-review-talk-reply-height nil)
        (ecc-review-style 'ediff))
    (ecc-review-resume-test--with-world
      (ecc-test-with-fake-session session
        (ecc-review-resume-test--with-directory directory
          (ecc-review-resume-test--repo session directory)
          (with-current-buffer (ecc-review session)
            (ecc-review-add-note 'user "in ediff" (car (ecc-review-lines)))
            (ecc-review--draw-notes)
            (ecc-review-close))
          (let ((control (ecc-review-resume (ecc-review-resume-test--entry session))))
            (with-current-buffer control
              (should (eq (key-binding (kbd "C-c C-k")) #'ecc-review-quit))
              (should (ecc-review-resume-test--answering t (ecc-review-quit))))
            (should-not (buffer-live-p control))
            (ecc-review-resume--save-at-exit)
            (should-not (ecc-review-resume-test--entry session))))))))

;;;; What refuses

(ert-deftest ecc-review-resume-test-a-session-not-in-this-emacs-is-refused ()
  "A review of a session this Emacs does not have is not opened for another."
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (let ((entry (list :session "no-such-session" :name "elsewhere"
                         :root temporary-file-directory :directory temporary-file-directory
                         :style 'diff :time (float-time))))
        (should (string-search "not open in this Emacs" (ecc-review-resume-describe entry)))
        (let ((error (should-error (ecc-review-resume entry) :type 'user-error)))
          (should (string-search "elsewhere is not open in this Emacs"
                                 (cadr error))))
        (should-not (get-buffer (ecc-review-buffer-name session)))))))

(ert-deftest ecc-review-resume-test-a-baseline-gone-is-refused ()
  "When git no longer has the baseline, the review is not opened against another."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (let ((baseline (ecc-session-baseline session))
              (entry (plist-put (copy-sequence (ecc-review-resume-test--entry session))
                                :baseline (make-string 40 ?0))))
          (let ((error (should-error (ecc-review-resume entry) :type 'user-error)))
            (should (string-search "git no longer has 0000000" (cadr error))))
          (should-not (get-buffer (ecc-review-buffer-name session)))
          (should (equal (ecc-session-baseline session) baseline)))))))

(ert-deftest ecc-review-resume-test-the-saved-baseline-is-taken-back ()
  "A session that took a new baseline is reviewed against the saved one again."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session session
      (ecc-review-resume-test--with-directory directory
        (ecc-review-resume-test--repo session directory)
        (ecc-review-resume-test--diff-review session)
        (let ((saved (ecc-session-baseline session)))
          ;; What a restored session did before its baseline was saved.
          (setf (ecc-session-baseline session) nil)
          (should (ecc-review-ensure-baseline session))
          (should-not (equal (ecc-session-baseline session) saved))
          (with-current-buffer (ecc-review-resume (ecc-review-resume-test--entry session))
            (should (equal (ecc-session-baseline session) saved))
            (should (string-search "+2" (buffer-string)))
            (should (equal (ecc-review-resume-test--texts (current-buffer)) '("why 2")))))))))

;;;; Two sessions

(ert-deftest ecc-review-resume-test-two-sessions-keep-a-review-each ()
  "Each session keeps its own review, and each comes back with its own comment."
  (skip-unless (executable-find "git"))
  (ecc-review-resume-test--with-world
    (ecc-test-with-fake-session one
      (ecc-review-resume-test--with-directory first
        (ecc-review-resume-test--with-directory second
          (let ((two (ecc-model-create-session :name "other" :project-root second)))
            (unwind-protect
                (progn
                  (ecc-review-resume-test--repo one first)
                  (ecc-review-resume-test--repo two second)
                  (ecc-review-resume-test--diff-review one)
                  (with-current-buffer (ecc-review-buffer two)
                    (ecc-review-resume-test--goto "+B")
                    (ecc-review-comment "the other's")
                    (ecc-review-close))
                  ;; Both kept, the one saved last first.
                  (let ((entries (ecc-review-resume-entries)))
                    (should (equal (mapcar (lambda (entry) (plist-get entry :name)) entries)
                                   '("other" "test")))
                    (should (equal (mapcar (lambda (entry) (plist-get entry :baseline)) entries)
                                   (list (ecc-session-baseline two)
                                         (ecc-session-baseline one))))
                    (should (= 2 (length (seq-uniq (mapcar #'car (ecc-review-resume--choices
                                                                 entries)))))))
                  ;; Offered by name, the one saved last the default.
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt table &rest args)
                               (should (equal (nth 4 args)
                                              (car (all-completions "" table))))
                               (car (all-completions "test" table)))))
                    (should (eq (buffer-local-value 'ecc-review--session
                                                    (call-interactively #'ecc-review-resume))
                                one)))
                  (should (equal (ecc-review-resume-test--texts
                                  (get-buffer (ecc-review-buffer-name one)))
                                 '("why 2")))
                  (with-current-buffer (ecc-review-resume (ecc-review-resume-test--entry two))
                    (should (eq ecc-review--session two))
                    (should (equal (file-truename default-directory) (file-truename second)))
                    (should (equal (ecc-review-resume-test--texts (current-buffer))
                                   '("the other's")))
                    (should (equal (ecc-review-resume-test--line) "+B"))))
              (ecc-test-cleanup-session two))))))))

;;;; The menu

(ert-deftest ecc-review-resume-test-the-review-menu-resumes ()
  "R in the review menu resumes, and is off while no review is saved."
  (ecc-review-resume-test--with-world
    (should-not (ecc-review-resume-saved-p))
    (should-not (funcall (oref (get 'ecc-review-menu-resume 'transient--suffix) inapt-if-not)))
    (with-temp-file ecc-review-resume-file
      (prin1 (list :version ecc-review-resume--version
                   :reviews (list (list :session "s" :root temporary-file-directory
                                        :time (float-time))))
             (current-buffer)))
    (should (ecc-review-resume-saved-p))
    (should (funcall (oref (get 'ecc-review-menu-resume 'transient--suffix) inapt-if-not)))
    (should (equal (assoc "R" (ecc-review-resume-test--menu-suffixes))
                   '("R" ecc-review-menu-resume)))
    (should (commandp 'ecc-review-menu-resume))))

(defun ecc-review-resume-test--menu-suffixes ()
  "Return the (KEY COMMAND) of every suffix `ecc-review-menu' declares."
  (with-temp-buffer
    (insert-file-contents (locate-library "ecc-review-menu.el" t))
    (goto-char (point-min))
    (re-search-forward "^(transient-define-prefix ecc-review-menu ")
    (beginning-of-line)
    (let ((out nil))
      (letrec ((walk (lambda (node)
                       (cond ((vectorp node) (mapc walk (append node nil)))
                             ((and (consp node) (stringp (car node)))
                              (push (list (car node) (car (last node))) out))
                             ((consp node)
                              (mapc (lambda (x) (when (or (consp x) (vectorp x))
                                                  (funcall walk x)))
                                    node))))))
        (dolist (group (cdddr (read (current-buffer))))
          (when (vectorp group) (funcall walk group))))
      (nreverse out))))

(provide 'ecc-review-resume-test)

;;; ecc-review-resume-test.el ends here
