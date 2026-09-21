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
  "Run BODY with git answering for a fixed repository of three projects.
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
          (ecc-space-test--tabs-was (frame-parameter nil 'ecc-space-tabs))
          (ecc-space--used nil)
          (ecc-space--implicit nil)
          (ecc-space--ensuring-parent nil)
          (ecc-space--closing nil)
          (sessions (mapcar (lambda (entry)
                              (ecc-model-create-session
                               :name (car entry) :project-root (cdr entry)))
                            ,spec)))
     (ignore sessions)
     ;; Which tab a Space is in lives on the frame, so a fresh table is
     ;; set rather than bound, and put back the way it was afterwards.
     (set-frame-parameter nil 'ecc-space-tabs nil)
     (unwind-protect
         (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                   ((symbol-function 'ecc-proc-send-json)
                    (lambda (_session object) object)))
           (ecc-space-test--with-git ,@body))
       (set-frame-parameter nil 'ecc-space-tabs ecc-space-test--tabs-was)
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
by watching which function is called.  `ecc-use-spaces' is on
throughout: `ecc-space-select' makes no tab without it.

`ecc-start' is stood in for: going to a Space with nothing running
starts a session there, and no test in this file is allowed to run a
CLI.  What it was asked for is in `ecc-space-test--started'."
  (declare (indent 0))
  `(let ((was tab-bar-mode)
         (ecc-use-spaces t)
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

(ert-deftest ecc-space-test-the-default-is-spaces ()
  "A Space per project is what the package does unless told otherwise.
Every harness in the suite says which layout it wants -- they have to,
or a tab made by one test turns up in the next -- so nothing else here
would notice the default changing."
  (should (custom-variable-p 'ecc-use-spaces))
  (should (eq (default-toplevel-value 'ecc-use-spaces) t))
  (should (eq (eval (car (get 'ecc-use-spaces 'standard-value)) t) t)))

(ert-deftest ecc-space-test-select-makes-no-tab-under-classic ()
  "Under `classic', going to a Space focuses the project and makes no tab.
Turning the tab bar on because somebody pressed a number in the
sidebar would be changing the layout behind their back."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (let ((ecc-use-spaces nil)
          (focused nil))
      (cl-letf (((symbol-function 'ecc-focus-project)
                 (lambda (root &rest _) (setq focused root))))
        (should-not (ecc-space-select (ecc-space-of-root ecc-space-test--one)))
        (should (equal focused ecc-space-test--one))
        (should-not (ecc-space--tabs))
        (should-not (bound-and-true-p tab-bar-mode))))
    ;; A Space with nothing running in it is shown rather than refused:
    ;; `ecc-focus-project' has no windows to deal out there.
    (let ((ecc-use-spaces nil)
          (ecc-space-test--started nil)
          (shown nil))
      (cl-letf (((symbol-function 'ecc-window--focus-source)
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

(defmacro ecc-space-test--with-hidden-tab-bar (&rest body)
  "Run BODY with `tab-bar-show\=' nil and the mode off, as a user may have it.
Tabs are made, named and switched all the same: what the mode draws is
the bar alone.  Otherwise this is `ecc-space-test--with-tab-bar\=', down
to standing in for `ecc-start\=' and closing the tabs afterwards -- and
the closing is quiet, tab-bar being exactly as talkative in a test as
it is anywhere else with the bar hidden."
  (declare (indent 0))
  `(let ((was tab-bar-mode)
         (tab-bar-show nil)
         (ecc-use-spaces t)
         (ecc-space-test--started nil))
     (unwind-protect
         (cl-letf (((symbol-function 'ecc-start)
                    (lambda (&optional root &rest _)
                      (push root ecc-space-test--started)
                      nil)))
           ,@body)
       (let ((inhibit-message t)
             (message-log-max nil))
         (dolist (tab (funcall tab-bar-tabs-function))
           (unless (eq (car tab) 'current-tab)
             (tab-bar-close-tab-by-name (alist-get 'name tab))))
         (tab-bar-rename-tab ""))
       (tab-bar-mode (if was 1 -1)))))

(ert-deftest ecc-space-test-select-leaves-the-tab-bar-alone ()
  "A Space is made and found again with the bar hidden and the mode off.
A tab is a named window configuration of the frame; `tab-bar-mode\='
only draws the bar above it, and whether that is drawn is
`tab-bar-show\=', which belongs to the user."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-hidden-tab-bar
      (let ((one (ecc-space-of-root ecc-space-test--one)))
        (should (equal (ecc-space-select one) "project-one"))
        (should-not (bound-and-true-p tab-bar-mode))
        (should (equal (ecc-space-current-key) ecc-space-test--one))
        ;; Found again by its name rather than made a second time.
        (should (equal (ecc-space-select one) "project-one"))
        (should (equal (length (funcall tab-bar-tabs-function)) 2))
        (should-not (bound-and-true-p tab-bar-mode))))))

(ert-deftest ecc-space-test-the-tabs-say-nothing ()
  "Moving between Spaces leaves none of tab-bar's own announcements behind.
With the bar hidden `tab-bar.el' messages on every tab added, renamed,
selected and closed -- it cannot show what it did, so it says it -- and
that is every move between Spaces told twice, once in somebody else's
words."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-hidden-tab-bar
      (let ((start (with-current-buffer (get-buffer-create "*Messages*")
                     (point-max))))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-space-select (ecc-space-of-root ecc-space-test--two))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'ecc-kill) #'ecc-model-remove-session))
          (ecc-space-close (ecc-space-of-root ecc-space-test--two)))
        (with-current-buffer "*Messages*"
          (should-not
           (string-match-p
            "Added new tab\\|Renamed tab\\|Selected tab\\|Deleted tab"
            (buffer-substring-no-properties start (point-max)))))))))

