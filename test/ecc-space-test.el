;;; ecc-space-test.el --- Tests for ecc-space  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Space model -- what Spaces there are, in what order, under which
;; parent, in what state -- without a tab bar in sight, and then the thin
;; layer that does use one.  git is never run: what it would say about a
;; worktree is bound here, so that the ordering can be tested on a
;; machine with no repository in it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-space)
;; Both are loaded on demand by `ecc-space': here they are loaded up
;; front, so that a `require' inside does not redefine a stub the test
;; has just put in place.
(require 'ecc-history)
(require 'ecc)
(require 'ecc-sidebar)
(require 'ecc-window)
(require 'ecc-session)

;;;; Helpers

(defconst ecc-space-test--one "/tmp/project-one/")
(defconst ecc-space-test--two "/tmp/project-two/")
(defconst ecc-space-test--work "/tmp/project-one/.claude/worktrees/feat-x/")

(defmacro ecc-space-test--with-git (&rest body)
  "Run BODY with git answering for a fixed repository of three checkouts.
`ecc-space-test--work' is a worktree of `ecc-space-test--one' on the
branch `worktree/feat-x'; the other two are repositories of their own."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'ecc-worktree-main)
              (lambda (root)
                (and (equal root ecc-space-test--work) ecc-space-test--one)))
             ((symbol-function 'ecc-worktree-branch)
              (lambda (root)
                (cond ((equal root ecc-space-test--work) "worktree/feat-x")
                      ((equal root ecc-space-test--one) "main")
                      (t "master")))))
     ,@body))

(defmacro ecc-space-test--with-sessions (spec &rest body)
  "Run BODY with a session in each root of SPEC, an alist of (NAME . ROOT).
The sessions are made in order, so the last one is the most recently
used, and the registry is emptied afterwards.  Every root answers as a
project of its own and the Space tables are fresh."
  (declare (indent 1))
  `(let* ((ecc-test-sent nil)
          (ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-window--project-root-cache (make-hash-table :test #'equal))
          (ecc-window--project-source-buffers nil)
          (ecc-window--last-source-buffer nil)
          (ecc-worktree--cache (make-hash-table :test #'equal))
          (ecc-space--tabs nil)
          (ecc-space--used nil)
          (sessions (mapcar (lambda (entry)
                              (ecc-model-create-session
                               :name (car entry) :project-root (cdr entry)))
                            ,spec)))
     (ignore sessions)
     (unwind-protect
         (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                   ((symbol-function 'ecc-proc-send-json)
                    (lambda (_session object) object)))
           (ecc-space-test--with-git ,@body))
       (mapc #'ecc-test-cleanup-session sessions))))

(defun ecc-space-test--past-p (space)
  "Return non-nil when SPACE is one of the projects only recordings are left of."
  (ecc-space-past space))

(defun ecc-space-test--names ()
  "Return the name of every Space, in order."
  (mapcar #'ecc-space-name (ecc-space-list)))

(defun ecc-space-test--roots ()
  "Return the root of every Space, in order."
  (mapcar #'ecc-space-root (ecc-space-list)))

;;;; The model

(ert-deftest ecc-space-test-one-per-project ()
  "Every project with a session has a Space, most recently used first."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (should (equal (ecc-space-test--roots)
                   (list ecc-space-test--two ecc-space-test--one)))
    (should (equal (ecc-space-test--names) '("project-two" "project-one")))))

(ert-deftest ecc-space-test-a-worktree-follows-its-parent ()
  "A worktree is drawn under the repository it came from, named by its branch."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("work" . ,ecc-space-test--work)
                                   ("two" . ,ecc-space-test--two))
    ;; Most recently used first would be two, work, one; the child is
    ;; pulled out of that order and put under its parent instead.
    (should (equal (ecc-space-test--roots)
                   (list ecc-space-test--two
                         ecc-space-test--one
                         ecc-space-test--work)))
    ;; The name of a worktree is its branch, without herdr's prefix.
    (should (equal (ecc-space-test--names)
                   '("project-two" "project-one" "feat-x")))
    (let ((spaces (ecc-space-list)))
      (should-not (ecc-space-child-p (nth 1 spaces) spaces))
      (should (ecc-space-child-p (nth 2 spaces) spaces))
      (should (equal (mapcar (lambda (space) (ecc-space-number space spaces))
                             spaces)
                     '(1 2 3))))))

(ert-deftest ecc-space-test-an-orphan-worktree-stands-alone ()
  "A worktree whose repository has no Space is a Space of its own."
  (ecc-space-test--with-sessions `(("work" . ,ecc-space-test--work)
                                   ("two" . ,ecc-space-test--two))
    (should (equal (ecc-space-test--roots)
                   (list ecc-space-test--two ecc-space-test--work)))
    (let ((spaces (ecc-space-list)))
      ;; It still knows what it is -- the name is the branch -- but
      ;; there is nothing on the screen to indent it under.
      (should (equal (ecc-space-name (nth 1 spaces)) "feat-x"))
      (should-not (ecc-space-child-p (nth 1 spaces) spaces)))))

(ert-deftest ecc-space-test-state-rolls-up ()
  "The loudest session of a Space says what the Space is doing."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("one-b" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (let ((space (ecc-space-of-root ecc-space-test--one))
          (other (ecc-space-of-root ecc-space-test--two)))
      (mapc (lambda (session) (ecc-model-set-state session 'idle)) sessions)
      (should (equal (ecc-space-state space) 'idle))
      (ecc-model-set-state (nth 1 sessions) 'running)
      (should (equal (ecc-space-state space) 'running))
      ;; A request waiting for an answer wins over work in progress.
      (ecc-test-add-request (car sessions) "Write")
      (should (equal (ecc-space-state space) 'attention))
      ;; And a Space of its own is unmoved by any of it.
      (should (equal (ecc-space-state other) 'idle)))))

(ert-deftest ecc-space-test-state-of-a-space-with-nothing-in-it ()
  "A Space with no session has no state to draw."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (should-not (ecc-space-state (ecc-space-of-root ecc-space-test--two)))))

;;;; The tabs

(defvar ecc-space-test--started nil
  "Roots `ecc-start' was asked for, newest first.")

(defmacro ecc-space-test--with-tab-bar (&rest body)
  "Run BODY with a tab bar, closing whatever tabs it opened afterwards.
`tab-bar-new-tab' does work in batch, with no tab bar drawn anywhere
\(verified 2026-09-14), so the tab side is tested for real rather than
by watching which function is called.  `ecc-layout' is `spaces'
throughout: `ecc-space-select' makes no tab under `classic'.

`ecc-start' is stood in for: going to a Space with nothing running
starts a session there, and no test in this file is allowed to run a
CLI.  What it was asked for is in `ecc-space-test--started'."
  (declare (indent 0))
  `(let ((was tab-bar-mode)
         (ecc-layout 'spaces)
         (ecc-space-test--started nil))
     (unwind-protect
         (cl-letf (((symbol-function 'ecc-start)
                    (lambda (&optional root &rest _)
                      (push root ecc-space-test--started)
                      nil)))
           (tab-bar-mode 1) ,@body)
       (dolist (tab (funcall tab-bar-tabs-function))
         (unless (eq (car tab) 'current-tab)
           (tab-bar-close-tab-by-name (alist-get 'name tab))))
       ;; The tab that is current cannot be closed, and it carries the
       ;; name a Space gave it.  Left alone, the next case that opens a
       ;; Space of the same name finds it taken and gets `name<2>'.
       (tab-bar-rename-tab "")
       (tab-bar-mode (if was 1 -1)))))

(ert-deftest ecc-space-test-select-makes-no-tab-under-classic ()
  "Under `classic', going to a Space focuses the project and makes no tab.
Turning the tab bar on because somebody pressed a number in the
sidebar would be changing the layout behind their back."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (let ((ecc-layout 'classic)
          (focused nil))
      (cl-letf (((symbol-function 'ecc-focus-project)
                 (lambda (root &rest _) (setq focused root))))
        (should-not (ecc-space-select (ecc-space-of-root ecc-space-test--one)))
        (should (equal focused ecc-space-test--one))
        (should-not ecc-space--tabs)
        (should-not (bound-and-true-p tab-bar-mode))))
    ;; A Space with nothing running in it is shown rather than refused:
    ;; `ecc-focus-project' has no windows to deal out there.
    (let ((ecc-layout 'classic)
          (ecc-space-test--started nil)
          (shown nil))
      (cl-letf (((symbol-function 'ecc-window-focus-source)
                 (lambda (root &rest _) (setq shown root)))
                ((symbol-function 'ecc-start)
                 (lambda (&optional root &rest _)
                   (push root ecc-space-test--started))))
        (ecc-space-select (make-ecc-space :key "/tmp/empty/" :root "/tmp/empty/"
                                          :name "empty"))
        (should (equal shown "/tmp/empty/"))
        ;; And `classic' starts nothing: the automatic session belongs
        ;; to the tab, which `classic' does not make.
        (should-not ecc-space-test--started)))))

(ert-deftest ecc-space-test-select-makes-a-tab-then-reuses-it ()
  "A Space gets one tab, named after it, and is found again by that name."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let ((one (ecc-space-of-root ecc-space-test--one))
            (two (ecc-space-of-root ecc-space-test--two)))
        (should (equal (ecc-space-select one) "project-one"))
        (should (equal (ecc-space-current-key) ecc-space-test--one))
        (should (equal (ecc-space-select two) "project-two"))
        (should (equal (ecc-space-current-key) ecc-space-test--two))
        ;; Back to the first: the same tab, not a second one.
        (should (equal (ecc-space-select one) "project-one"))
        (should (equal (length (funcall tab-bar-tabs-function)) 3))
        (should (equal (ecc-space-tab one) "project-one"))))))

(ert-deftest ecc-space-test-two-spaces-of-one-name ()
  "Two Spaces that would be called the same get tabs that are not."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((a (make-ecc-space :key "/tmp/a/" :root "/tmp/a/" :name "main"))
            (b (make-ecc-space :key "/tmp/b/" :root "/tmp/b/" :name "main")))
        (should (equal (ecc-space-select a) "main"))
        (should (equal (ecc-space-select b) "main<2>"))
        (should (equal (ecc-space-tab a) "main"))))))

(ert-deftest ecc-space-test-a-closed-tab-is-forgotten ()
  "Closing the tab of a Space by hand leaves nothing behind but the sessions."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((one (ecc-space-of-root ecc-space-test--one)))
        (ecc-space-select one)
        (tab-bar-close-tab-by-name "project-one")
        (should-not (ecc-space-tab one))
        (should-not (ecc-space-current-key))
        ;; The session is untouched: it has no window, that is all.
        (should (ecc-space-sessions one))))))

(ert-deftest ecc-space-test-a-tab-with-no-session-keeps-its-place ()
  "A Space whose sessions have gone is still listed, after the busy ones."
  (ecc-space-test--with-sessions `(("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (ecc-space-select (make-ecc-space :key ecc-space-test--one
                                        :root ecc-space-test--one
                                        :name "project-one"))
      (should (equal (ecc-space-test--roots)
                     (list ecc-space-test--two ecc-space-test--one))))))

(ert-deftest ecc-space-test-windows-go-beside-and-beside-again ()
  "The first session is put beside the source, the next beside the first.
Ordinary windows, both: no role and no dedication, so that the user can
move them afterwards."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("one-b" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-layout 'spaces)
            (ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        ;; The sidebar comes up with a new Space; this case is about the
        ;; session windows alone, so it is taken down again.
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let* ((source (selected-window))
               (first (ecc-space-display-session (car sessions))))
          (should (window-live-p first))
          (should-not (window-parameter first 'ecc-window-role))
          (should-not (window-dedicated-p first))
          ;; Beside: to the right of the source, not above or below it.
          (should (> (nth 0 (window-edges first)) (nth 0 (window-edges source))))
          (let ((second (ecc-space-display-session (nth 1 sessions))))
            (should (window-live-p second))
            (should-not (eq second first))
            ;; Beside the session window, and in the same row as it.
            (should (= (nth 1 (window-edges second)) (nth 1 (window-edges first))))
            (should (> (nth 0 (window-edges second)) (nth 0 (window-edges first))))
            ;; And a session already on the screen is not opened twice.
            (should (eq (ecc-space-display-session (car sessions)) first))
            (should (= 3 (length (window-list nil 'no-minibuffer))))))))))

(ert-deftest ecc-space-test-a-new-session-goes-to-the-right ()
  "A session opens at the right end, and leaves the one being read alone.
Nothing is ever stacked: the sessions of a Space stand side by side, and
the new one divides the rightmost of them rather than the window last
worked in, which would cut the transcript being read in half."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one)
                                   ("three" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      ;; Wide enough for three transcripts abreast in a batch frame.
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (cl-labels ((row ()
                      (mapcar (lambda (window)
                                (ecc-session-name
                                 (ecc-window-buffer-session
                                  (window-buffer window))))
                              (ecc-space--session-windows))))
          ;; The sessions were made oldest last, so take them in order.
          (let* ((ordered (reverse sessions))
                 (first (nth 0 ordered))
                 (second (nth 1 ordered))
                 (third (nth 2 ordered)))
            (ecc-space-display-session first)
            (ecc-space-display-session second)
            (should (equal (row) (list (ecc-session-name first)
                                       (ecc-session-name second))))
            ;; Go back to the first, the way anybody reading would, and
            ;; remember how wide it is.
            (let* ((window (get-buffer-window (ecc-session-buffer first)))
                   (width (window-body-width window)))
              (select-window window)
              (ecc-space-display-session third)
              ;; The third is at the right end, not between the other two.
              (should (equal (row) (list (ecc-session-name first)
                                         (ecc-session-name second)
                                         (ecc-session-name third))))
              ;; Nothing was stacked: one row, three windows abreast.
              (should (apply #'= (mapcar (lambda (w) (nth 1 (window-edges w)))
                                         (ecc-space--session-windows))))
              ;; And the one being read kept its room.
              (should (= width (window-body-width window))))))))))

(ert-deftest ecc-space-test-a-full-row-takes-over-the-oldest-window ()
  "With no room for another column, the session used longest ago gives up its.
A narrower window is not made: the row keeps the width it needs to be
read, and the session that lost its window goes on running without one."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one)
                                   ("three" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let* ((ordered (reverse sessions))
               (first (nth 0 ordered))
               (second (nth 1 ordered))
               (third (nth 2 ordered)))
          (ecc-space-display-session first)
          (ecc-space-display-session second)
          ;; The first was worked in most recently of the two on screen,
          ;; so it is the second that hands its window over.
          (ecc-model-touch first)
          (let ((windows (length (window-list nil 'no-minibuffer)))
                (taken (get-buffer-window (ecc-session-buffer second)))
                ;; Wider than the frame: nothing can be divided again.
                (ecc-space-session-min-width (frame-width)))
            (let ((window (ecc-space-display-session third)))
              (should (eq window taken))
              (should (= windows (length (window-list nil 'no-minibuffer))))
              (should (eq (window-buffer window) (ecc-session-buffer third)))
              (should-not (get-buffer-window (ecc-session-buffer second)))
              (should (get-buffer-window (ecc-session-buffer first))))))))))

(defun ecc-space-test--layout ()
  "Return the buffer name and width of every window of this tab, left to right."
  (mapcar (lambda (window)
            (cons (buffer-name (window-buffer window))
                  (window-total-width window)))
          (sort (window-list nil 'no-minibuffer)
                (lambda (a b)
                  (< (nth 0 (window-edges a)) (nth 0 (window-edges b)))))))

(defmacro ecc-space-test--with-popup (var &rest body)
  "Run BODY with VAR bound to a buffer standing in for a question or a plan."
  (declare (indent 1))
  `(let ((,var (get-buffer-create "*ecc-question: test*")))
     (unwind-protect (progn ,@body)
       (kill-buffer ,var))))

(ert-deftest ecc-space-test-a-question-leaves-the-other-session-alone ()
  "A question opens beside its session and takes no session\\='s window.
The session windows of a Space are narrower than
`split-width-threshold\\=', so `display-buffer\\=' could divide none of them
and `display-buffer-use-some-window\\=' handed over whichever window had
been used longest ago -- the transcript of the other session, which
then vanished (reported 2026-09-16).  Two sessions, because what it
does to the one that was not asked about is the bug."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-layout 'spaces)
            (ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let ((one (car sessions)) (two (nth 1 sessions)))
          (ecc-space-display-session one)
          (ecc-space-display-session two)
          (ecc-space-test--with-popup popup
            (let* ((before (ecc-space-test--layout))
                   (window (ecc-window-display-beside-session popup one)))
              (should (window-live-p window))
              (should (eq (window-buffer window) popup))
              ;; Neither transcript lost its window.
              (should (get-buffer-window (ecc-session-buffer one)))
              (should (get-buffer-window (ecc-session-buffer two)))
              ;; And the row is as it was once the question is answered:
              ;; the window it was in goes back to what it held, at the
              ;; width it held it.
              (quit-window nil window)
              (should (equal (ecc-space-test--layout) before)))))))))

(ert-deftest ecc-space-test-a-question-brings-its-session-with-it ()
  "A question of a session with no window opens the session as well.
The two are read together: a question with nothing around it says
nothing about what is being asked."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-layout 'spaces)
            (ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let ((two (nth 1 sessions)))
          (ecc-space-test--with-popup popup
            (let ((window (ecc-window-display-beside-session popup two)))
              (should (window-live-p window))
              (should (eq (window-buffer window) popup))
              (should (get-buffer-window (ecc-session-buffer two))))))))))

(ert-deftest ecc-space-test-a-question-divides-rather-than-take-a-transcript ()
  "With every window a transcript, the question divides one instead.
There is no window left to put it in, and taking one would lose a
conversation; a new window is made beside the session being asked
about, and both transcripts stay on the screen."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-layout 'spaces)
            (ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let ((one (car sessions)) (two (nth 1 sessions)))
          (ecc-space-display-session one)
          ;; The source window is given to the other session, so that
          ;; nothing on the tab is anything but a transcript.
          (set-window-buffer (selected-window) (ecc-session-buffer two))
          (should-not (ecc-space--popup-window))
          (ecc-space-test--with-popup popup
            (let ((count (length (window-list nil 'no-minibuffer)))
                  (window (ecc-window-display-beside-session popup one)))
              (should (eq (window-buffer window) popup))
              (should (= (1+ count) (length (window-list nil 'no-minibuffer))))
              (should (get-buffer-window (ecc-session-buffer one)))
              (should (get-buffer-window (ecc-session-buffer two))))))))))

(ert-deftest ecc-space-test-a-new-tab-stands-the-sessions-side-by-side ()
  "The tab of a Space comes up with its sessions already on the screen.
Most recently used first, to the right of the source.  A tab that opened
with the transcripts hidden was one the user had to unpack by hand."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (let ((row (mapcar (lambda (window)
                             (ecc-session-name
                              (ecc-window-buffer-session (window-buffer window))))
                           (ecc-space--session-windows))))
          ;; `ecc-model-sessions' is most recently used first, and the
          ;; sessions were made oldest first.
          (should (equal row '("two" "one")))
          ;; One row: nothing was stacked.
          (should (apply #'= (mapcar (lambda (w) (nth 1 (window-edges w)))
                                     (ecc-space--session-windows))))
          ;; And the source is still there, to the left of them.
          (should (< (nth 0 (window-edges (ecc-window--source-window)))
                     (nth 0 (window-edges
                             (car (ecc-space--session-windows)))))))))))

(ert-deftest ecc-space-test-a-tab-with-no-window-for-the-code-gets-one ()
  "Going to a Space whose tab has only transcripts in it puts the code back.
The windows of a tab are the user\='s and are left where they were put.
A tab with nothing but transcripts is the one case that is nobody\='s
arrangement -- `delete-other-windows\=' on a transcript leaves it -- and
nothing brought that window back on its own (reported 2026-09-16)."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let* ((one (ecc-space-of-root ecc-space-test--one))
             (two (ecc-space-of-root ecc-space-test--two))
             (ecc-window-width 20)
             (ecc-space-session-min-width 10)
             ;; A file of the project to read: these roots are names
             ;; rather than directories, so there is none to list either.
             (code (get-buffer-create "code.el")))
        (with-current-buffer code
          (setq buffer-file-name (expand-file-name "code.el" ecc-space-test--one)))
        (ecc-space-select one)
        ;; The source window is given to a transcript and everything
        ;; else is put away, the way C-x 1 on a transcript leaves it.
        (let ((session (car (ecc-window-project-sessions ecc-space-test--one))))
          (set-window-buffer (ecc-window--source-window)
                             (ecc-session-ensure-buffer session))
          (delete-other-windows
           (get-buffer-window (ecc-session-buffer session)))
          (should-not (ecc-space--source-window)))
        ;; Away and back: the tab has a window for the code again, and
        ;; the transcript that took it over is still there.
        (ecc-space-select two)
        (ecc-space-select one)
        (let ((window (ecc-space--source-window)))
          (should window)
          (should (ecc-window--buffer-in-project-p
                   (window-buffer window)
                   (ecc-window-project-key ecc-space-test--one)))
          (should (ecc-space--session-windows))
          ;; To the left of the transcript, where a Space keeps it.
          (should (< (nth 0 (window-edges window))
                     (nth 0 (window-edges
                             (car (ecc-space--session-windows))))))))
      (when-let* ((code (get-buffer "code.el")))
        (with-current-buffer code (set-buffer-modified-p nil))
        (kill-buffer code)))))

(ert-deftest ecc-space-test-a-tab-that-has-a-source-window-is-left-alone ()
  "A window pointed at another project is the user\='s doing and stays.
`ecc-window-focus-source\=' is the way back, and it is a command with a
key of its own for that reason; going to the Space is not."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let ((one (ecc-space-of-root ecc-space-test--one))
            (two (ecc-space-of-root ecc-space-test--two))
            (ecc-window-width 20)
            (ecc-space-session-min-width 10))
        (ecc-space-select one)
        (let* ((stranger (get-buffer-create "stranger.txt"))
               (window (ecc-space--source-window))
               (before (length (window-list nil 'no-minibuffer))))
          (set-window-buffer window stranger)
          (ecc-space-select two)
          (ecc-space-select one)
          (should (eq (window-buffer (ecc-space--source-window)) stranger))
          (should (= before (length (window-list nil 'no-minibuffer))))
          (kill-buffer stranger))))))

(ert-deftest ecc-space-test-focus-source-puts-the-code-of-this-space-back ()
  "`ecc-window-focus-source\=' is the way back, and it asks the Space first.
Everywhere else the project is read off the buffer in front of the
user.  Here that buffer is the very thing being complained about -- a
window of this tab showing another project -- so the Space showing is
what the command means by \"this project\"."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let* ((one (ecc-space-of-root ecc-space-test--one))
             (ecc-window-width 20)
             (ecc-space-session-min-width 10)
             (code (get-buffer-create "code.el"))
             (stranger (get-buffer-create "stranger.el")))
        (with-current-buffer code
          (setq buffer-file-name (expand-file-name "code.el" ecc-space-test--one)))
        (with-current-buffer stranger
          (setq buffer-file-name (expand-file-name "other.el" ecc-space-test--two)))
        (should (commandp 'ecc-window-focus-source))
        (ecc-space-select one)
        (set-window-buffer (ecc-space--source-window) stranger)
        ;; Run from the window that holds the stranger, the way the user
        ;; would be sitting in it.
        (with-current-buffer stranger
          (call-interactively #'ecc-window-focus-source))
        (should (eq (window-buffer (ecc-space--source-window)) code))
        (dolist (buffer (list code stranger))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest ecc-space-test-a-new-tab-stops-when-the-row-is-full ()
  "The lay-out stops at the edge of the row rather than taking a window over.
A session that does not fit goes on running without one; the sidebar
and `ecc-toggle' bring it back."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one)
                                   ("three" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      ;; Wider than the frame: one session fits and nothing else can.
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width (frame-width)))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (should (= 1 (length (ecc-space--session-windows))))
        ;; The one on the screen is the most recently used, and the
        ;; other two kept their own buffers rather than being swapped in.
        (should (equal "three"
                       (ecc-session-name
                        (ecc-window-buffer-session
                         (window-buffer (car (ecc-space--session-windows))))))))))) 

(ert-deftest ecc-space-test-an-empty-space-gets-a-session ()
  "Going to a Space with nothing running starts one there.
A tab with a file in it and no way to say anything is a Space that
looks broken."
  (ecc-space-test--with-sessions `(("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let ((root (file-name-as-directory (make-temp-file "ecc-space" t))))
        (unwind-protect
            (progn
              (ecc-space-select (ecc-space-of-root root))
              (should (equal ecc-space-test--started
                             (list (ecc-space-root (ecc-space-of-root root)))))
              ;; The Space that has one is left alone.
              (setq ecc-space-test--started nil)
              (ecc-space-select (ecc-space-of-root ecc-space-test--two))
              (should-not ecc-space-test--started))
          (delete-directory root t))))))

(ert-deftest ecc-space-test-the-automatic-session-does-not-loop ()
  "Starting a session shows it, and showing it selects the Space again.
Without a guard the second turn of that circle starts another session:
`ecc-model-create-session' has registered nothing at the moment the
first one asks for a window."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (let* ((root (file-name-as-directory (make-temp-file "ecc-space" t)))
             (space (ecc-space-of-root root))
             (calls 0))
        (unwind-protect
            (cl-letf (((symbol-function 'ecc-start)
                       (lambda (&optional directory &rest _)
                         (cl-incf calls)
                         ;; What `ecc-start' does, in the order it does
                         ;; it: the session is made, and then shown.
                         (let ((session (ecc-model-create-session
                                         :name "auto" :project-root directory)))
                           (ecc-space-display-session session)
                           session))))
              (ecc-space-select space)
              (should (= 1 calls))
              (should (= 1 (length (ecc-space-sessions space)))))
          (mapc #'ecc-test-cleanup-session (ecc-space-sessions space))
          (delete-directory root t))))))

(ert-deftest ecc-space-test-a-past-project-is-offered-but-not-listed ()
  "A project only recordings are left of can be gone to, and is not numbered.
Putting it in `ecc-space-list' would move the numbers the sidebar draws
and the 1-9 keys take under the user's feet."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (let* ((past (file-name-as-directory (make-temp-file "ecc-space-past" t)))
           (numbers (mapcar (lambda (space) (ecc-space-number space))
                            (ecc-space-list)))
           (listed (ecc-space-test--roots)))
      (unwind-protect
          (cl-letf (((symbol-function 'ecc-history-project-roots)
                     (lambda () (list (directory-file-name past)
                                      ;; A checkout that is gone has
                                      ;; nowhere to start a session.
                                      "/tmp/ecc-space-gone/"
                                      ;; And the live project is not
                                      ;; offered twice.
                                      ecc-space-test--one))))
            (let ((spaces (ecc-space-past-projects)))
              (should (equal (mapcar #'ecc-space-root spaces) (list past)))
              (should (ecc-space-test--past-p (car spaces))))
            ;; The list and the numbering are untouched.
            (should (equal listed (ecc-space-test--roots)))
            (should (equal numbers (mapcar (lambda (space)
                                             (ecc-space-number space))
                                           (ecc-space-list))))
            ;; And it is offered, after the Spaces on the screen.
            (let ((ecc-layout 'spaces)
                  (offered nil))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt collection &rest _)
                           (setq offered (all-completions "" collection))
                           (car (last offered)))))
                (should (equal past (ecc-space-root (ecc-space-read)))))
              (should (= 2 (length offered)))
              (should (string-match-p "past" (car (last offered))))))
        (delete-directory past t)))))

(ert-deftest ecc-space-test-going-to-a-request-goes-to-its-space ()
  "`ecc-next-attention' takes the Space of the session with it.
A question and a plan open a buffer of their own, and that buffer used
to be popped into whichever Space the user was in, leaving the session
it belongs to behind in another tab."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let ((there (nth 1 sessions))
            (opened nil))
        (unwind-protect
            (dolist (tool '("Write" "AskUserQuestion"))
              ;; Stand in the first Space, with the request in the second.
              (ecc-space-select (ecc-space-of-root ecc-space-test--one))
              (should (equal (ecc-space-current-key) ecc-space-test--one))
              (let ((request (ecc-test-add-request there tool)))
                (ecc-next-attention)
                (should (equal (ecc-space-current-key) ecc-space-test--two))
                (when-let* ((buffer (get-buffer
                                     (format "*ecc-question: %s*"
                                             (ecc-session-name there)))))
                  (push buffer opened))
                (ignore request)
                (setf (ecc-session-pending there) nil)))
          (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) opened))))))

(ert-deftest ecc-space-test-zoom-goes-back ()
  "Zooming leaves one window and zooming again brings the others back."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (unwind-protect
          (progn
            (delete-other-windows)
            (split-window-right)
            (split-window-below)
            (let ((before (length (window-list nil 'no-minibuffer))))
              (should (= before 3))
              (ecc-space-zoom)
              (should (= 1 (length (window-list nil 'no-minibuffer))))
              (ecc-space-zoom)
              (should (= before (length (window-list nil 'no-minibuffer))))))
        (set-frame-parameter nil 'ecc-space-zoom nil)
        (delete-other-windows)))))

(ert-deftest ecc-space-test-zoom-says-when-there-is-nothing-to-zoom ()
  "One window on its own is not zoomed, and is not left thinking it was.
Saving the state here would leave the key `zoomed' without the screen
having changed, and the way back would do nothing either."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (unwind-protect
          (progn
            (delete-other-windows)
            (ecc-space-zoom)
            (should-not (frame-parameter nil 'ecc-space-zoom))
            (should (= 1 (length (window-list nil 'no-minibuffer))))
            ;; A side window beside it is not something to put away
            ;; either: it refuses to be deleted.
            (let ((side (display-buffer-in-side-window
                         (get-buffer-create "*ecc-space-test-side*")
                         '((side . left) (slot . 0) (window-width . 20)
                           (window-parameters
                            . ((no-delete-other-windows . t)))))))
              (ecc-space-zoom)
              (should-not (frame-parameter nil 'ecc-space-zoom))
              (should (window-live-p side))
              ;; And from inside the side window it says so rather than
              ;; letting `delete-other-windows' raise.
              (select-window side)
              (should-error (ecc-space-zoom) :type 'user-error)))
        (set-frame-parameter nil 'ecc-space-zoom nil)
        (when (get-buffer "*ecc-space-test-side*")
          (kill-buffer "*ecc-space-test-side*"))
        (delete-other-windows)))))

;;;; What the rest of the package asks

(ert-deftest ecc-space-test-context-root-follows-the-tab ()
  "With `spaces', the Space showing says which project a session starts in."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-layout 'spaces))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (with-temp-buffer
          ;; A buffer behind no file says nothing, so the tab is asked.
          (should (equal (ecc-window-context-project-root)
                         ecc-space-test--one))
          ;; And with `classic' it is not, whatever tab is showing.
          (let ((ecc-layout 'classic)
                (default-directory "/tmp/elsewhere/"))
            (should (equal (ecc-window-context-project-root)
                           "/tmp/elsewhere/"))))))))

(ert-deftest ecc-space-test-display-session-goes-through-the-space ()
  "`ecc-display-session' hands over to the Space layout when asked to."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (let ((shown nil))
      (cl-letf (((symbol-function 'ecc-space-display-session)
                 (lambda (session) (setq shown session) 'window)))
        (let ((ecc-layout 'spaces))
          (should (eq (ecc-display-session (car sessions)) 'window))
          (should (eq shown (car sessions))))
        ;; `classic' never reaches it.
        (setq shown nil)
        (let ((ecc-layout 'classic)
              (ecc-window-use-side-window nil))
          (ecc-display-session (car sessions))
          (should-not shown))))))

(ert-deftest ecc-space-test-focus-project-selects-the-space ()
  "With `spaces', focusing a project is going to its tab."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (let ((selected nil))
      (cl-letf (((symbol-function 'ecc-space-select)
                 (lambda (space) (setq selected (ecc-space-root space)))))
        (let ((ecc-layout 'spaces))
          (ecc-focus-project ecc-space-test--one))
        (should (equal selected ecc-space-test--one))))))

(provide 'ecc-space-test)

;;; ecc-space-test.el ends here
