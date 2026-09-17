;;; worktree-removal-offer.el --- Asking about the worktree, wherever its Space ends  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of the removal offer, in the user's own configuration: a
;; worktree offered wherever its last session leaves -- by hand, from
;; Lisp, or with the Space it was in -- one question for a group closed
;; together, git's own second question on a worktree it does not find
;; clean, and a branch that is never taken with any of it.
;;
;; Every case is played on a real worktree with a real session in it,
;; and git is asked after each one, on camera, for what is left: `git
;; worktree list' and `git branch' are the only witnesses that matter.
;;
;; The questions are the ones ecc really asks.  What is stood in for is
;; the answering: `yes-or-no-p' is advised for the whole of this Emacs,
;; so that a question arriving from the timer -- which is how the offer
;; now reaches the user -- is put on the screen and answered without a
;; minibuffer.  Emacs does not answer the recorder while a minibuffer is
;; open, and half these questions do not come from a command at all.
;;
;; Played by demo/scenes/worktree-removal-offer.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-worktree)

(defvar demo-sessions nil
  "The sessions this scene started, by name.")

(defvar demo-answers nil
  "Alist of a regexp matching a question to the answer to give it.
The first match wins; a question that matches nothing is answered no.")

(defvar demo-asked nil
  "The questions that have been asked, newest first.")

(defvar demo-answer-pause 4
  "How long a question is held on the screen before it is answered.")

;;;; The questions, answered without a minibuffer

(defun demo-answer (prompt)
  "Answer PROMPT from `demo-answers', after putting it on the screen.
An override of `yes-or-no-p' for the whole of this Emacs, and not a
`cl-letf' around a step: the offer to remove a worktree is made from a
timer, which fires after the step that killed the session has already
returned."
  (let ((answer (cl-loop for (regexp . value) in demo-answers
                         when (string-match-p regexp prompt) return value)))
    (push prompt demo-asked)
    (demo-say (format "%s%s" prompt (if answer "yes" "no")))
    (sit-for demo-answer-pause)
    answer))

(defun demo-expect (&rest answers)
  "Take ANSWERS, a list of (REGEXP . ANSWER), as the answers to come.
The questions asked so far are forgotten with them, so that a step can
say how many were asked since."
  (setq demo-answers answers
        demo-asked nil)
  nil)

(defun demo-report-asked ()
  "Say what was asked since the last `demo-expect'."
  (demo-say (format "Questions asked: %d%s"
                    (length demo-asked)
                    (if demo-asked
                        (format "   -- %s" (string-join (reverse demo-asked)
                                                        " // "))
                      "   -- nothing was asked")))
  nil)

;;;; What the scene is played in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-layout 'spaces)
  (setq ecc-space-always-session t)
  (setq demo-sessions nil
        demo-answers nil
        demo-asked nil)
  (advice-add 'yes-or-no-p :override #'demo-answer)
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-write "README.md" "# greet\n\nA greeting.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (ecc-sidebar-show)
  (demo-say (format "ecc from %s   --   layout %S"
                    (abbreviate-file-name (locate-library "ecc-worktree"))
                    ecc-layout))
  nil)

;;;; What git and the model say

