;;; space-reset.el --- Putting a Space back in order, and the sidebar  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-space-reset-windows' (`C-c c V', `V' in the menu) is new in
;; 0.3.0: the windows of a Space are the user's and nothing rearranges
;; them on its own, which left no way to say start again.  It runs the
;; same code a new tab is dealt with -- the source on the left, the
;; transcripts beside it, most recently used first, stopping where the
;; row has no room for another column of `ecc-space-session-min-width'.
;;
;; The scene wrecks a tab in the three ways it gets wrecked -- a
;; transcript given the whole tab, a zoom, a hidden sidebar -- and puts
;; it back.  It also shows the fix beside it: a Space whose tab has
;; nothing but transcripts left in it comes up with a window for the
;; code again, without anybody asking.  Then the sidebar: the numbers
;; the `1'-`9' keys take, `TAB' folding a repository's worktrees away,
;; and the mark of a folded repository answering for the group.
;;
;; Played by demo/scenes/space-reset.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-worktree)

(defvar demo-sessions nil "The sessions this scene started, newest first.")

;;;; The project

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el."
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-write "README.md" "# greet\n\nA greeting.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say what the setting is."
  (find-file (expand-file-name "greet.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc-use-spaces = %S   ecc-space-session-min-width = %S"
                    ecc-use-spaces ecc-space-session-min-width))
  nil)

(defun demo-start-sessions (n)
  "Start N sessions in the project."
  (dotimes (_ n)
    (push (ecc-start demo-root) demo-sessions))
  (demo-frame)
  nil)

(defun demo-start-worktree (branch)
  "Cut BRANCH beside the repository and start a session there."
  (let ((default-directory demo-root))
    (push (ecc-start-worktree branch) demo-sessions))
  (demo-frame)
  nil)

;;;; What the tab looks like

(defun demo-report-windows ()
  "Say what the windows of this tab hold."
  (demo-say (format "%d windows: %s"
                    (length (window-list))
                    (mapconcat (lambda (window)
                                 (format "%s%s"
                                         (buffer-name (window-buffer window))
                                         (if (window-parameter window 'no-other-window)
                                             " (side)" "")))
                               (window-list) " | ")))
  nil)

(defun demo-report-zoom ()
  "Say whether this tab is zoomed."
  (demo-say (format "zoomed (the way back kept for this tab): %s   ·   sidebar: %s"
                    (if (alist-get (ecc-window--layout-key)
                                   (frame-parameter nil 'ecc-space-zoom)
                                   nil nil #'equal)
                        "yes" "no")
                    (if (get-buffer-window ecc-sidebar-buffer-name) "on the screen" "hidden")))
  nil)

;;;; Wrecking it

(defun demo-only-a-transcript ()
  "Give the whole tab to one transcript, which is what C-x 1 there does."
  (when-let* ((session (car demo-sessions))
              (window (get-buffer-window (ecc-session-buffer session))))
    (select-window window)
    (delete-other-windows))
  (demo-frame)
  nil)

(defun demo-hide-sidebar ()
  "Hide the sidebar, the way q in it does."
  (ecc-sidebar-hide)
  (demo-frame)
  nil)

(defun demo-zoom ()
  "Fill the tab with the window point is in."
  (ecc-space-zoom)
  (demo-frame)
  nil)

;;;; Putting it back

(defun demo-reset ()
  "V -- put this Space back to the arrangement a new tab gets."
  (ecc-space-reset-windows)
  (demo-frame)
  nil)

(defun demo-leave-and-return ()
  "Go to another Space and come back, which is where the fix shows."
  (when-let* ((other (seq-find (lambda (space)
                                 (not (equal (ecc-space-key space)
                                             (ecc-space-key (ecc-space-current)))))
                               (ecc-space-list))))
    (ecc-space-goto other)
    (demo-frame)
    (run-at-time 3 nil (lambda ()
                         (ecc-space-goto (car (ecc-space-list)))
                         (demo-frame))))
  nil)

(defun demo-narrow-the-row ()
  "Ask for wider transcripts than the frame can hold, and deal again."
  (setq ecc-space-session-min-width 150)
  (ecc-space-reset-windows)
  (demo-frame)
  (demo-say (format "ecc-space-session-min-width = %d: a row with no room does not grow a narrower column"
                    ecc-space-session-min-width))
  nil)

(defun demo-widen-the-row ()
  "Put the setting back and deal again."
  (setq ecc-space-session-min-width 80)
  (ecc-space-reset-windows)
  (demo-frame)
  nil)

(defun demo-report-homeless ()
  "Say which sessions of this Space have no window, and are running all the same."
  (let* ((sessions (ecc-space-sessions (ecc-space-current)))
         (homeless (seq-remove (lambda (session)
                                 (get-buffer-window (ecc-session-buffer session) t))
                               sessions)))
    (demo-say (format "%d session(s) in this Space, %d without a window: %s"
                      (length sessions) (length homeless)
                      (or (mapconcat (lambda (session)
                                       (format "%s (%s)" (ecc-session-name session)
                                               (if (process-live-p (ecc-session-process session))
                                                   "still running" "stopped")))
                                     homeless "  ")
                          "none"))))
  nil)

;;;; The sidebar

(defun demo-show-sidebar ()
  "Put the sidebar back on the screen."
  (ecc-sidebar-show)
  (ecc-sidebar-redraw)
  (demo-frame)
  nil)

(defun demo-sidebar-text ()
  "Say what the sidebar is drawing, row by row."
  (with-current-buffer (get-buffer-create ecc-sidebar-buffer-name)
    (demo-say (format "sidebar: %s"
                      (string-join
                       (seq-remove #'string-empty-p
                                   (split-string (buffer-substring-no-properties
                                                  (point-min) (point-max))
                                                 "\n"))
                       " / "))))
  nil)

(defun demo-sidebar-key (key)
  "Run what KEY does in the sidebar."
  (demo-run-key-in ecc-sidebar-buffer-name key))

(defun demo-sidebar-goto-repository ()
  "Put point on the row of the repository, which is the one with children."
  (with-current-buffer (get-buffer ecc-sidebar-buffer-name)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (with-selected-window window
        (goto-char (point-min))
        (when (re-search-forward (regexp-quote
                                  (file-name-nondirectory
                                   (directory-file-name demo-root)))
                                 nil t)
          (goto-char (line-beginning-position))))))
  nil)

;;;; Putting the machine back

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

(provide 'space-reset)
;;; space-reset.el ends here