(ert-deftest ecc-space-test-the-tab-table-is-on-the-frame ()
  "Which tab a Space is in is kept on the frame, and closing it clears it.
A tab belongs to a frame, so a table for the whole Emacs said a Space
had a tab that the frame in front could not see.  Batch cannot make a
second frame; that the two frames keep their own tables, and that
closing a Space takes its tab off both, was verified by hand on
2026-09-17."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((one (ecc-space-of-root ecc-space-test--one)))
        (should-not (ecc-space--tabs))
        (ecc-space-select one)
        (should (equal (ecc-space--tabs)
                       (frame-parameter nil 'ecc-space-tabs)))
        (should (equal (alist-get ecc-space-test--one (ecc-space--tabs)
                                  nil nil #'equal)
                       "project-one"))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'ecc-kill) #'ecc-model-remove-session))
          (ecc-space-close one))
        (should-not (ecc-space--tabs))))))

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

(ert-deftest ecc-space-test-forget-closes-the-tab-and-the-space ()
  "A Space that is forgotten takes its tab and its place in the list with it.
This is what a removed worktree goes through: the sessions are gone
already, and a tab left behind would keep the Space in the sidebar with
nothing under it."
  (ecc-space-test--with-sessions `(("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let ((one (make-ecc-space :key ecc-space-test--one
                                 :root ecc-space-test--one
                                 :name "project-one")))
        (ecc-space-select one)
        (should (equal (ecc-space-tab one) "project-one"))
        (ecc-space-forget ecc-space-test--one)
        (should-not (ecc-space-tab one))
        (should-not (assoc ecc-space-test--one ecc-space--used))
        (should-not (tab-bar--tab-index-by-name "project-one"))
        (should (equal (ecc-space-test--roots) (list ecc-space-test--two)))))))

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
      (let ((ecc-use-spaces t)
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

(ert-deftest ecc-space-test-a-row-is-never-crushed-to-fit ()
  "A tab dealt more sessions than fit shows the ones that fit and no more.
The `enghi\\=' tab of 2026-09-22: seven sessions in a Space, and a new
tab came up with five of them two columns wide.  The rightmost window
was being widened to make room for the next split with `window-resize\\='
told to ignore every minimum, which took the transcripts beside it
down to `window-safe-min-width\\=' one after another.  The row has room
for two columns here -- 52 columns beside the sidebar, 40 of them the
first session\\='s -- and two is what it gets."
  (ecc-space-test--with-sessions `(("enghi" . ,ecc-space-test--one)
                                   ("fable" . ,ecc-space-test--one)
                                   ("impl" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one)
                                   ("three" . ,ecc-space-test--one)
                                   ("four" . ,ecc-space-test--one)
                                   ("five" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-code
        (let ((ecc-window-width 40)
              (ecc-space-session-min-width 15))
          (ecc-space-select (ecc-space-of-root ecc-space-test--one))
          (let ((row (ecc-space--session-windows)))
            (should (= 2 (length row)))
            (dolist (window row)
              (should (>= (window-total-width window)
                          (ecc-space--column-width))))
            ;; The two most recently used, and the other five running
            ;; with no window rather than in a sliver each.
            (should (equal (mapcar (lambda (window)
                                     (ecc-session-name
                                      (ecc-window-buffer-session
                                       (window-buffer window))))
                                   row)
                           '("five" "four")))
            (should (= 5 (seq-count (lambda (session)
                                      (not (get-buffer-window
                                            (ecc-session-buffer session))))
                                    sessions)))))))))

(ert-deftest ecc-space-test-the-row-gives-what-it-can-spare ()
  "A new column is paid for by the transcripts that have room, in proportion.
Three sessions in a 70-column row with columns of 15: the rightmost
has 17 and needs 30 before it can be divided.  The 13 it is short come
from the other two -- 12 from the one with 20 to spare and 1 from the
one with 3 -- and none from the source, which keeps its 10.  Nothing
ends under 15."
  (ecc-space-test--with-sessions `(("a" . ,ecc-space-test--one)
                                   ("b" . ,ecc-space-test--one)
                                   ("c" . ,ecc-space-test--one)
                                   ("d" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-code
        (let ((ecc-window-width 70)
              (ecc-space-session-min-width 15))
          (ecc-space-select (ecc-space-of-root ecc-space-test--one))
          (ecc-sidebar-hide)
          (delete-other-windows)
          ;; The sessions were made in this order, oldest first, and
          ;; are shown in it: each new one divides the rightmost.  The
          ;; row is `ecc-window-width' wide whatever the frame is, so
          ;; only the session windows are compared: the source is
          ;; whatever the frame leaves, and one test before this one
          ;; leaves the batch frame wider than it found it.
          (cl-flet ((row ()
                      (seq-filter (lambda (entry)
                                    (string-prefix-p "*ecc: " (car entry)))
                                  (ecc-space-test--layout))))
            (dolist (session (butlast sessions))
              (ecc-space-display-session session))
            (should (equal (row) '(("*ecc: a*" . 35) ("*ecc: b*" . 18)
                                   ("*ecc: c*" . 17))))
            (let* ((source (ecc-space--source-window))
                   (width (window-total-width source)))
              (ecc-space-display-session (car (last sessions)))
              (should (equal (row) '(("*ecc: a*" . 23) ("*ecc: b*" . 17)
                                     ("*ecc: c*" . 15) ("*ecc: d*" . 15))))
              (should (eq source (ecc-space--source-window)))
              (should (= width (window-total-width source))))))))))


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
      (let ((ecc-use-spaces t)
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
      (let ((ecc-use-spaces t)
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
      (let ((ecc-use-spaces t)
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
`ecc-space-reset-windows\=' is the way back, and it is a command with a
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

(ert-deftest ecc-space-test-the-source-of-a-space-can-be-put-back ()
  "`ecc-window--focus-source\=' puts the code of the root it is given back.
The half of focusing a project that `ecc-focus-project\=' and the
`classic\=' side of `ecc-space-select\=' are built on.  It takes the root
rather than working one out: the buffer in front of the user is the
very thing being complained about -- a window of this tab showing
another project -- and reading the project off it would answer with the
project being asked about."
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
        ;; Not a command any more: `C-c c V' is `ecc-space-reset-windows',
        ;; which puts the whole arrangement back rather than this window.
        (should-not (commandp 'ecc-window--focus-source))
        (ecc-space-select one)
        (set-window-buffer (ecc-space--source-window) stranger)
        ;; Called from the window that holds the stranger, the way
        ;; `ecc-focus-project' calls it.
        (with-current-buffer stranger
          (ecc-window--focus-source ecc-space-test--one))
        (should (eq (window-buffer (ecc-space--source-window)) code))
        (dolist (buffer (list code stranger))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest ecc-space-test-a-session-too-wide-for-the-frame-leaves-the-sidebar-alone ()
  "A session asked to be wider than the frame has room for takes what there is.
The batch frame is 80 columns and the sidebar 28 of them, so a session
of 60 does not fit beside the source.  `display-buffer\\=' made it fit
with a resize told to ignore every minimum and every `preserve-size\\=',
which took the ten columns from the sidebar.  The width is capped at
what the divided window has to give, and the sidebar keeps its own."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-code
        (let ((ecc-window-width 60)
              (ecc-space-session-min-width 10))
          (ecc-space-select (ecc-space-of-root ecc-space-test--one))
          (should (= ecc-sidebar-width
                     (window-total-width (ecc-sidebar--window))))
          (should (= 1 (length (ecc-space--session-windows))))
          (should (>= (window-total-width (ecc-space--source-window))
                      window-min-width)))))))

(ert-deftest ecc-space-test-a-new-tab-stops-when-the-row-is-full ()
  "The lay-out stops at the edge of the row rather than taking a window over.
A session that does not fit goes on running without one; the sidebar
and `ecc-space-reset-windows' bring it back."
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

;;;; Putting a Space back the way a new tab gets it

(defmacro ecc-space-test--with-code (&rest body)
  "Run BODY with a file of `ecc-space-test--one\\=' to read, killed afterwards.
These roots are names rather than directories, so there is nothing to
list either: without a buffer of the project there is no source for a
lay-out to put anywhere."
  (declare (indent 0))
  `(let ((code (get-buffer-create "code.el")))
     (unwind-protect
         (progn
           (with-current-buffer code
             (setq buffer-file-name
                   (expand-file-name "code.el" ecc-space-test--one)))
           ,@body)
       (with-current-buffer code (set-buffer-modified-p nil))
       (kill-buffer code))))

(defun ecc-space-test--wreck-the-tab ()
  "Give the source window to a transcript and put everything else away.
What `C-x 1' on a transcript leaves: a tab that is all transcript, with
no window to read the code in and nobody's arrangement in it."
  (let ((session (car (ecc-window-project-sessions ecc-space-test--one))))
    (set-window-buffer (ecc-window--source-window)
                       (ecc-session-ensure-buffer session))
    (delete-other-windows (get-buffer-window (ecc-session-buffer session)))))

(ert-deftest ecc-space-test-reset-stands-the-sessions-side-by-side-again ()
  "Resetting deals the tab again, by the rules it was dealt with."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-code
        (let ((ecc-window-width 60)
              (ecc-space-session-min-width 10))
          (ecc-space-select (ecc-space-of-root ecc-space-test--one))
          (ecc-space-test--wreck-the-tab)
          (should-not (ecc-space--source-window))
          (ecc-space-reset-windows)
          (let ((row (mapcar (lambda (window)
                               (ecc-session-name
                                (ecc-window-buffer-session
                                 (window-buffer window))))
                             (ecc-space--session-windows))))
            ;; The same row a new tab comes up with: most recently used
            ;; first, nothing stacked, the source to the left of them.
            (should (equal row '("two" "one")))
            (should (apply #'= (mapcar (lambda (w) (nth 1 (window-edges w)))
                                       (ecc-space--session-windows))))
            (should (< (nth 0 (window-edges (ecc-space--source-window)))
                       (nth 0 (window-edges
                               (car (ecc-space--session-windows))))))
            ;; And point is where a new tab leaves it, in the code.
            (should (eq (selected-window) (ecc-space--source-window)))))))))

(ert-deftest ecc-space-test-reset-stops-when-the-row-is-full ()
  "Resetting stops at the edge of the row rather than taking a window over."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one)
                                   ("three" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-code
        (let ((ecc-window-width 60)
              (ecc-space-session-min-width (frame-width)))
          (ecc-space-select (ecc-space-of-root ecc-space-test--one))
          (ecc-space-test--wreck-the-tab)
          (ecc-space-reset-windows)
          (should (= 1 (length (ecc-space--session-windows))))
          (should (equal "three"
                         (ecc-session-name
                          (ecc-window-buffer-session
                           (window-buffer
                            (car (ecc-space--session-windows)))))))
          ;; The two that did not fit are running with no window.
          (dolist (name '("one" "two"))
            (let ((session (seq-find (lambda (one)
                                       (equal (ecc-session-name one) name))
                                     (ecc-model-sessions))))
              (should session)
              (should-not (get-buffer-window
                           (ecc-session-ensure-buffer session))))))))))

(ert-deftest ecc-space-test-reset-leaves-the-sidebar-alone ()
  "The sidebar keeps its place and its width, and a hidden one comes back.
It is a side window that asked not to be deleted, which is what
`delete-other-windows\\=' honours -- and a new tab has a sidebar, which
is the arrangement this command promises."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-code
        (let ((ecc-window-width 60)
              (ecc-space-session-min-width 10))
          (ecc-space-select (ecc-space-of-root ecc-space-test--one))
          (ecc-sidebar-show)
          (let* ((side (ecc-sidebar--window))
                 (width (window-total-width side)))
            (should side)
            (ecc-space-test--wreck-the-tab)
            (ecc-space-reset-windows)
            (should (window-live-p (ecc-sidebar--window)))
            (should (eq (window-parameter (ecc-sidebar--window) 'window-side)
                        'left))
            (should (= width (window-total-width (ecc-sidebar--window))))
            (should (= 2 (length (ecc-space--session-windows)))))
          ;; Hidden, it comes back: a new tab has one.
          (ecc-sidebar-hide)
          (should-not (ecc-sidebar--window))
          (ecc-space-reset-windows)
          (should (ecc-sidebar--window)))))))

(ert-deftest ecc-space-test-reset-forgets-the-zoom ()
  "The way back a zoom left behind goes with the arrangement it led to."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-code
        (let ((ecc-window-width 60)
              (ecc-space-session-min-width 10))
          (unwind-protect
              (progn
                (ecc-space-select (ecc-space-of-root ecc-space-test--one))
                (ecc-sidebar-hide)
                (ecc-space-zoom)
                (should (alist-get (ecc-window--layout-key)
                                   (frame-parameter nil 'ecc-space-zoom)
                                   nil nil #'equal))
                (ecc-space-reset-windows)
                (should-not (alist-get (ecc-window--layout-key)
                                       (frame-parameter nil 'ecc-space-zoom)
                                       nil nil #'equal))
                ;; So the next zoom zooms, rather than putting back the
                ;; arrangement that was thrown away.  The sidebar is not
                ;; counted: the reset brought it back and zooming cannot
                ;; take it down.
                (should (cdr (ecc-space--session-windows)))
                (ecc-space-zoom)
                (should-not (seq-remove
                             (lambda (window)
                               (window-parameter window 'window-side))
                             (cdr (window-list nil 'no-minibuffer)))))
            (set-frame-parameter nil 'ecc-space-zoom nil)))))))

(ert-deftest ecc-space-test-reset-is-a-spaces-command ()
  "Under `classic' there is no Space to deal, and it says so."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (let ((ecc-use-spaces nil))
      (should-error (ecc-space-reset-windows) :type 'user-error))
    (ecc-space-test--with-tab-bar
      ;; `spaces', but this tab is nobody's Space.
      (set-frame-parameter nil 'ecc-space-tabs nil)
      (should-error (ecc-space-reset-windows) :type 'user-error))))

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
                                      ;; A worktree that is gone has
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
            (let ((ecc-use-spaces t)
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
      (let ((ecc-use-spaces t))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (with-temp-buffer
          ;; A buffer behind no file says nothing, so the tab is asked.
          (should (equal (ecc-window-context-project-root)
                         ecc-space-test--one))
          ;; And with `classic' it is not, whatever tab is showing.
          (let ((ecc-use-spaces nil)
                (default-directory "/tmp/elsewhere/"))
            (should (equal (ecc-window-context-project-root)
                           "/tmp/elsewhere/"))))))))

(ert-deftest ecc-space-test-display-session-goes-through-the-space ()
  "`ecc-display-session' hands over to the Space layout when asked to."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (let ((shown nil))
      (cl-letf (((symbol-function 'ecc-space-display-session)
                 (lambda (session) (setq shown session) 'window)))
        (let ((ecc-use-spaces t))
          (should (eq (ecc-display-session (car sessions)) 'window))
          (should (eq shown (car sessions))))
        ;; `classic' never reaches it.
        (setq shown nil)
        (let ((ecc-use-spaces nil)
              (ecc-window-use-side-window nil))
          (ecc-display-session (car sessions))
          (should-not shown))))))

(ert-deftest ecc-space-test-focus-project-selects-the-space ()
  "With `spaces', focusing a project is going to its tab."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (let ((selected nil))
      (cl-letf (((symbol-function 'ecc-space-select)
                 (lambda (space) (setq selected (ecc-space-root space)))))
        (let ((ecc-use-spaces t))
          (ecc-focus-project ecc-space-test--one))
        (should (equal selected ecc-space-test--one))))))

;;;; The repository a worktree hangs under

(defmacro ecc-space-test--with-worktrees (repo work &rest body)
  "Run BODY with REPO and WORK bound to a repository and a worktree of it.
Real directories, both: a worktree that is not there is one
`ecc-space--ensure-parent' leaves alone, so the case cannot be made
with a path that stands for nothing.  git is stood in for all the
same -- no repository is created."
  (declare (indent 2))
  `(let* ((,repo (file-name-as-directory (make-temp-file "ecc-space-repo" t)))
          (,work (file-name-as-directory (make-temp-file "ecc-space-work" t))))
     (unwind-protect
         (cl-letf (((symbol-function 'ecc-worktree-main)
                    (lambda (root) (and (equal root ,work) ,repo)))
                   ((symbol-function 'ecc-worktree-branch)
                    (lambda (root)
                      (if (equal root ,work) "worktree/feat-x" "main"))))
           ,@body)
       (delete-directory ,repo t)
       (delete-directory ,work t))))

(ert-deftest ecc-space-test-a-worktree-opens-its-repository-too ()
  "Opening a worktree opens the repository it came from, behind it.
A worktree with no repository on the screen is a child with nothing to
hang under; this is herdr's `ensure_source_parent_membership'."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-worktrees repo work
        (let ((space (ecc-space-of-root work)))
          (ecc-space-select space)
          ;; Both tabs are there, and the worktree is the one in front.
          (should (ecc-space-tab (ecc-space-of-root repo)))
          (should (ecc-space-tab space))
          (should (equal (ecc-space-current-key) work))
          ;; The repository was opened first and got a session of its
          ;; own, the worktree after it.
          (should (equal (reverse ecc-space-test--started) (list repo work)))
          ;; Nobody asked for the repository, and it says so.
          (should (member repo ecc-space--implicit))
          (should-not (member work ecc-space--implicit)))))))

(ert-deftest ecc-space-test-the-repository-is-not-opened-twice ()
  "A repository that has a Space already is left where it is."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-worktrees repo work
        (ecc-space-select (ecc-space-of-root repo))
        (setq ecc-space-test--started nil)
        (let ((tabs (length (funcall tab-bar-tabs-function))))
          (ecc-space-select (ecc-space-of-root work))
          ;; One tab more, not two, and nothing started in the
          ;; repository a second time.
          (should (= (1+ tabs) (length (funcall tab-bar-tabs-function))))
          (should (equal ecc-space-test--started (list work)))
          ;; The user opened it, so it is not ours to close again.
          (should-not (member repo ecc-space--implicit))
          ;; And coming back to the worktree makes no tab either.
          (ecc-space-select (ecc-space-of-root repo))
          (ecc-space-select (ecc-space-of-root work))
          (should (= (1+ tabs) (length (funcall tab-bar-tabs-function)))))))))

(ert-deftest ecc-space-test-a-worktree-whose-repository-is-gone-opens-alone ()
  "A worktree whose repository is not on the disk opens on its own."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-worktrees repo work
        (delete-directory repo t)
        (ecc-space-select (ecc-space-of-root work))
        (should (equal (ecc-space-current-key) work))
        (should (equal ecc-space-test--started (list work)))
        (should-not ecc-space--implicit)
        (should (= 2 (length (funcall tab-bar-tabs-function))))
        (make-directory repo t)))))

(ert-deftest ecc-space-test-the-repository-gets-no-session-when-told-not-to ()
  "With `ecc-space-always-session' off the repository is opened and left alone."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-worktrees repo work
        (let ((ecc-space-always-session nil))
          (ecc-space-select (ecc-space-of-root work))
          (should (ecc-space-tab (ecc-space-of-root repo)))
          (should (equal (ecc-space-current-key) work))
          (should-not ecc-space-test--started))))))

