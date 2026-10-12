;;; ecc-sidebar-test.el --- Tests for ecc-sidebar  -*- lexical-binding: t; -*-

;;; Commentary:

;; What the sidebar draws, with two projects and a worktree between
;; them, and what its keys do.  Every case has two sessions or more:
;; the sidebar reaches across the whole of this Emacs, and the bugs
;; that matter there do not show up with one (CLAUDE.md).
;;
;; git is never run -- what it would say is bound -- and the spinner
;; and the blink are off, which is what makes the snapshot stable.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-sidebar)
(require 'ecc-worktree)
(require 'ecc-space)
(require 'ecc-session)

;;;; Helpers

(defconst ecc-sidebar-test--one "/tmp/project-one/")
(defconst ecc-sidebar-test--two "/tmp/project-two/")
(defconst ecc-sidebar-test--work "/tmp/project-one/.claude/worktrees/feat-x/")
(defconst ecc-sidebar-test--work-2 "/tmp/project-one/.claude/worktrees/feat-y/")

(defmacro ecc-sidebar-test--with-sidebar (spec &rest body)
  "Run BODY in the drawn sidebar, with a session in each root of SPEC.
SPEC is an alist of (NAME . ROOT); the sessions are made in order.  git
answers for a fixed repository in which `ecc-sidebar-test--work' is a
worktree of `ecc-sidebar-test--one'.  The buffer is current and drawn
when BODY runs, and everything is put back afterwards."
  (declare (indent 1))
  `(let* ((ecc-test-sent nil)
          (ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-window--project-root-cache (make-hash-table :test #'equal))
          (ecc-window--project-source-buffers nil)
          (ecc-window--last-source-buffer nil)
          (ecc-worktree--cache (make-hash-table :test #'equal))
          (ecc-sidebar-test--tabs-was (frame-parameter nil 'ecc-space-tabs))
          (ecc-space--used nil)
          (ecc-sidebar--collapsed nil)
          (ecc-sidebar-sessions-sort 'spaces)
          (ecc-use-spaces nil)
          (ecc-visual-enable-spinner nil)
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
                    (lambda (_session object) object))
                   ((symbol-function 'ecc-worktree-main)
                    (lambda (root)
                      (and (member root (list ecc-sidebar-test--work
                                              ecc-sidebar-test--work-2))
                           ecc-sidebar-test--one)))
                   ((symbol-function 'ecc-worktree-branch)
                    (lambda (root)
                      (cond ((equal root ecc-sidebar-test--work)
                             "worktree/feat-x")
                            ((equal root ecc-sidebar-test--work-2)
                             "worktree/feat-y")
                            ((equal root ecc-sidebar-test--one) "main")
                            (t "master"))))
                   ((symbol-function 'ecc-worktree-ahead-behind)
                    (lambda (root)
                      (and (equal root ecc-sidebar-test--one) '(2 . 0))))
                   ;; Going to a Space with nothing running starts a
                   ;; session there, and no test runs a CLI.
                   ((symbol-function 'ecc-start) (lambda (&rest _) nil)))
           (dolist (session sessions) (ecc-model-set-state session 'idle))
           (with-current-buffer (get-buffer-create ecc-sidebar-buffer-name)
             (unless (derived-mode-p 'ecc-sidebar-mode) (ecc-sidebar-mode))
             (ecc-sidebar-redraw)
             ,@body))
       (set-frame-parameter nil 'ecc-space-tabs ecc-sidebar-test--tabs-was)
       (mapc #'ecc-test-cleanup-session sessions)
       (when-let* ((buffer (get-buffer ecc-sidebar-buffer-name)))
         (kill-buffer buffer)))))

(defun ecc-sidebar-test--text ()
  "Return what the sidebar is showing, without the properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun ecc-sidebar-test--goto (name)
  "Put point on the row whose text holds NAME, failing when there is none."
  (goto-char (point-min))
  (unless (search-forward name nil t)
    (ert-fail (format "no row for %s in\n%s" name (ecc-sidebar-test--text))))
  (beginning-of-line))

;;;; What it draws

(ert-deftest ecc-sidebar-test-draws-both-sections ()
  "Two projects, a worktree under one of them, and a session waiting."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat" . ,ecc-sidebar-test--work)
                                    ("two" . ,ecc-sidebar-test--two))
    (ecc-model-set-state (nth 2 sessions) 'running)
    (ecc-test-add-request (car sessions) "Write")
    (ecc-test-add-request (car sessions) "Edit")
    (ecc-sidebar-redraw)
    (should (ecc-test-snapshot "sidebar" (ecc-sidebar-test--text)))))

(ert-deftest ecc-sidebar-test-a-worktree-is-named-by-its-branch ()
  "The child row carries the branch, indented, and no git line of its own."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat" . ,ecc-sidebar-test--work))
    (let ((text (ecc-sidebar-test--text)))
      ;; The parent says what branch it is on and how far from upstream.
      (should (string-match-p "^   main ↑2 ↓0$" text))
      ;; The child is named by its branch, on a tree line, and says no more.
      (should (string-match-p "^  └─ . \\[2\\] feat-x" text))
      (should-not (string-match-p "worktree/feat-x" text)))))

(ert-deftest ecc-sidebar-test-a-lone-worktree-says-its-branch-once ()
  "A worktree with no parent on the screen is not its own git line as well.
It is named after its branch already; repeating the branch under it
says nothing the second time."
  (ecc-sidebar-test--with-sidebar `(("feat" . ,ecc-sidebar-test--work))
    (let ((text (ecc-sidebar-test--text)))
      (should (string-match-p "^. \\[1\\] feat-x" text))
      ;; Once, on the row itself, and no dim line under it.
      (should (= 1 (cl-count "feat-x" (split-string text "\n")
                             :test (lambda (needle line)
                                     (string-match-p needle line)))))
      (should-not (string-match-p "^   feat-x" text)))))

(ert-deftest ecc-sidebar-test-marks-follow-the-sessions ()
  "A Space is marked with the loudest of what is running in it."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("one-b" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (should (string-match-p "^· \\[.\\] project-one$" (ecc-sidebar-test--text)))
    (ecc-model-set-state (nth 1 sessions) 'running)
    (ecc-sidebar-redraw)
    (should (string-match-p "^▶ \\[.\\] project-one$" (ecc-sidebar-test--text)))
    ;; Waiting for an answer wins over working.
    (ecc-test-add-request (car sessions) "Write")
    (ecc-sidebar-redraw)
    (should (string-match-p "^⚠ \\[.\\] project-one$" (ecc-sidebar-test--text)))
    ;; And the other project is untouched by any of it.
    (should (string-match-p "^· \\[.\\] project-two$" (ecc-sidebar-test--text)))))

(ert-deftest ecc-sidebar-test-waiting-is-counted ()
  "A session waiting on more than one request says how many."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (ecc-test-add-request (car sessions) "Write")
    (ecc-sidebar-redraw)
    (should (string-match-p "one +waiting$" (ecc-sidebar-test--text)))
    (ecc-test-add-request (car sessions) "Edit")
    (ecc-sidebar-redraw)
    (should (string-match-p "one +waiting ×2$" (ecc-sidebar-test--text)))))

(ert-deftest ecc-sidebar-test-rows-come-and-go-with-the-sessions ()
  "Starting and stopping a session is drawn without anybody asking."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (should (string-match-p "\\[2\\] project-one" (ecc-sidebar-test--text)))
    (let ((third (ecc-model-create-session :name "three"
                                           :project-root "/tmp/project-three/")))
      (unwind-protect
          (progn
            ;; The hook the model runs is what draws it, not the test.
            (ecc-model-set-state third 'idle)
            (should (string-match-p "\\[1\\] project-three"
                                    (ecc-sidebar-test--text)))
            (should (string-match-p "three" (ecc-sidebar-test--text))))
        (ecc-model-remove-session third)
        (ecc-test-cleanup-session third)))
    (ecc-sidebar-redraw)
    (should-not (string-match-p "project-three" (ecc-sidebar-test--text)))))

(ert-deftest ecc-sidebar-test-priority-order ()
  "With `priority', what wants an answer is at the top of the Sessions list."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two)
                                    ("three" . ,ecc-sidebar-test--work))
    (ecc-model-set-state (nth 1 sessions) 'running)
    (ecc-test-add-request (nth 2 sessions) "Write")
    (let ((ecc-sidebar-sessions-sort 'priority))
      (should (equal (mapcar #'ecc-session-name (ecc-sidebar--sessions))
                     '("three" "two" "one"))))
    ;; And by Space otherwise: the order of the list at the top.
    (should (equal (mapcar #'ecc-session-name (ecc-sidebar--sessions))
                   '("two" "one" "three")))))

;;;; The tree

(ert-deftest ecc-sidebar-test-worktrees-hang-on-a-tree-line ()
  "Every worktree is tied to its repository, and the last one closes the line."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat-x" . ,ecc-sidebar-test--work)
                                    ("feat-y" . ,ecc-sidebar-test--work-2))
    (let ((rows (seq-filter (lambda (line) (string-match-p "feat-" line))
                            (split-string (ecc-sidebar-test--text) "
"))))
      ;; The two rows of the Spaces list, and the two of the Sessions one.
      (should (= 4 (length rows)))
      (should (string-prefix-p "  ├─ " (nth 0 rows)))
      (should (string-prefix-p "  └─ " (nth 1 rows))))))

(ert-deftest ecc-sidebar-test-a-lone-worktree-closes-the-line-on-its-own ()
  "One worktree under a repository is the last one as well."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat" . ,ecc-sidebar-test--work))
    (should (string-match-p "^  └─ " (ecc-sidebar-test--text)))
    (should-not (string-match-p "├" (ecc-sidebar-test--text)))))

;;;; Folding


(ert-deftest ecc-sidebar-test-tab-folds-the-worktrees-away ()
  "TAB on a repository hides its worktrees, and shows them again."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat" . ,ecc-sidebar-test--work))
    (should (string-match-p "feat-x" (ecc-sidebar-test--text)))
    (ecc-sidebar-test--goto "project-one")
    (ecc-sidebar-toggle-children)
    (should-not (string-match-p "feat-x" (ecc-sidebar-test--text)))
    (ecc-sidebar-toggle-children)
    (should (string-match-p "feat-x" (ecc-sidebar-test--text)))))

(ert-deftest ecc-sidebar-test-the-space-one-is-in-is-never-folded-away ()
  "Folding a repository leaves the worktree being worked in on the screen."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat" . ,ecc-sidebar-test--work))
    (cl-letf (((symbol-function 'ecc-space-current)
               (lambda () (ecc-space-of-root ecc-sidebar-test--work))))
      (setq ecc-sidebar--collapsed (list ecc-sidebar-test--one))
      (ecc-sidebar-redraw)
      (should (string-match-p "feat-x" (ecc-sidebar-test--text))))))

(ert-deftest ecc-sidebar-test-only-a-repository-with-worktrees-has-an-arrow ()
  "The arrow says a row can be folded, and which way it stands."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat" . ,ecc-sidebar-test--work)
                                    ("two" . ,ecc-sidebar-test--two))
    (should (string-match-p "project-one +▾$" (ecc-sidebar-test--text)))
    ;; Nothing under the other project, and nothing under a worktree.
    (should-not (string-match-p "project-two.*▾" (ecc-sidebar-test--text)))
    (should-not (string-match-p "feat-x.*▾" (ecc-sidebar-test--text)))
    (ecc-sidebar-test--goto "project-one")
    (ecc-sidebar-toggle-children)
    (should (string-match-p "project-one +▸$" (ecc-sidebar-test--text)))))

(ert-deftest ecc-sidebar-test-a-folded-repository-answers-for-its-worktrees ()
  "With the rows away, the mark of the repository says a worktree is waiting."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("feat" . ,ecc-sidebar-test--work))
    (ecc-test-add-request (nth 1 sessions) "Write")
    (ecc-sidebar-redraw)
    ;; Unfolded, the repository says what it is doing and no more.
    (should (string-match-p "^· \\[.\\] project-one" (ecc-sidebar-test--text)))
    (ecc-sidebar-test--goto "project-one")
    (ecc-sidebar-toggle-children)
    (should-not (string-match-p "feat-x" (ecc-sidebar-test--text)))
    (should (string-match-p "^⚠ \\[.\\] project-one" (ecc-sidebar-test--text)))
    ;; And it is the repository's own mark again once it is unfolded.
    (ecc-sidebar-toggle-children)
    (should (string-match-p "^· \\[.\\] project-one" (ecc-sidebar-test--text)))))

;;;; The keys

(ert-deftest ecc-sidebar-test-return-goes-there ()
  "RET on a session shows it; RET on a Space goes to the project."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (let ((selected nil)
          (focused nil)
          (tabbed nil))
      (cl-letf (((symbol-function 'ecc-window-select-session)
                 (lambda (session) (setq selected session)))
                ;; The real `ecc-space-select' runs, so that what is
                ;; tested is the branch it takes.
                ((symbol-function 'ecc-focus-project)
                 (lambda (root &rest _) (setq focused root)))
                ((symbol-function 'ecc-space--select-tab)
                 (lambda (space) (setq tabbed (ecc-space-root space)))))
        ;; A session row.
        (ecc-sidebar-test--goto "· one")
        (ecc-sidebar-visit)
        (should (eq selected (car sessions)))
        ;; A Space row, under `classic': the old way of focusing, and
        ;; no tab made.
        (ecc-sidebar-test--goto "project-two")
        (ecc-sidebar-visit)
        (should (equal focused ecc-sidebar-test--two))
        (should-not tabbed)
        ;; And under `spaces': its tab, and nothing focused.
        (setq focused nil)
        (let ((ecc-use-spaces t))
          (ecc-sidebar-test--goto "project-one")
          (ecc-sidebar-visit))
        (should (equal tabbed ecc-sidebar-test--one))
        (should-not focused)))))

(ert-deftest ecc-sidebar-test-a-number-does-what-return-does ()
  "The number keys take the same path as RET, layout and all.
Under `classic' pressing 2 used to turn the tab bar on and make a tab,
where RET on the same row focused the project."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (let ((focused nil)
          (tabbed nil))
      (cl-letf (((symbol-function 'ecc-focus-project)
                 (lambda (root &rest _) (setq focused root)))
                ((symbol-function 'ecc-space--select-tab)
                 (lambda (space) (setq tabbed (ecc-space-root space))))
                ((symbol-function 'this-command-keys) (lambda () "1")))
        (ecc-sidebar-jump)
        (should (equal focused (ecc-space-root (car (ecc-space-list)))))
        (should-not tabbed)))))

(ert-deftest ecc-sidebar-test-n-and-p-skip-what-is-not-a-row ()
  "Moving passes over the headings and the git lines."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (goto-char (point-min))
    (ecc-sidebar-next-line)
    (should (ecc-space-p (ecc-sidebar--item-at-point)))
    (let ((first (ecc-sidebar--item-at-point)))
      (ecc-sidebar-next-line)
      ;; The line just passed over is the branch of the first Space.
      (should-not (ecc-sidebar--same-item-p (ecc-sidebar--item-at-point) first))
      (should (ecc-sidebar--item-at-point))
      (ecc-sidebar-previous-line)
      (should (ecc-sidebar--same-item-p (ecc-sidebar--item-at-point) first)))
    ;; Every row reached this way stands for something.
    (goto-char (point-min))
    (ecc-sidebar-next-line)
    (dotimes (_ 12)
      (ecc-sidebar-next-line)
      (should (ecc-sidebar--item-at-point))
      (should-not (get-text-property (line-beginning-position)
                                     'ecc-sidebar-detail)))))

(ert-deftest ecc-sidebar-test-a-redraw-leaves-point-where-it-was ()
  "Every line survives a redraw, the git line under a Space included.
It did not: a Space and its git line stand for the same Space, so point
on the git line came back a line higher.  With the spinner redrawing
several times a second, moving down onto one with `C-n' was impossible."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (let ((lines (count-lines (point-min) (point-max))))
      (should (> lines 6))
      (dotimes (n lines)
        (goto-char (point-min))
        (forward-line n)
        (let ((text (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (ecc-sidebar-redraw)
          (should (equal (line-number-at-pos) (1+ n)))
          (should (equal text (buffer-substring-no-properties
                               (line-beginning-position)
                               (line-end-position)))))))))

(ert-deftest ecc-sidebar-test-k-stops-the-session-at-point ()
  "`k' asks, and stops the session of the row it was typed on."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (let ((killed nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'ecc-kill)
                 (lambda (session) (setq killed session))))
        (ecc-sidebar-test--goto "· two")
        (ecc-sidebar-kill-session)
        (should (eq killed (nth 1 sessions)))))))

(ert-deftest ecc-sidebar-test-a-answers-the-session-at-point ()
  "`a' allows what the session of the row is waiting on, not somebody else's."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (ecc-test-add-request (car sessions) "Write")
    (ecc-test-add-request (nth 1 sessions) "Edit")
    (ecc-sidebar-redraw)
    (let ((allowed nil))
      (cl-letf (((symbol-function 'ecc-perm-allow-request)
                 (lambda (request) (setq allowed request))))
        (let ((ecc-answer-confirm nil))
          (ecc-sidebar-test--goto "⚠ two")
          (ecc-sidebar-allow)
          (should (eq allowed (car (ecc-session-pending (nth 1 sessions)))))
          ;; The one waiting on the other session is untouched.
          (should-not (eq allowed (car (ecc-session-pending (car sessions))))))))))

(ert-deftest ecc-sidebar-test-a-and-d-leave-the-excluded-tools-alone ()
  "A tool of `ecc-answer-exclude-tools' is not answered from a row.
`ecc-answer-allow' and `ecc-answer-deny' skip those tools wherever they
are asked from, the point being that a shell command is read whole
before it is answered; the sidebar has a row and a one line summary and
was answering them all the same."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (ecc-test-add-request (nth 1 sessions) "Bash"
                          '((command . "rm -rf /tmp/somewhere")))
    (ecc-sidebar-redraw)
    (let ((answered nil)
          (ecc-answer-confirm nil))
      (cl-letf (((symbol-function 'ecc-perm-allow-request)
                 (lambda (request) (setq answered request)))
                ((symbol-function 'ecc-perm-respond)
                 (lambda (request &rest _) (setq answered request))))
        (ecc-sidebar-test--goto "⚠ two")
        (should-error (ecc-sidebar-allow) :type 'user-error)
        (should-error (ecc-sidebar-deny "") :type 'user-error)
        (should-not answered)
        ;; The request is still there to be answered where it can be read.
        (should (car (ecc-session-pending (nth 1 sessions))))))))

(ert-deftest ecc-sidebar-test-a-answers-a-question-too ()
  "`a' takes whatever kind the session is waiting on.
`ecc-perm-allow-request' approves a plan and opens a question in the
buffer it is answered in.  `a' used to refuse both while `d' denied
them, so a session waiting on a question could be turned down from the
sidebar but not answered."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (let* ((session (nth 1 sessions))
           (node (ecc-model-add-node session :type 'question :status 'pending))
           (request (make-ecc-request :request-id "q-1" :session session
                                      :kind 'question :created-at (current-time)
                                      :node node)))
      (ecc-model-node-put node 'request request)
      (ecc-model-add-request session request)
      (ecc-sidebar-redraw)
      (let ((allowed nil)
            (ecc-answer-confirm nil))
        (cl-letf (((symbol-function 'ecc-perm-allow-request)
                   (lambda (request) (setq allowed request))))
          (ecc-sidebar-test--goto "⚠ two")
          (ecc-sidebar-allow)
          (should (eq allowed request)))))))

(ert-deftest ecc-sidebar-test-x-on-a-row-with-nothing-refuses ()
  "A key that wants a Space says so rather than acting on the wrong one."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (goto-char (point-min))            ; the Spaces heading
    (should-error (ecc-sidebar-close-space) :type 'user-error)
    (should-error (ecc-sidebar-kill-session) :type 'user-error)
    ;; And `X' refuses a Space that is not a worktree.
    (ecc-sidebar-test--goto "project-two")
    (should-error (ecc-sidebar-remove-worktree) :type 'user-error)))

;;;; The window

(ert-deftest ecc-sidebar-test-a-removed-worktree-is-redrawn ()
  "The sidebar listens for a worktree going, not only for a session.
A worktree an offer removed -- the last session of one leaving, a group
closed together -- took its row with it only when something else
happened to redraw the sidebar; the row stood there pointing at a
directory that was gone."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one))
    (should (memq #'ecc-sidebar-redraw ecc-worktree-removed-hook))
    (let ((drawn 0))
      (cl-letf* ((redraw (symbol-function 'ecc-sidebar-redraw))
                 ((symbol-function 'ecc-sidebar-redraw)
                  (lambda (&rest arguments)
                    (cl-incf drawn)
                    (apply redraw arguments))))
        (run-hook-with-args 'ecc-worktree-removed-hook
                            ecc-sidebar-test--work)
        (should (= 1 drawn))))))

(ert-deftest ecc-sidebar-test-show-and-hide ()
  "The sidebar goes on the left, is never selected, and hides alone."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (delete-other-windows)
    (let* ((other (selected-window))
           (window (ecc-sidebar-show)))
      (should (window-live-p window))
      (should (eq (window-parameter window 'window-side) 'left))
      (should (window-parameter window 'no-other-window))
      (should-not (eq (selected-window) window))
      ;; `delete-other-windows' elsewhere leaves it standing.
      (select-window other)
      (delete-other-windows)
      (should (window-live-p window))
      (ecc-sidebar-hide)
      (should-not (window-live-p window))
      (should (buffer-live-p (get-buffer ecc-sidebar-buffer-name))))))

(ert-deftest ecc-sidebar-test-the-width-survives-the-frame-changing-size ()
  "The sidebar keeps its width when the frame is made wider or narrower.
Without a preserved size it is resized in proportion like any other
window, and since it draws `ecc-sidebar-width' columns whatever the
window measures, the rest of a widened one is blank."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (delete-other-windows)
    (let ((window (ecc-sidebar-show)))
      (should (= (window-total-width window) ecc-sidebar-width))
      (set-frame-width nil 200)
      (should (= (window-total-width window) ecc-sidebar-width))
      (set-frame-width nil 90)
      (should (= (window-total-width window) ecc-sidebar-width))
      ;; And one that is already too wide is put back by showing it
      ;; again, which is what recovers a sidebar widened before this.
      (window-preserve-size window t nil)
      (window-resize window 20 t)
      (should (> (window-total-width window) ecc-sidebar-width))
      (should (eq (ecc-sidebar-show) window))
      (should (= (window-total-width window) ecc-sidebar-width))
      (ecc-sidebar-hide))))

(ert-deftest ecc-sidebar-test-focus-goes-in-and-comes-back ()
  "`ecc-sidebar-focus' is the way in, and the same command is the way out.
`no-other-window' keeps `C-x o' out of the sidebar, which leaves its
keys unreachable without this."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (delete-other-windows)
    (let ((work (selected-window)))
      ;; It is not selected when it merely appears.
      (let ((window (ecc-sidebar-show)))
        (should-not (eq (selected-window) window))
        ;; And `other-window' will not go there, which is the point.
        (select-window work)
        (other-window 1)
        (should-not (eq (selected-window) window))
        ;; The way in, and point lands on a row rather than the heading.
        (select-window work)
        (ecc-sidebar-focus)
        (should (eq (selected-window) window))
        (should (ecc-sidebar--item-at-point))
        ;; And the way out.
        (ecc-sidebar-focus)
        (should (eq (selected-window) work))
        (ecc-sidebar-hide)))))

(ert-deftest ecc-sidebar-test-focus-shows-it-first ()
  "Asking to go into a sidebar that is not up puts it up."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (delete-other-windows)
    (should-not (ecc-sidebar--window))
    (ecc-sidebar-focus)
    (should (ecc-sidebar--window))
    (should (eq (selected-window) (ecc-sidebar--window)))
    (ecc-sidebar-hide)))

(ert-deftest ecc-sidebar-test-closing-keys-grow-with-what-they-close ()
  "`k' stops a session, `K' removes a worktree, `X' closes a Space.
`X' is the menu's key for closing a Space; the sidebar had it on `x'
and `X' on the worktree, so the same letter closed two different
things depending on which list was in front."
  (should (eq (lookup-key ecc-sidebar-mode-map (kbd "k")) #'ecc-sidebar-kill-session))
  (should (eq (lookup-key ecc-sidebar-mode-map (kbd "K")) #'ecc-sidebar-remove-worktree))
  (should (eq (lookup-key ecc-sidebar-mode-map (kbd "X")) #'ecc-sidebar-close-space))
  (should-not (lookup-key ecc-sidebar-mode-map (kbd "x"))))

(provide 'ecc-sidebar-test)

;;; ecc-sidebar-test.el ends here

(ert-deftest ecc-sidebar-test-a-row-fits-the-window-it-is-drawn-in ()
  "No row is wider than the text of the sidebar window.
`ecc-sidebar-width' is the window's total width, fringes included, so a
row filled to it overflows the body and the right end of every row --
the state a session is waiting in -- is drawn as a truncation arrow."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (delete-other-windows)
    (let ((window (ecc-sidebar-show)))
      (ecc-model-set-state (nth 1 sessions) 'running)
      (ecc-sidebar-redraw)
      (with-current-buffer (get-buffer ecc-sidebar-buffer-name)
        (dolist (line (split-string (buffer-string) "\n"))
          (should (<= (string-width line) (window-body-width window)))))
      (ecc-sidebar-hide))))

;;;; The spinner

(ert-deftest ecc-sidebar-test-the-tick-draws-the-frame-alone ()
  "A tick of the spinner replaces the frame in place and draws nothing else.
Drawing the whole sidebar five times a second is what took Emacs down
once the markers of the buffer had piled up; undo is off in the buffer
for the same reason, a redraw being nothing to undo."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (should (eq buffer-undo-list t))
    (let ((ecc-visual-enable-spinner t)
          (ecc-visual--tick 0))
      (ecc-model-set-state (nth 1 sessions) 'running)
      (ecc-sidebar-test--goto "two")
      (let ((before (ecc-sidebar-test--text))
            (point (point))
            (old (ecc-visual-spinner-frame)))
        (should (string-search old before))
        (cl-letf (((symbol-function 'ecc-sidebar-redraw)
                   (lambda (&rest _) (error "The tick drew the sidebar again")))
                  ((symbol-function 'ecc-sidebar--visible-p) (lambda () t)))
          (ecc-sidebar--spinner-tick))
        (let ((new (ecc-visual-spinner-frame)))
          (should-not (equal old new))
          (should (equal (ecc-sidebar-test--text) (string-replace old new before)))
          (should (= (point) point))
          ;; The row still says what it stands for: the properties of
          ;; the frame went over with it.
          (should (ecc-sidebar--item-at-point)))))))

(ert-deftest ecc-sidebar-test-a-redraw-leaves-no-marker-behind ()
  "Drawing the sidebar calls nothing that makes a marker.
`match-data' after a search in a buffer makes a marker per group in
that buffer, and an Emacs slow to collect them walks every one at
every insertion, in every buffer they were left in."
  (ecc-sidebar-test--with-sidebar `(("one" . ,ecc-sidebar-test--one)
                                    ("two" . ,ecc-sidebar-test--two))
    (let ((makers '(match-data make-marker copy-marker point-marker))
          (calls nil))
      (dolist (maker makers)
        (advice-add maker :before (lambda (&rest _) (push maker calls))
                    '((name . ecc-sidebar-test-count))))
      ;; Advising a primitive compiles a trampoline for it, and the
      ;; compiler saves match data of its own: only what comes after
      ;; counts.
      (setq calls nil)
      (unwind-protect
          (progn
            ;; A search in a buffer first: it is what `match-data' would
            ;; then answer with markers.
            (with-temp-buffer (insert "abc") (goto-char (point-min))
                              (re-search-forward "b"))
            (ecc-model-set-state (nth 1 sessions) 'running)
            (ecc-sidebar-redraw))
        (dolist (maker makers)
          (advice-remove maker 'ecc-sidebar-test-count)))
      (should-not calls))))
