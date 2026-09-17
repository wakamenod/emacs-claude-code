;;; reset-and-sidebar.el --- Putting a Space back, and the sidebar's keys  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-space-reset-windows' (C-c c V, V in the menu) and the sidebar
;; of 0.3.0.  Three real sessions are started in one project, the
;; windows of the Space are then pulled apart the way a morning's work
;; pulls them apart -- split, zoomed, given over to one transcript,
;; with the sidebar put away -- and the key deals them out again.
;;
;; Then the sidebar itself: n and p, TAB on a repository, RET, the
;; numbers, g and q.
;;
;; Played by demo/scenes/reset-and-sidebar.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-worktree)

(defvar demo-sessions nil "The sessions this scene started, newest first.")
(defvar demo-source "greet.py" "The file the Space is opened on.")
(defvar demo-other "notes.md" "A second file, for a window that is not a transcript.")

(defun demo-scene-build ()
  "Build the project.  Called by demo.el once there is a frame."
  (demo-fresh-repository)
  (demo-write demo-source "def greet(name):\n    return \"hi \" + name\n")
  (demo-write demo-other "# notes\n\n- one\n- two\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name demo-source demo-root))
  (demo-say (format "ecc from %s · ecc-use-spaces %s"
                    (abbreviate-file-name (locate-library "ecc"))
                    ecc-use-spaces))
  nil)

;;;; What is on the screen

(defun demo-window-line ()
  "Return one line naming the windows of this tab and their widths."
  (mapconcat (lambda (window)
               (format "%s(%d)"
                       (buffer-name (window-buffer window))
                       (window-total-width window)))
             (window-list nil 'never)
             " | "))

(defun demo-report-windows ()
  "Say what the windows of this tab are."
  (demo-say (format "Windows: %s" (demo-window-line)))
  nil)

(defun demo-report-spaces ()
  "Say what the Spaces are, which is showing, and whether the sidebar is up."
  (let ((spaces (ecc-space-list)))
    (demo-say (format "Spaces: %s · showing: %s · sidebar: %s"
                      (mapconcat
                       (lambda (space)
                         (format "%s%s (%d)"
                                 (if (ecc-space-child-p space spaces) "\\_ " "")
                                 (ecc-space-name space)
                                 (length (ecc-space-sessions space))))
                       spaces " | ")
                      (if-let* ((key (ecc-space-current-key)))
                          (ecc-space-name (ecc-space-of-root key))
                        "none")
                      (if (ecc-sidebar--visible-p) "shown" "hidden"))))
  nil)

;;;; Three sessions

(defun demo-start-session (name)
  "Start a real session called NAME in the project."
  (push (ecc-start demo-root name) demo-sessions)
  (demo-frame)
  nil)

;;;; Pulling the Space apart

(defun demo-mess-it-up ()
  "Do to the windows what a morning's work does to them."
  (when-let* ((session (car (last demo-sessions)))
              (window (get-buffer-window (ecc-session-buffer session) t)))
    (with-selected-frame (window-frame window)
      (with-selected-window window
        ;; One transcript filling the tab, then split three ways with
        ;; whatever was to hand -- and no window left to read code in.
        (delete-other-windows)
        (split-window-below)
        (other-window 1)
        (switch-to-buffer (find-file-noselect
                           (expand-file-name demo-other demo-root)))
        (split-window-right)
        (other-window 1)
        (switch-to-buffer "*Messages*"))))
  (ecc-sidebar-toggle)
  (demo-frame)
  nil)

(defun demo-reset ()
  "Press `C-c c V' in the transcript: the Space is dealt out again."
  (demo-run-key-in (buffer-name (ecc-session-buffer (car demo-sessions)))
                   "C-c c V"))

;;;; Zoom

(defun demo-zoom ()
  "Press `C-c c z', which fills the tab with the window point is in."
  (demo-run-key-in (buffer-name (ecc-session-buffer (car demo-sessions)))
                   "C-c c z"))

;;;; The sidebar

(defun demo-sidebar-focus ()
  "Press `C-c c b' from the transcript: the sidebar takes the point."
  (demo-run-key-in (buffer-name (ecc-session-buffer (car demo-sessions)))
                   "C-c c b"))

(defun demo-sidebar-key (key)
  "Press KEY in the sidebar."
  (demo-run-key-in ecc-sidebar-buffer-name key))

(defun demo-report-sidebar-row ()
  "Say which row of the sidebar point is on."
  (demo-say (format "The sidebar row: %S"
                    (with-current-buffer ecc-sidebar-buffer-name
                      (string-trim (thing-at-point 'line t)))))
  nil)

(defun demo-report-sidebar ()
  "Say what the sidebar holds, row by row."
  (demo-say (format "The sidebar: %s"
                    (mapconcat #'string-trim
                               (seq-remove #'string-empty-p
                                           (split-string
                                            (with-current-buffer ecc-sidebar-buffer-name
                                              (buffer-substring-no-properties
                                               (point-min) (point-max)))
                                            "\n"))
                               " / ")))
  nil)

(defun demo-jump (number)
  "Go to Space NUMBER, which is what the digit keys of the sidebar do."
  (ecc-space-jump number)
  (demo-frame)
  nil)

;;;; A worktree, so that the sidebar has a tree to draw

(defun demo-start-worktree (branch)
  "Cut BRANCH beside the repository and start a session in it.
The root the command works out is checked before it is let near git: a
step arrives with `*scratch*\=' current, and a scene that asked for a
worktree once cut two of them in the real repository (2026-09-17)."
  (with-current-buffer (find-file-noselect
                        (expand-file-name demo-source demo-root))
    (let* ((default-directory demo-root)
           (root (ecc-worktree-context-root)))
      (unless (equal (file-truename root) (file-truename demo-root))
        (error "The demo would have worked in %s, not %s" root demo-root))
      (push (ecc-start-worktree branch) demo-sessions)))
  (demo-frame)
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session and undo the worktrees this scene cut."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (let ((default-directory demo-root))
    (call-process "git" nil nil nil "worktree" "prune"))
  (demo-say "Every session stopped.")
  nil)

(provide 'reset-and-sidebar)
;;; reset-and-sidebar.el ends here