(ert-deftest ecc-space-test-a-worktree-under-classic-opens-nothing ()
  "Under `classic' there are no Spaces to open, the repository's included."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-worktrees repo work
      (let ((ecc-use-spaces nil)
            (ecc-space-test--started nil))
        (cl-letf (((symbol-function 'ecc-window--focus-source) #'ignore)
                  ((symbol-function 'ecc-focus-project) #'ignore)
                  ((symbol-function 'ecc-start)
                   (lambda (&optional root &rest _)
                     (push root ecc-space-test--started))))
          (ecc-space-select (ecc-space-of-root work))
          (should-not (ecc-space--tabs))
          (should-not ecc-space--implicit)
          (should-not ecc-space-test--started))))))

;;;; A Space that empties

(ert-deftest ecc-space-test-a-space-goes-with-its-last-session ()
  "A Space with nothing left in it closes, and another Space comes up."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (ecc-space-select (ecc-space-of-root ecc-space-test--two))
      (ecc-space-select (ecc-space-of-root ecc-space-test--one))
      (should (equal (ecc-space-current-key) ecc-space-test--one))
      (ecc-model-remove-session (car sessions))
      (should-not (tab-bar--tab-index-by-name "project-one"))
      (should-not (assoc ecc-space-test--one (ecc-space--tabs)))
      (should (equal (ecc-space-test--roots) (list ecc-space-test--two)))
      ;; The tab that closed was the one showing, so another Space is.
      (should (equal (ecc-space-current-key) ecc-space-test--two)))))

