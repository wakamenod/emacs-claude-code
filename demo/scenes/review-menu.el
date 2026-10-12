;;; review-menu.el --- C-c c D asks what to compare  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 4 of the review comments: `C-c c D' opens `ecc-review-menu',
;; which asks what a review compares before it opens one.  What a batch
;; test cannot see is the menu itself -- its counts, its heading, the
;; mark on the last choice and where the cursor starts -- and the keys
;; going through it in the user's own configuration: `S' to send the
;; comments to the other session, `b RET RET' for this branch with its
;; working tree, and `c' on one commit.
;;
;; Two real sessions are started in the project and nothing is sent to
;; either, so the scene costs nothing.  The keys of the menu are put on
;; `unread-command-events' from timers, the way typing arrives: transient
;; reads them through its own keymap, whichever buffer is current, and a
;; step cannot wait for the server while a minibuffer is open.
;;
;; Every step reports what it found -- the text of the menu, the line the
;; cursor is on, and the range, session and files of the review that
;; opened -- and the scene ends by saving those reports to
;; /tmp/ecc-demo-review-menu-log.txt, which is what the run is judged
;; from.
;;
;; Played by demo/scenes/review-menu.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-menu)

(defvar demo-sessions nil "The two sessions of the project, first started first.")

(defvar demo-commits nil "Alist of a commit's subject to its short id.")

;;;; The project

(defun demo-commit (subject file content)
  "Write CONTENT to FILE and commit it as SUBJECT; remember its id."
  (demo-write file content)
  (demo-git "add" file)
  (demo-git "commit" "-q" "-m" subject)
  (push (cons subject (string-trim (let ((default-directory demo-root))
                                     (shell-command-to-string
                                      "git rev-parse --short HEAD"))))
        demo-commits))

(defun demo-scene-build ()
  "Build three branches, main, develop and feature, and open the project.
Called by demo.el."
  ;; The menu's -e is the way to ediff for one review; the scene shows
  ;; the diff, whatever this machine's init chose.
  (setq ecc-review-style 'diff)
  (setq demo-commits nil)
  (demo-fresh-repository)
  (demo-git "symbolic-ref" "HEAD" "refs/heads/main")
  (demo-commit "first" "app.py" "def main():\n    print(\"hi\")\n")
  (demo-git "checkout" "-q" "-b" "develop")
  (demo-commit "add util" "util.py" "def double(x):\n    return 2 * x\n")
  (demo-git "checkout" "-q" "-b" "feature")
  (demo-commit "greet" "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-open-source)
  (demo-say (format "ecc %s   ecc-use-spaces = %S   branches main < develop < feature"
                    (ecc-version) ecc-use-spaces))
  nil)

(defun demo-open-source ()
  "Show app.py alone: the menu is opened from a file of the project."
  (find-file (expand-file-name "app.py" demo-root))
  (delete-other-windows)
  nil)

(defun demo-start-sessions ()
  "Start two sessions in the project; their baseline is the tree as committed."
  (setq demo-sessions (list (ecc-start demo-root "menu-a")))
  (run-at-time 3 nil (lambda ()
                       (setq demo-sessions
                             (append demo-sessions
                                     (list (ecc-start demo-root "menu-b"))))))
  nil)

(defun demo-work ()
  "Change the tree the way a session would: unstaged, staged and untracked."
  (demo-write "app.py" "def main():\n    print(\"hello\")\n")
  (demo-write "notes.md" "# Notes\n")
  (demo-git "add" "notes.md")
  (demo-write "todo.txt" "write the tests\n")
  (demo-say "app.py changed, notes.md staged, todo.txt untracked")
  nil)

;;;; Typing

(defun demo-type (&rest chunks)
  "Type CHUNKS 0.8 s apart: a string is a key description, a list a text.
They go on `unread-command-events', where transient and the minibuffer
read them the way they read typing."
  (let ((delay 0.3))
    (dolist (chunk chunks)
      (let ((events (if (consp chunk)
                        (string-to-list (car chunk))
                      (listify-key-sequence (kbd chunk)))))
        (run-at-time delay nil
                     (lambda ()
                       (setq unread-command-events
                             (append unread-command-events events)))))
      (setq delay (+ delay 0.8))))
  nil)

(defun demo-open-menu ()
  "Press C-c c D in app.py, the way the user's init binds it."
  (demo-open-source)
  (demo-say-key-in "app.py" "C-c c D")
  (demo-run-key-in "app.py" "C-c c D")
  nil)

;;;; Reports

(defun demo-report-menu (label)
  "Say, under LABEL, what the menu shows and which line the cursor is on."
  (let* ((buffer (get-buffer (or (bound-and-true-p transient--buffer-name)
                                 " *transient*")))
         (window (and buffer (get-buffer-window buffer t))))
    (if (not window)
        (demo-say (format "[%s] no menu on the screen" label))
      (with-current-buffer buffer
        (demo-say (format "[%s] menu:\n%s\n[%s] cursor on: %s" label
                          (string-trim-right (buffer-substring-no-properties
                                              (point-min) (point-max)))
                          label
                          (save-excursion
                            (goto-char (window-point window))
                            (string-trim (buffer-substring-no-properties
                                          (line-beginning-position)
                                          (line-end-position)))))))))
  nil)

(defun demo-review-buffers ()
  "The review buffers of this Emacs, the most recently shown first."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer (derived-mode-p 'ecc-review-mode)))
              (buffer-list)))

(defun demo-report-review (label)
  "Say, under LABEL, what the review on the screen compares and shows."
  (let ((review (seq-find #'get-buffer-window (demo-review-buffers))))
    (if (not review)
        (demo-say (format "[%s] no review on the screen" label))
      (with-current-buffer review
        (let ((files nil))
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward "^diff --git a/\\(\\S-+\\)" nil t)
              (push (match-string 1) files)))
          (demo-say (format "[%s] review %s  range %S  comments to %s  files %s"
                            label (buffer-name) ecc-review--range
                            (ecc-session-name ecc-review--session)
                            (string-join (nreverse files) " ")))))))
  nil)

(defun demo-report-commits ()
  "Say which commit is which, so the c step can be checked."
  (demo-say (format "commits: %s"
                    (mapconcat (lambda (cell) (format "%s=%s" (car cell) (cdr cell)))
                               (reverse demo-commits) "  ")))
  nil)

;;;; The steps

(defun demo-switch-session ()
  "S, then the name of the session the comments do not go to yet."
  (let ((other (seq-find (lambda (session)
                           (not (eq session (plist-get ecc-review-menu--state :session))))
                         demo-sessions)))
    (demo-type "S" (list (ecc-session-name other)) "RET")))

(defun demo-branch ()
  "b RET RET: this branch with its working tree, against the guessed base."
  (demo-type "b" "RET" "RET"))

(defun demo-one-commit ()
  "c, the commit \"add util\", RET: that commit alone."
  (demo-type "c" (list (alist-get "add util" demo-commits nil nil #'equal))
             "RET" "RET"))

(defun demo-close-menu ()
  "Close whatever transient is open."
  (run-at-time 0.2 nil (lambda () (ignore-errors (transient-quit-all))))
  nil)

(defun demo-cleanup ()
  "Kill the two sessions."
  (dolist (session demo-sessions)
    (ignore-errors (ecc-kill session)))
  nil)

(provide 'review-menu)
;;; review-menu.el ends here
