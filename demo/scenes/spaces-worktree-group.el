;;; spaces-worktree-group.el --- A repository behind every worktree  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of feat/worktree's Space changes, in the user's own
;; configuration: a worktree that opens the repository it came from, a
;; Space that closes when its last session goes, a repository that
;; closes the worktrees drawn under it, and the window of a killed
;; session going instead of being left to `*scratch*'.
;;
;; It starts real sessions -- five of them -- and sends none of them
;; anything: what is being shown is where the windows and the tabs go,
;; not what the model says.
;;
;; Played by demo/scenes/spaces-worktree-group.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-worktree)

(defvar demo-other-root "/tmp/ecc-demo-other/"
  "A second project, for the half of the setting that starts nothing.")

(defvar demo-sessions nil
  "The sessions this scene started, by name.")

;;;; The questions, answered without a minibuffer

;; Since 0.3.0 the offer to remove a worktree follows the last session
;; working in one wherever it goes -- and it is made from a timer, after
;; the step that stopped the session has already returned.  A `cl-letf'
;; around the step cannot catch that one, and an Emacs sitting at a
;; question nobody answers stops answering `emacsclient': every step
;; after it times out, and the recording is a frozen frame.  That is what
;; this scene did on release/0.3.0 until the override below (2026-09-17).
;;
;; The answers are the scene's own claims: the worktrees are left where
;; they are -- `ecc-remove-worktree' is what undoes one, and the scene
;; says so -- and everything else is agreed to.

(defun demo-answer (prompt)
  "Answer PROMPT, having put it on the screen long enough to read.
An override of `yes-or-no-p\=' for the whole of this Emacs.  A question
about removing a worktree is answered no: this scene closes Spaces and
stops sessions, and the checkouts it made stay on disk."
  (let ((answer (not (string-match-p "Remove the worktree" prompt))))
    (demo-say (concat prompt (if answer "yes" "no")))
    (sit-for 4)
    answer))

;;;; What the scene is played in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-use-spaces t)
  (setq ecc-space-always-session t)
  (setq demo-sessions nil)
  (advice-add 'yes-or-no-p :override #'demo-answer)
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-write "README.md" "# greet\n\nA greeting.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  ;; A second project of its own, used at the end.
  (delete-directory demo-other-root t)
  (make-directory demo-other-root t)
  (with-temp-file (expand-file-name "notes.md" demo-other-root)
    (insert "# notes\n\nA project to read rather than work in.\n"))
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc and which layout this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc-use-spaces = %S   ecc-space-always-session = %S   ecc from %s"
                    ecc-use-spaces ecc-space-always-session
                    (abbreviate-file-name (locate-library "ecc-space"))))
  nil)

;;;; Saying what the Spaces are

(defun demo-report-spaces ()
  "Say what Spaces there are, which is showing, and how they are drawn."
  (let* ((spaces (ecc-space-list))
         (current (ecc-space-current-key))
         (drawn (mapconcat
                 (lambda (space)
                   (format "%s%s%s"
                           (if (ecc-space-child-p space spaces) "  \\_ " "")
                           (ecc-space-name space)
                           (let ((n (length (ecc-space-sessions space))))
                             (format " (%d session%s)" n (if (= n 1) "" "s")))))
                 spaces " | ")))
    (demo-say (format "Spaces: %s      -- showing: %s      -- tabs: %d"
                      (if (string-empty-p drawn) "none" drawn)
                      (if current (ecc-space-name (ecc-space-of-root current)) "none")
                      (length (funcall tab-bar-tabs-function)))))
  nil)

(defun demo-report-windows ()
  "Say what the windows of this tab are showing."
  (demo-say (format "Windows here: %s"
                    (mapconcat (lambda (window)
                                 (buffer-name (window-buffer window)))
                               (window-list nil 'no-minibuffer) " | ")))
  nil)

(defun demo-report-implicit ()
  "Say which Spaces were opened on somebody else's account."
  (demo-say (format "Opened behind a worktree, so ours to close again: %s"
                    (or (mapconcat (lambda (key)
                                     (ecc-space-name (ecc-space-of-root key)))
                                   ecc-space--implicit " | ")
                        "none")))
  nil)

;;;; The steps

(defun demo-start-worktree (branch)
  "Check BRANCH out beside the demo project and start a session there.
The buffer and the directory are both pinned to `demo-root\=', and the
root the command works out is checked before it is let near git.  A step
arrives from `emacsclient\=' with `*scratch*\=' current, which has no
directory behind it, and `ecc-window-context-project-root\=' falls back
to `default-directory\=' -- the checkout the demo Emacs was started from.
That is the real repository, and a run of this scene cut two worktrees
in it before anybody noticed (2026-09-17)."
  (with-current-buffer (find-file-noselect
                        (expand-file-name "greet.py" demo-root))
    (let* ((default-directory demo-root)
           (root (ecc-worktree-context-root)))
      (unless (equal (file-truename root) (file-truename demo-root))
        (error "The demo would have worked in %s, not %s" root demo-root))
      (push (cons branch (ecc-start-worktree branch)) demo-sessions)))
  nil)