(ert-deftest ecc-space-test-a-space-with-a-session-left-keeps-its-tab ()
  "A Space is closed by its last session going, not by any of them."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("one-b" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-select (ecc-space-of-root ecc-space-test--one))
      (ecc-model-remove-session (car sessions))
      (should (tab-bar--tab-index-by-name "project-one"))
      (should (equal (ecc-space-current-key) ecc-space-test--one)))))

(ert-deftest ecc-space-test-an-exited-session-keeps-its-space ()
  "A session whose process died keeps its Space: `/resume' comes back to it."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (ecc-space-select (ecc-space-of-root ecc-space-test--one))
      (ecc-model-set-state (car sessions) 'exited)
      (run-hook-with-args 'ecc-session-exited-hook (car sessions) 0)
      (should (tab-bar--tab-index-by-name "project-one"))
      (should (ecc-space-tab (ecc-space-of-root ecc-space-test--one))))))

(ert-deftest ecc-space-test-a-session-of-nobody-closes-nothing ()
  "A recording, the usage probe and an inline question close no Space.
All three are kind `own' and all three belong to nobody: the probe has
no project of its own and lands in whatever directory was current."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (ecc-space-select (make-ecc-space :key ecc-space-test--one
                                        :root ecc-space-test--one
                                        :name "project-one"))
      (dolist (session
               (list (ecc-model-create-session
                      :name "past" :project-root ecc-space-test--one
                      :kind 'archived)
                     (ecc-model-create-session
                      :name "probe" :project-root ecc-space-test--one
                      :options '(:usage-probe t))))
        (ecc-model-remove-session session)
        (ecc-test-cleanup-session session)
        (should (tab-bar--tab-index-by-name "project-one")))
      (let ((inline (ecc-model-create-session
                     :name "inline" :project-root ecc-space-test--one)))
        (cl-letf (((symbol-function 'ecc-inline-session-p)
                   (lambda (session) (eq session inline))))
          (ecc-model-remove-session inline))
        (ecc-test-cleanup-session inline)
        (should (tab-bar--tab-index-by-name "project-one"))))))

(ert-deftest ecc-space-test-a-start-that-fails-keeps-its-tab ()
  "A session that never came up does not take the tab down with it.
`ecc-proc--start-failed' forgets a session the CLI refused, and the
Space being opened is empty again at that moment."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (let ((root (file-name-as-directory (make-temp-file "ecc-space" t))))
        (unwind-protect
            (cl-letf (((symbol-function 'ecc-start)
                       (lambda (&optional directory &rest _)
                         ;; What a failed start does: register, then
                         ;; forget again.
                         (let ((session (ecc-model-create-session
                                         :name "no" :project-root directory)))
                           (ecc-model-remove-session session)
                           (ecc-test-cleanup-session session)
                           nil))))
              (ecc-space-select (ecc-space-of-root root))
              (should (ecc-space-tab (ecc-space-of-root root))))
          (delete-directory root t))))))

