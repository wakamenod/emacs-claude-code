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

;;;; What the scene is played in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-layout 'spaces)
  (setq ecc-space-always-session t)
  (setq demo-sessions nil)
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
  (demo-say (format "ecc-layout = %S   ecc-space-always-session = %S   ecc from %s"
                    ecc-layout ecc-space-always-session
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
  "Check BRANCH out beside the repository and start a session there."
  (push (cons branch (ecc-start-worktree branch)) demo-sessions)
  nil)

(defun demo-start-second-session ()
  "Start a second session in the repository, so its Space has two."
  (push (cons "second" (ecc-start demo-root "second")) demo-sessions)
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

(defun demo-close-space (root &optional answer)
  "Close the Space of ROOT, answering its question with ANSWER.
The answer is typed into the question rather than queued before it.
Queued ahead of the call it was never read and the demonstration stood
at the prompt with nothing happening (2026-09-17); put there from
`minibuffer-setup-hook\=' it goes where a read that is already waiting
will take it.  A second and a half first, so the question can be read.

`use-short-answers\=' is asked because the answer has to be the one the
question wants: a `yes\=' typed at a y-or-n-p leaves `es\=' and a RET
behind, in whatever buffer comes next."
  (run-at-time
   0.2 nil
   (lambda ()
     (minibuffer-with-setup-hook
         (lambda ()
           (run-at-time
            1.5 nil
            (lambda ()
              (setq unread-command-events
                    (listify-key-sequence
                     (if (bound-and-true-p use-short-answers)
                         "y"
                       (concat (or answer "yes") "\r")))))))
       (ecc-space-close (ecc-space-of-root root)))))
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
