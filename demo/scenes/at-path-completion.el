;;; at-path-completion.el --- @ completion of paths outside the project  -*- lexical-binding: t; -*-

;;; Commentary:

;; `TAB' after `@' in the prompt region, through whatever completion the
;; configuration runs -- corfu, in the init this is played in.  A plain
;; word after `@' is completed from the three special words and the
;; project's files, as it always was.  A path that starts with `/', `~/',
;; `./' or `../' is completed as a file name, a directory at a time, and
;; a relative one from the directory the CLI runs in.  A remote path is
;; not completed and connects to nothing.  The last step sends a path
;; completed outside the project, and the answer shows the CLI read it.
;;
;; The project is a directory of its own under a parent the scene owns,
;; so that `../' lists what the scene made and nothing else in /tmp.
;;
;; Played by demo/scenes/at-path-completion.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-chat)
(require 'ecc-prompt)
(require 'ecc-proc)

(defvar demo-parent "/tmp/ecc-demo-at-path-completion/"
  "The directory the scene owns: the project, a sibling and a tree.")

(setq demo-root (concat demo-parent "project/"))

(defvar demo-tree (concat demo-parent "tree/")
  "A directory outside the project, completed by its absolute path.")

(defvar demo-session nil "The session whose prompt is completed in.")

(defun demo-scene-build ()
  "Build the project, a sibling beside it and a tree.  Called by demo.el."
  (delete-directory demo-parent t)
  (demo-fresh-repository)
  (demo-write "readme.md" "# at-paths\n\nA project to complete @ references in.\n")
  (demo-write "records/reader.py" "def read(path):\n    return open(path).read()\n")
  ;; A cheap model for the one prompt the scene sends: a setting of
  ;; Claude Code, so it goes where Claude Code reads it.
  (demo-write ".claude/settings.json" "{\n  \"model\": \"haiku\"\n}\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (dolist (file '("sibling/note.txt" "sibling/other.txt"
                  "tree/alpha.txt" "tree/beta.txt" "tree/sub/deep.txt"))
    (let ((path (concat demo-parent file)))
      (make-directory (file-name-directory path) t)
      (with-temp-file path
        (insert (if (equal file "sibling/note.txt")
                    "The kettle is in the third cupboard.\nSecond line.\n"
                  (format "%s\n" file))))))
  (find-file (expand-file-name "readme.md" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s from %s" (ecc-version)
                    (file-name-directory (locate-library "ecc"))))
  nil)

(defun demo-start-session ()
  "Start a session in the project and show it."
  (setq demo-session (ecc-start demo-root "at-paths"))
  (ecc-display-session demo-session)
  (demo-frame)
  nil)

(defun demo-buffer ()
  "Return the buffer of the session."
  (ecc-session-buffer demo-session))

(defun demo-write-prompt (text)
  "Make TEXT the prompt, with point at its end in the session's window."
  (with-current-buffer (demo-buffer)
    (when (bound-and-true-p completion-in-region-mode)
      (completion-in-region-mode -1))
    (ecc-chat-set-draft text)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (set-window-point window (point))))
  (demo-say (format "prompt: %S, then TAB" text))
  nil)

(defun demo-tab ()
  "Press TAB in the prompt, which is `completion-at-point' there.
`demo-run-key-in' calls the command from a timer, outside the command
loop, and corfu draws and updates its popup from `post-command-hook':
run that way, the popup held the candidates of the TAB before, and a
second TAB put them back (2026-10-11).  The hooks are run around it
here, as the command loop would."
  (run-at-time
   0.2 nil
   (lambda ()
     (when-let* ((window (get-buffer-window (demo-buffer) t)))
       (with-selected-frame (window-frame window)
         (with-selected-window window
           (let* ((command (key-binding (kbd "TAB")))
                  (this-command command)
                  (last-command-event ?\t))
             (run-hooks 'pre-command-hook)
             (call-interactively command)
             (setq last-command command)
             (run-hooks 'post-command-hook)))))))
  nil)

(defun demo-project-report ()
  "Say where the session stands and what its project files are."
  (let* ((root (ecc-session-project-root demo-session))
         (project (project-current nil root)))
    (demo-say (format "session root %S; project %S; project files %S"
                      root project
                      (ecc-visit-project-files demo-session))))
  nil)

(defun demo-shown (&optional names)
  "Say what TAB offered, from corfu if it is showing and the capf otherwise.
NAMES nil says only how many there are, for a listing of the home
directory."
  (with-current-buffer (demo-buffer)
    (let* ((corfu (and (bound-and-true-p completion-in-region-mode)
                       (boundp 'corfu--candidates)
                       corfu--candidates))
           (prompt (ecc-chat-draft)))
      (demo-say
       (format "after TAB: prompt %S; corfu %s %d candidate(s)%s"
               (if names prompt (replace-regexp-in-string "~/.*" "~/..." prompt))
               (if completion-in-region-mode "shows" "is not showing,")
               (length corfu)
               (if names
                   (format ": %S" (seq-take corfu 12))
                 "")))))
  nil)

(defun demo-capf-says (&optional names)
  "Say what the capf itself returns at point, apart from corfu.
NAMES as for `demo-shown'."
  (with-current-buffer (demo-buffer)
    (save-excursion
      (goto-char (ecc-chat-prompt-end))
      (let* ((capf (ecc-prompt-at-capf))
             (start (nth 0 capf)))
        (if (null capf)
            (demo-say "the capf returns nil: no completion")
          (let* ((string (buffer-substring-no-properties start (point)))
                 (all (all-completions string (nth 2 capf))))
            (demo-say (format "capf completes %S: %d candidate(s)%s"
                              (if names string "~/...") (length all)
                              (if names (format ": %S" (seq-take (sort all #'string<) 12)) ""))))))))
  nil)

(defun demo-quit-completion ()
  "Close what TAB opened."
  (with-current-buffer (demo-buffer)
    (when (fboundp 'corfu-quit)
      (with-selected-window (get-buffer-window (current-buffer) t)
        (ignore-errors (corfu-quit))))
    (when (bound-and-true-p completion-in-region-mode)
      (completion-in-region-mode -1)))
  nil)

(defun demo-tramp-state ()
  "Say whether TRAMP is loaded and has any connection."
  (demo-say (format "tramp loaded: %s; tramp connections: %s"
                    (featurep 'tramp)
                    (if (fboundp 'tramp-list-connections)
                        (length (tramp-list-connections))
                      0)))
  nil)

(defun demo-send ()
  "Send the prompt as written."
  (demo-run-key-in (demo-buffer) "C-c C-c"))

(defun demo-answer ()
  "Say what the session answered last."
  (with-current-buffer (demo-buffer)
    (let ((text (buffer-substring-no-properties (point-min) (ecc-chat-prompt-start))))
      (demo-say (format "transcript tail: %S"
                        (string-trim (substring text (max 0 (- (length text) 400))))))))
  nil)

(defun demo-cleanup ()
  "Stop the sessions this scene started."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'at-path-completion)
;;; at-path-completion.el ends here