(ert-deftest ecc-space-test-a-space-stays-for-its-source-when-told-to ()
  "With `ecc-space-always-session' off a Space lives on its source buffer.
It goes when the last buffer of the project goes, and not before."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let ((ecc-space-always-session nil))
        (ecc-space-select (ecc-space-of-root ecc-space-test--two))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-model-remove-session (car sessions))
        ;; Nothing is running there any more, and the Space stands.
        (should (tab-bar--tab-index-by-name "project-one"))
        (let ((buffer (generate-new-buffer "source.el")))
          (with-current-buffer buffer
            (setq buffer-file-name (expand-file-name
                                    "source.el" ecc-space-test--one)))
          (kill-buffer buffer))
        (should-not (tab-bar--tab-index-by-name "project-one"))
        (should-not (assoc ecc-space-test--one (ecc-space--tabs)))))))

(ert-deftest ecc-space-test-an-empty-space-starts-nothing-when-told-not-to ()
  "With `ecc-space-always-session' off, opening a Space starts nothing."
  (ecc-space-test--with-sessions `(("two" . ,ecc-space-test--two))
    (ecc-space-test--with-tab-bar
      (let ((ecc-space-always-session nil)
            (root (file-name-as-directory (make-temp-file "ecc-space" t))))
        (unwind-protect
            (progn
              (ecc-space-select (ecc-space-of-root root))
              (should-not ecc-space-test--started)
              (should (ecc-space-tab (ecc-space-of-root root))))
          (delete-directory root t))))))

;;;; Closing a Space, and the group under it

(ert-deftest ecc-space-test-closing-a-repository-closes-its-worktrees ()
  "A repository takes the worktrees drawn under it with it, and asks once.
The one question is about the sessions.  Nothing is offered about the
directories here because these stand for nothing on disk, which is what
`ecc-worktree-offer-group-removal' leaves out of its own question; the
test below makes real ones."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("work" . ,ecc-space-test--work))
    (ecc-space-test--with-tab-bar
      (let ((asked 0)
            (killed nil)
            (removed nil))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-space-select (ecc-space-of-root ecc-space-test--work))
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (cl-incf asked) t))
                  ((symbol-function 'ecc-kill)
                   (lambda (session)
                     (push (ecc-session-name session) killed)
                     (ecc-model-remove-session session)))
                  ((symbol-function 'ecc-worktree-remove)
                   (lambda (&rest _) (setq removed t))))
          (ecc-space-close (ecc-space-of-root ecc-space-test--one)))
        (should (= asked 1))
        (should (equal (sort killed #'string<) '("one" "work")))
        (should-not removed)
        (should-not (tab-bar--tab-index-by-name "project-one"))
        (should-not (tab-bar--tab-index-by-name "feat-x"))
        (should-not (ecc-space--tabs))))))

