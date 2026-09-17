;;; review-baseline.el --- The review is git against git now  -*- lexical-binding: t; -*-

;;; Commentary:

;; 0.3.0 made `ecc-review' (`D') a comparison of two git trees: what the
;; working tree held when the session started against what it holds now.
;; It no longer reads the tool stream, so a file changed by a shell
;; command, a script or a person is in the review all the same, and work
;; the session committed along the way is still shown -- which is the
;; one thing `ecc-review-worktree' (`G'), taken against `HEAD', loses.
;;
;; The scene changes the files behind the session's back, which is the
;; case the old review missed entirely, commits one of the changes, and
;; opens both reviews over the same moment.  Then the comments: `c',
;; `l', `d', and `C-c C-c', which sends them instead of opening a buffer
;; to confirm them in.
;;
;; Last, a repository with no commit at all -- where `G' used to stop at
;; `Git cannot diff against "HEAD" (exit 128)'.
;;
;; Played by demo/scenes/review-baseline.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)

(defvar demo-session nil "The session the reviews belong to.")
(defvar demo-unborn-root "/tmp/ecc-demo-unborn/" "A repository with no commit.")
(defvar demo-unborn-session nil "The session of that repository.")

;;;; The project

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el."
  ;; This scene is about the one diff buffer, and the machine this is
  ;; played on sets `ecc-review-style' to `ediff' in its own init: the
  ;; run of 2026-09-18 opened ediff, reported no files at all and
  ;; answered every comment key with a wrong-type-argument.
  (setq ecc-review-style 'diff)
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-write "README.md" "# greet\n\nA greeting.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc and which review style this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc-review-style = %S   ecc %s"
                    ecc-review-style (ecc-version)))
  nil)

(defun demo-start-session ()
  "Start a real session.  Its baseline is the tree as it stands now."
  (setq demo-session (ecc-start demo-root "review-demo"))
  nil)

(defun demo-report-baseline ()
  "Say what the session took as its baseline."
  (demo-say (format "baseline tree of the session: %s"
                    (or (ecc-review-ensure-baseline demo-session) "(none)")))
  nil)

;;;; The work, done where no tool stream would see it

(defun demo-do-the-work ()
  "Change the files the way a shell command would: no Edit, no Write."
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-write "NOTES.md" "Written by a script, not by an Edit.\n")
  (demo-say "greet.py rewritten and NOTES.md created -- by a script, behind the session's back")
  nil)

(defun demo-commit-some-of-it ()
  "Commit README.md during the session, which is what G then loses."
  (demo-write "README.md" "# greet\n\nA greeting, committed during the session.\n")
  (demo-git "add" "README.md")
  (demo-git "commit" "-q" "-m" "committed during the session")
  (demo-say "README.md changed and committed -- still the session's work, but no longer in HEAD's diff")
  nil)

;;;; The two reviews

(defun demo-review-buffer (&optional range)
  "Return the review buffer of this session, RANGE or not."
  (get-buffer (ecc-review-buffer-name demo-session nil range)))

(defun demo-files-in (buffer)
  "Return the files BUFFER's diff names."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (let (files)
          (while (re-search-forward "^\\+\\+\\+ \\(.*\\)$" nil t)
            (push (match-string-no-properties 1) files))
          (nreverse files))))))

(defun demo-open-review ()
  "D -- everything that changed since the session started."
  (ecc-review demo-session)
  (demo-frame)
  nil)

(defun demo-report-review ()
  "Say which files D has."
  (demo-say (format "D (since the session started): %s"
                    (string-join (demo-files-in (demo-review-buffer)) "  ")))
  nil)

(defun demo-open-worktree-review ()
  "G -- what changed since the last commit."
  (with-current-buffer (find-file-noselect (expand-file-name "greet.py" demo-root))
    (ecc-review-worktree demo-session ""))
  (demo-frame)
  nil)

(defun demo-report-worktree-review ()
  "Say which files G has, and what is missing from it."
  (let ((files (demo-files-in (demo-review-buffer ""))))
    (demo-say (format "G (since the last commit): %s   -- README.md is %s"
                      (string-join files "  ")
                      (if (seq-find (lambda (f) (string-match-p "README" f)) files)
                          "STILL THERE"
                        "gone, as it was committed"))))
  nil)

;;;; The comments

(defun demo-key (key &optional text prefix)
  "Run what KEY does in the review buffer."
  (demo-run-key-in (demo-review-buffer) key text prefix))

(defun demo-goto-first-hunk ()
  "Put point on the first hunk of the review."
  (with-current-buffer (demo-review-buffer)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (with-selected-window window
        (goto-char (point-min))
        (re-search-forward "^@@" nil t)
        (forward-line 2))))
  nil)

(defun demo-report-header ()
  "Say what the header line of the review says the keys are."
  (with-current-buffer (demo-review-buffer)
    (demo-say (substring-no-properties (format-mode-line (ecc-review--header-line)))))
  nil)

(defun demo-report-comments ()
  "Say how many comments the review carries."
  (with-current-buffer (demo-review-buffer)
    (demo-say (format "%d comment(s) on the review"
                      (length (ecc-review-comment-overlays)))))
  nil)

(defun demo-message-buffer ()
  "The buffer `C-u C-c C-c\\=' opens."
  (ecc-review-message-buffer-name demo-session))

(defun demo-cancel-message ()
  "Leave that buffer the way C-c C-k does there."
  (demo-run-key-in (demo-message-buffer) "C-c C-k"))

(defun demo-show-session ()
  "Show the transcript, which is where the comments went."
  (ecc-display-session demo-session)
  (demo-frame)
  nil)

;;;; A repository with no commit at all

(defun demo-build-unborn ()
  "Make a repository with a file in it and no commit, and open it."
  (delete-directory demo-unborn-root t)
  (make-directory demo-unborn-root t)
  (let ((default-directory demo-unborn-root))
    (call-process "git" nil nil nil "init" "-q")
    (call-process "git" nil nil nil "config" "user.email" "demo@example.com")
    (call-process "git" nil nil nil "config" "user.name" "demo")
    (with-temp-file (expand-file-name "main.py" demo-unborn-root)
      (insert "print(\"the first code of a project\")\n"))
    (with-temp-file (expand-file-name "untracked.txt" demo-unborn-root)
      (insert "never added\n"))
    (call-process "git" nil nil nil "add" "main.py"))
  (find-file (expand-file-name "main.py" demo-unborn-root))
  (delete-other-windows)
  (demo-say "A repository with one file added and no commit: HEAD names nothing")
  nil)

(defun demo-start-unborn-session ()
  "Start a session in the repository with no commit."
  (setq demo-unborn-session (ecc-start demo-unborn-root "unborn"))
  nil)

(defun demo-open-unborn-review ()
  "G in a repository whose HEAD is unborn."
  (with-current-buffer (find-file-noselect (expand-file-name "main.py" demo-unborn-root))
    (condition-case error
        (ecc-review-worktree demo-unborn-session "" demo-unborn-root)
      (error (demo-say (format "G failed: %S" error)))))
  (demo-frame)
  nil)

(defun demo-report-unborn-review ()
  "Say what that review holds."
  (let ((files (demo-files-in
                (get-buffer (ecc-review-buffer-name demo-unborn-session nil "")))))
    (demo-say (format "G in an unborn repository: %s"
                      (if files (string-join files "  ") "NOTHING -- the old error"))))
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session this scene left running."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'review-baseline)
;;; review-baseline.el ends here