(defun demo-start-second-session ()
  "Start a second session in the repository, so its Space has two."
  (let ((default-directory demo-root))
    (push (cons "second" (ecc-start demo-root "second")) demo-sessions))
  nil)

(defun demo-kill-a-transcript-buffer ()
  "Kill the buffer of the session the repository's Space shows on the right.
The buffer, not the session: this is the case that used to leave
`*scratch*' standing where the transcript had been."
  (when-let* ((session (cdr (assoc "second" demo-sessions))))
    (kill-buffer (ecc-session-buffer session)))
  nil)

(defun demo-kill-session (name)
  "Stop the session called NAME, from Lisp, the way the sidebar's `k' would."
  (when-let* ((session (cdr (assoc name demo-sessions))))
    (ecc-kill session))
  nil)

(defun demo-goto-session-space (name)
  "Go to the Space of the session called NAME."
  (when-let* ((session (cdr (assoc name demo-sessions))))
    (ecc-space-select (ecc-space-of-root (ecc-session-project-root session))))
  nil)

(defun demo-goto-space (root)
  "Go to the Space of ROOT."
  (ecc-space-select (ecc-space-of-root root))
  nil)

(defun demo-close-space (root &optional _answer)
  "Close the Space of ROOT.  The questions it asks go to `demo-answer\='.
Called plainly.  `ecc-space-close\=' driven from a timer took the whole
Emacs down twice (2026-09-17): reading the minibuffer from a timer while
the tabs underneath it are being closed is not something to put on
camera, and the command itself is fine -- called like this, from
`emacsclient\=' or by hand, it closes the group and Emacs carries on.

The text on the screen is the question ecc really asks, held long
enough to read."
  (ecc-space-close (ecc-space-of-root root))
  nil)

;;;; The other half of the setting

(defun demo-turn-the-setting-off ()
  "Say what `ecc-space-always-session' nil means, and set it."
  (setq ecc-space-always-session nil)
  (demo-say "ecc-space-always-session = nil -- a Space to read in: nothing is started, and it lives on its source")
  nil)

(defun demo-open-the-other-project ()
  "Open a Space for a project nothing is running in."
  (ecc-space-select (ecc-space-of-root demo-other-root))
  nil)

(defun demo-kill-the-other-source ()
  "Kill the last buffer of that project, which is what closes its Space."
  (dolist (buffer (buffer-list))
    (when-let* ((directory (ecc-window-buffer-directory buffer)))
      (when (equal (ecc-window-project-key directory)
                   (ecc-window-project-key demo-other-root))
        (kill-buffer buffer))))
  nil)

(provide 'spaces-worktree-group)
;;; spaces-worktree-group.el ends here