(ert-deftest ecc-space-test-closing-a-worktree-leaves-the-repository ()
  "A worktree closed on its own is the only Space that closes."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("work" . ,ecc-space-test--work))
    (ecc-space-test--with-tab-bar
      (ecc-space-select (ecc-space-of-root ecc-space-test--one))
      (ecc-space-select (ecc-space-of-root ecc-space-test--work))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'ecc-kill) #'ecc-model-remove-session))
        (ecc-space-close (ecc-space-of-root ecc-space-test--work)))
      (should-not (tab-bar--tab-index-by-name "feat-x"))
      (should (tab-bar--tab-index-by-name "project-one")))))

(ert-deftest ecc-space-test-closing-the-last-worktree-closes-a-repository-nobody-asked-for ()
  "A repository opened behind a worktree goes when the last worktree does.
One the user opened themselves stays: it was asked for."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-worktrees repo work
        (let ((ecc-space-always-session nil))
          (ecc-space-select (ecc-space-of-root work))
          (should (ecc-space-tab (ecc-space-of-root repo)))
          ;; The worktree is offered once the tabs are gone; this test
          ;; is about the tabs, so git is kept out of the answer.
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'ecc-worktree-remove) #'identity))
            (ecc-space-close (ecc-space-of-root work)))
          (should-not (ecc-space-tab (ecc-space-of-root work)))
          (should-not (ecc-space-tab (ecc-space-of-root repo)))
          ;; Now the same with a repository the user opened first.
          (ecc-space-select (ecc-space-of-root repo))
          (ecc-space-select (ecc-space-of-root work))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'ecc-worktree-remove) #'identity))
            (ecc-space-close (ecc-space-of-root work)))
          (should (ecc-space-tab (ecc-space-of-root repo))))))))