(defun demo-report-git ()
  "Say what worktrees and what branches the repository has."
  (let* ((trees (seq-remove #'ecc-worktree-entry-main-p
                            (ecc-worktree-list demo-root)))
         (names (mapcar (lambda (entry)
                          (file-name-nondirectory
                           (directory-file-name
                            (ecc-worktree-entry-path entry))))
                        trees)))
    (demo-say (format "git worktree list: %s      git branch: %s"
                      (if names (string-join names ", ") "(only the repository)")
                      (string-join (sort (ecc-worktree-branches demo-root)
                                         #'string<)
                                   ", "))))
  nil)

(defun demo-report-spaces ()
  "Say what Spaces there are and how many sessions each holds."
  (let ((spaces (ecc-space-list)))
    (demo-say (format "Spaces: %s"
                      (if (null spaces) "none"
                        (mapconcat
                           (lambda (space)
                             (format "%s%s (%d)"
                                     (if (ecc-space-child-p space spaces)
                                         "\\_ " "")
                                     (ecc-space-name space)
                                     (length (ecc-space-sessions space))))
                         spaces "  |  ")))))
  nil)

(defun demo-report-agents ()
  "Say which sessions the model still has, which is the sidebar's Agents list."
  (let ((names (mapcar #'ecc-session-name (ecc-model-sessions))))
    (demo-say (format "Agents: %s"
                      (if names (string-join names ", ") "none"))))
  nil)

;;;; Making a worktree, and working in it

(defun demo-worktree (branch)
  "Return the path of the worktree of BRANCH."
  (ecc-worktree-path demo-root branch))

(defun demo-start-worktree (branch)
  "Check BRANCH out beside the demo project and start a session there.
The buffer and the directory are both pinned to `demo-root\=', and the
root the command works out is checked before it is let near git: a step
arrives with `*scratch*\=' current, and a scene that asked for a worktree
cut two of them in the real repository before anybody noticed
\(2026-09-17)."
  (with-current-buffer (find-file-noselect
                        (expand-file-name "greet.py" demo-root))
    (let* ((default-directory demo-root)
           (root (ecc-worktree-context-root)))
      (unless (equal (file-truename root) (file-truename demo-root))
        (error "The demo would have worked in %s, not %s" root demo-root))
      (push (cons branch (ecc-start-worktree branch)) demo-sessions)))
  nil)

(defun demo-start-second-session (branch)
  "Start a second session in the worktree of BRANCH."
  (let* ((path (demo-worktree branch))
         (default-directory path))
    (push (cons (concat branch "-b") (ecc-start path (concat branch "-b")))
          demo-sessions))
  nil)

(defun demo-start-nested-session (branch)
  "Start a session in a repository of its own inside the worktree of BRANCH.
A submodule, a checkout nested in the tree: `project-current\=' answers
such a directory with itself, so the session is in none of the
worktree\='s own -- and used to be left in the model with its directory
deleted under it."
  (let* ((path (demo-worktree branch))
         (nested (expand-file-name "vendor/lib" path)))
    (make-directory nested t)
    (with-temp-file (expand-file-name "lib.py" nested) (insert "x = 1\n"))
    (call-process "git" nil nil nil "-C" nested "init" "-q")
    (let ((default-directory nested))
      (push (cons "nested" (ecc-start nested "nested")) demo-sessions)))
  nil)

;;;; Stopping things

(defun demo-settle (&optional seconds)
  "Wait SECONDS, so that the timer carrying the offer fires on camera.
The offer is scheduled where the session leaves the model and made from
a timer: a session can leave from inside the process that was running
it, which is no place to ask anybody anything."
  (sit-for (or seconds 3))
  nil)

(defun demo-kill-session (name)
  "Stop the session called NAME from Lisp, and wait for the offer."
  (when-let* ((session (cdr (assoc name demo-sessions))))
    (ecc-kill session))
  (demo-settle 6)
  nil)

(defun demo-close-space (root)
  "Close the Space of ROOT, group and all."
  (ecc-space-select (ecc-space-of-root root))
  (ecc-space-close (ecc-space-of-root root))
  (demo-settle 3)
  nil)

(defun demo-remove-worktree (branch)
  "Run `ecc-remove-worktree\=' on the worktree of BRANCH, as `C-c c ? M\=' does.
git\='s refusal is caught and put on the screen rather than left to
Emacs: saying no to the second question is a refusal that stands, and
the message it stands as is the thing worth reading."
  (condition-case error
      (ecc-remove-worktree (demo-worktree branch))
    (user-error (demo-say (error-message-string error))))
  (demo-settle 3)
  nil)

(defun demo-dirty (branch)
  "Leave a file git has never seen in the worktree of BRANCH."
  (let ((path (demo-worktree branch)))
    (with-temp-file (expand-file-name "notes.txt" path)
      (insert "something that was never committed\n"))
    (demo-say (format "%s now has a file git has never seen: notes.txt"
                      (file-name-nondirectory (directory-file-name path)))))
  nil)

(defun demo-goto-space (root)
  "Go to the Space of ROOT."
  (ecc-space-select (ecc-space-of-root root))
  nil)

(provide 'worktree-removal-offer)
;;; worktree-removal-offer.el ends here
