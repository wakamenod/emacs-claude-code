;;; space-picker.el --- The Space picker of C-c c j, grouped  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of feat/space-picker-groups: `ecc-space-goto' (C-c c j)
;; offers the Spaces under `Open' and the projects of recordings under
;; `Past', each line drawn the way the sidebar draws its row -- the mark
;; of its state, its number, the tree line of a worktree -- and its
;; directory dimmed after it.  Only the name is matched.
;;
;; It builds a repository with two worktrees, a session in each, opens
;; the picker in the real configuration (vertico, here), types `feat' to
;; narrow it to the worktrees and quits.  The Past group is whatever the
;; machine's own recordings hold.
;;
;; Played by demo/scenes/space-picker.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-space)
(require 'ecc-worktree)

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el."
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "greet.py" demo-root))
  (delete-other-windows)
  nil)

(defun demo-start-session ()
  "Start a session in the project."
  (ecc-start demo-root)
  (demo-frame)
  nil)

(defun demo-start-worktree (branch)
  "Cut BRANCH beside the repository and start a session there."
  (let ((default-directory demo-root))
    (ecc-start-worktree branch))
  (demo-frame)
  nil)

(defun demo-report-picker ()
  "Say the lines the picker shows, as text, for the log."
  (let* ((spaces (ecc-space-list))
         (candidates (ecc-space--candidates spaces nil)))
    (dolist (line (ecc-space--affixes candidates spaces))
      (demo-say (format "picker: %s%s%s" (nth 1 line) (nth 0 line)
                        (nth 2 line)))))
  nil)

(defun demo-open-picker (typed)
  "Open the picker, type TYPED a while later, and quit a while after that.
Emacs does not answer the server while the minibuffer is open, so the
whole of it is put on timers before the step returns."
  (run-at-time 0.2 nil (lambda () (call-interactively #'ecc-space-goto)))
  (run-at-time 5 nil (lambda ()
                       (setq unread-command-events (string-to-list typed))))
  (run-at-time 10 nil (lambda ()
                        (setq unread-command-events
                              (listify-key-sequence (kbd "C-g")))))
  nil)

(defun demo-cleanup ()
  "Stop every session and remove every worktree this scene made."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (let ((default-directory demo-root))
    (dolist (line (split-string
                   (shell-command-to-string "git worktree list --porcelain") "\n" t))
      (when (string-prefix-p "worktree " line)
        (let ((path (substring line 9)))
          (unless (equal (file-name-as-directory path) (file-name-as-directory demo-root))
            (call-process "git" nil nil nil "worktree" "remove" "--force" path))))))
  (demo-say "Every session stopped and every worktree removed.")
  nil)

(provide 'space-picker)
;;; space-picker.el ends here