(ert-deftest ecc-space-test-closing-offers-the-worktrees-of-the-group ()
  "Closing a Space offers the worktrees that closed with it, in one question.
The Spaces are gone and nothing is left running in them, so this is the
moment somebody is thinking about the directories.  No leaves them
where they are."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (ecc-space-test--with-worktrees repo work
        (let ((ecc-space-always-session nil)
              (asked nil)
              (removed nil))
          (ecc-space-select (ecc-space-of-root work))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (prompt) (push prompt asked) nil))
                    ((symbol-function 'ecc-worktree-remove)
                     (lambda (path &rest _) (push path removed) path)))
            (ecc-space-close (ecc-space-of-root work)))
          (should (= 1 (length asked)))
          (should (string-match-p "Remove the worktree worktree/feat-x as well"
                                  (car asked)))
          (should-not removed)
          ;; And yes takes it.  The repository itself is never in the
          ;; question: it is nobody's worktree.
          (setq asked nil)
          (ecc-space-select (ecc-space-of-root repo))
          (ecc-space-select (ecc-space-of-root work))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (prompt) (push prompt asked) t))
                    ((symbol-function 'ecc-worktree-remove)
                     (lambda (path &rest _) (push path removed) path)))
            (ecc-space-close (ecc-space-of-root repo)))
          (should (= 1 (length asked)))
          (should (equal removed (list work))))))))

;;;; The windows of a session that is killed

