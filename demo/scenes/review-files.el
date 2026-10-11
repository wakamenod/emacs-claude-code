;;; review-files.el --- s lists the files of a review, / filters them  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 6 of the review comments.  What a batch test cannot see is
;; where the files pane sits in the user's own frame -- a side window at
;; the left edge of an ediff review that has the frame to itself, and
;; between the session and the diff of a diff review under Spaces -- the
;; pane narrowing while / is typed, n and p stepping over the files the
;; filter hides, and the two lines of help in the ediff control panel.
;;
;; The project has five files, each changed in the working tree, and
;; Claude's comment on README.md mentions the lib, so a filter of "lib"
;; keeps README.md by the comment and src/lib.py by its path.  One real
;; session is started and nothing is sent to it, so the scene costs
;; nothing.
;;
;; Every step reports what it found -- the windows from left to right,
;; the lines of the pane, the difference ediff is on and its file -- and
;; the scene ends by saving those reports to
;; /tmp/ecc-demo-review-files-log.txt, which is what the run is judged
;; from.
;;
;; Played by demo/scenes/review-files.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-files)

(defvar demo-session nil "The session of the project.")

(defconst demo-files
  '("README.md" "docs/notes.md" "src/app.py" "src/lib.py" "tests/test_app.py")
  "The files of the project, each changed once the scene is built.")

(defun demo-text (name changed)
  "The text of NAME, CHANGED or not: twenty lines, two of them changed."
  (mapconcat (lambda (n)
               (format "%s line %d of %s"
                       (if (and changed (memq n '(3 15))) "CHANGED" "plain") n name))
             (number-sequence 1 20) "\n"))

(defun demo-scene-build ()
  "Build the project: five files committed, then all five changed.  Called by demo.el."
  (setq ecc-review-style 'ediff
        ecc-review-files-shown nil
        ;; The control panel a window of the frame, so that it is in the
        ;; picture (demo/README.md).
        ediff-window-setup-function #'ediff-setup-windows-plain)
  (demo-fresh-repository)
  (dolist (name demo-files)
    (demo-write name (concat (demo-text name nil) "\n")))
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (dolist (name demo-files)
    (demo-write name (concat (demo-text name t) "\n")))
  (find-file (expand-file-name "src/app.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   theme %S   ecc-use-spaces %S   five files changed"
                    (ecc-version) custom-enabled-themes ecc-use-spaces))
  nil)

(defun demo-start-session ()
  "Start the session the comments go to."
  (setq demo-session (ecc-start demo-root "files"))
  nil)

;;;; Looking

(defun demo-control-buffer ()
  "Return the control buffer of the ediff review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode) ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-diff-review ()
  "Return the diff review buffer of the session."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ecc-review-mode) (eq ecc-review--session demo-session))))
            (buffer-list)))

(defun demo-review ()
  "Return the review on the screen: the ediff one, else the diff one."
  (or (demo-control-buffer) (demo-diff-review)))

(defun demo-report-windows (label)
  "Say, under LABEL, the windows of the frame from left to right."
  (demo-say
   (format "[%s] windows, left to right: %s" label
           (mapconcat (lambda (window)
                        (format "%s%s(%d cols%s)"
                                (buffer-name (window-buffer window))
                                (if (window-parameter window 'window-side)
                                    (format " side:%s " (window-parameter window 'window-side))
                                  " ")
                                (window-total-width window)
                                (if (eq window (selected-window)) ", selected" "")))
                      (sort (window-list (demo-main-frame) 'no-minibuffer)
                            (lambda (a b)
                              (let ((ea (window-edges a)) (eb (window-edges b)))
                                (or (< (car ea) (car eb))
                                    (and (= (car ea) (car eb)) (< (nth 1 ea) (nth 1 eb)))))))
                      " | ")))
  nil)

(defun demo-report-pane (label)
  "Say, under LABEL, what the files pane of the review says."
  (when-let* ((review (demo-review)))
    (let ((pane (buffer-local-value 'ecc-review-files--pane review)))
      (demo-say (format "[%s] pane %s: %s" label
                        (if (ecc-review-files--pane-window review) "shown" "hidden")
                        (if (buffer-live-p pane)
                            (string-join (split-string (with-current-buffer pane
                                                         (buffer-substring-no-properties
                                                          (point-min) (point-max)))
                                                       "\n" t)
                                         " / ")
                          "(no pane buffer)")))))
  nil)

(defun demo-report-help ()
  "Say the lines of the ediff control panel."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "control panel: %s"
                      (string-join (split-string (buffer-substring-no-properties
                                                  (point-min) (point-max))
                                                 "\n" t)
                                   " // "))))
  nil)

(defun demo-report-difference (label)
  "Say, under LABEL, the difference ediff is on and its file."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "[%s] on difference %d of %d, in %s; hidden: %S"
                      label (1+ ediff-current-difference) ediff-number-of-differences
                      (ecc-review-files-current) ecc-review--hidden)))
  nil)

;;;; Doing

(defun demo-open-ediff ()
  "Open the review of everything uncommitted, in ediff, as G opens it."
  (ecc-review-range demo-session "HEAD" demo-root)
  nil)

(defun demo-claude-comment ()
  "Put a comment of Claude's on README.md that mentions the lib."
  (with-current-buffer (demo-control-buffer)
    (ecc-review-add-note 'claude "Mention the new lib here as well"
                         (car (ecc-review-ediff--unit-lines (car (ecc-review-units)))))
    (ecc-review--draw-notes))
  nil)

(defun demo-key (key)
  "Run what KEY does in the review on the screen."
  (demo-run-key-in (demo-review) key)
  nil)

(defun demo-type-filter (text)
  "Press / in the review and type TEXT a character a second, reporting the pane.
Then RET.  The characters go on `unread-command-events' from timers,
the way typing arrives while the minibuffer is open."
  (demo-key "/")
  (let ((delay 1.5))
    (dolist (char (string-to-list text))
      (run-at-time delay nil (lambda () (setq unread-command-events
                                              (append unread-command-events (list char)))))
      (run-at-time (+ delay 0.4) nil
                   (lambda () (demo-report-pane (format "typed so far, after %c" char))))
      (setq delay (+ delay 1.2)))
    (run-at-time (+ delay 0.8) nil
                 (lambda () (setq unread-command-events
                                  (append unread-command-events
                                          (listify-key-sequence (kbd "RET")))))))
  nil)

(defun demo-clear-filter ()
  "Show every file again."
  (ecc-review-files-set-filter (demo-review) "")
  nil)

(defun demo-quit-ediff ()
  "Quit the ediff review, and say whether the pane went with it."
  (let* ((control (demo-control-buffer))
         (pane (and control (buffer-local-value 'ecc-review-files--pane control))))
    (when control
      (ecc-review-ediff-quit control))
    (demo-say (format "ediff quit; its pane buffer %s"
                      (if (buffer-live-p pane) "is still there" "is gone"))))
  nil)

(defun demo-open-diff ()
  "Open the same review as a diff, beside the session, as G opens it."
  (let ((ecc-review-style 'diff))
    (ecc-review-range demo-session "HEAD" demo-root))
  nil)

(defun demo-quit ()
  "Close the reviews, and the session."
  (when-let* ((control (demo-control-buffer)))
    (ecc-review-ediff-quit control))
  (when-let* ((review (demo-diff-review)))
    (kill-buffer review))
  (ignore-errors (ecc-kill demo-session))
  nil)

(provide 'review-files)
;;; review-files.el ends here