(ert-deftest ecc-space-test-a-killed-session-takes-its-window-with-it ()
  "The window of a session that is killed is deleted, not filled with scratch."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("one-b" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let ((first (ecc-space-display-session (car sessions)))
              (second (ecc-space-display-session (nth 1 sessions))))
          (should (window-live-p first))
          (should (window-live-p second))
          (let ((windows (length (window-list nil 'no-minibuffer))))
            (ecc-model-remove-session (car sessions))
            (should-not (window-live-p first))
            (should (window-live-p second))
            (should (= (1- windows) (length (window-list nil 'no-minibuffer))))
            ;; And nothing was put in its place: the window is gone,
            ;; rather than left holding whatever was there before the
            ;; transcript.
            (should-not (get-buffer-window-list
                         (ecc-session-buffer (car sessions)) nil t))))))))

(ert-deftest ecc-space-test-closing-a-tab-keeps-the-window ()
  "A window with a tab line loses the tab, not itself.
Closing the tab of the session a window is showing moves it to the tab
beside it; the window keeps its place in the row."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10)
            (ecc-tab-line-mode t))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let* ((first (car sessions))
               (second (nth 1 sessions))
               ;; Both are tabs of the row; only the first is shown.
               (_ (ecc-session-ensure-buffer second))
               (window (ecc-space-display-session first))
               (windows (length (window-list nil 'no-minibuffer))))
          (ecc-model-remove-session first)
          (should (window-live-p window))
          (should (= windows (length (window-list nil 'no-minibuffer))))
          (should (eq (window-buffer window) (ecc-session-buffer second)))
          (should-not (get-buffer-window-list
                       (ecc-session-buffer first) nil t)))))))

(ert-deftest ecc-space-test-closing-the-last-tab-takes-the-window ()
  "With no tab left there is nothing for the window to show.
The window is deleted, as it is with no tab line at all: what the
deleting is there to avoid is a window left holding whatever was
underneath the transcript."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10)
            (ecc-tab-line-mode t))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let* ((first (car sessions))
               (second (nth 1 sessions))
               (_ (ecc-session-ensure-buffer second))
               (window (ecc-space-display-session first))
               (windows (length (window-list nil 'no-minibuffer))))
          (ecc-model-remove-session first)
          ;; One tab left, and the window is showing it.
          (should (window-live-p window))
          (should (eq (window-buffer window) (ecc-session-buffer second)))
          (ecc-test-cleanup-session first)
          (ecc-model-remove-session second)
          ;; And with that one gone there is no row to stay in.
          (should-not (window-live-p window))
          (should (= (1- windows) (length (window-list nil 'no-minibuffer)))))))))

(ert-deftest ecc-space-test-the-stream-window-is-taken-away-all-the-same ()
  "A stream buffer is no tab, so its window goes as it always did.
Only the transcript of a session is part of the row of tabs; the log of
the process behind it carries no tab line and has no neighbour to move
to."
  ;; Three of them: the tab the transcript moves to is not the only one
  ;; left, so a stream window asking the same question would be given
  ;; the third rather than deleted.
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one)
                                   ("three" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10)
            (ecc-tab-line-mode t))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let* ((first (car sessions))
               (second (nth 1 sessions))
               (stream (get-buffer-create " *ecc-space-test-stream*"))
               (_ (ecc-session-ensure-buffer second))
               (_ (ecc-session-ensure-buffer (nth 2 sessions)))
               (window (ecc-space-display-session first))
               (stream-window (split-window)))
          (unwind-protect
              (progn
                (setf (ecc-session-stream-buffer first) stream)
                (set-window-buffer stream-window stream)
                (ecc-model-remove-session first)
                ;; The transcript window stayed and took the tab beside it.
                (should (window-live-p window))
                (should (eq (window-buffer window) (ecc-session-buffer second)))
                ;; The window of the stream did not.
                (should-not (window-live-p stream-window)))
            (kill-buffer stream)))))))

(ert-deftest ecc-space-test-a-tab-on-the-screen-already-is-not-moved-to ()
  "A window does not move to a tab the window beside it is showing.
The transcripts of a Space stand side by side under one row of tabs, so
the tab next door is often already on the screen; moving to it would
put the same transcript in two windows.  With nothing else left to
show, the window that lost its tab goes."
  (ecc-space-test--with-sessions `(("one" . ,ecc-space-test--one)
                                   ("two" . ,ecc-space-test--one))
    (ecc-space-test--with-tab-bar
      (let ((ecc-window-width 60)
            (ecc-space-session-min-width 10)
            (ecc-tab-line-mode t))
        (ecc-space-select (ecc-space-of-root ecc-space-test--one))
        (ecc-sidebar-hide)
        (delete-other-windows)
        (let* ((first (car sessions))
               (second (nth 1 sessions))
               (one (ecc-space-display-session first))
               (two (ecc-space-display-session second))
               (windows (length (window-list nil 'no-minibuffer))))
          (ecc-model-remove-session first)
          (should-not (window-live-p one))
          (should (window-live-p two))
          (should (eq (window-buffer two) (ecc-session-buffer second)))
          (should (= (1- windows) (length (window-list nil 'no-minibuffer)))))))))

(ert-deftest ecc-space-test-the-last-window-gets-the-source-rather-than-scratch ()
  "A transcript alone in a Space that stays is replaced by the source.
The window cannot be deleted -- it would take the tab with it -- and a
Space kept alive by its source is one with a source to show.  With
`ecc-space-always-session' on the question does not arise: the Space
closes with its last session."
  (ecc-space-test--with-sessions nil
    (ecc-space-test--with-tab-bar
      (let* ((ecc-space-always-session nil)
             (root (file-name-as-directory (make-temp-file "ecc-space" t)))
             (session nil))
        (unwind-protect
            (progn
              (setq session (ecc-model-create-session
                             :name "one" :project-root root))
              (ecc-space-select (ecc-space-of-root root))
              (ecc-sidebar-hide)
              (delete-other-windows)
              (set-window-buffer (selected-window)
                                 (ecc-session-ensure-buffer session))
              (ecc-model-remove-session session)
              (should (= 1 (length (window-list nil 'no-minibuffer))))
              (should (equal (window-buffer (selected-window))
                             (ecc-space--source-buffer
                              (ecc-space-of-root root)))))
          (when session (ecc-test-cleanup-session session))
          (delete-directory root t))))))

(provide 'ecc-space-test)

;;; ecc-space-test.el ends here
