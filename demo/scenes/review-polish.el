;;; review-polish.el --- b says its sides, ediff shows what changed in a line  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 5 of the review comments.  What a batch test cannot see is the
;; two questions of `b' in the review menu as they are asked in the
;; user's own configuration -- the prompt naming the side, each branch
;; with how far it is behind its upstream beside it, and a local develop
;; that is behind origin/develop giving way to it -- and then the ediff
;; review that opens, under the user's own theme: what changed inside a
;; line marked in the current difference and in the difference beside
;; it that is not current, and the files coloured after the review is
;; already on the screen.
;;
;; The project has a develop two commits behind an origin/develop it
;; tracks, and a feature cut from origin/develop.  One real session is
;; started and nothing is sent to it, so the scene costs nothing.  The
;; keys of the menu go on `unread-command-events' from timers, the way
;; typing arrives, as in review-menu.el.
;;
;; Every step reports what it found -- the prompts and the annotations,
;; the files of the review, the faces at the characters that changed and
;; the backgrounds they are drawn on -- and the scene ends by saving
;; those reports to /tmp/ecc-demo-review-polish-log.txt, which is what
;; the run is judged from.
;;
;; Played by demo/scenes/review-polish.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-menu)

(defvar demo-session nil "The session of the project.")

;;;; The project

(defun demo-lib (&optional changed)
  "The text of lib.py; CHANGED renames a word in lines 4 and 9."
  (concat "import math\n\n\n"
          (if changed "def area(radius):\n" "def size(radius):\n")
          "    \"\"\"The area of a circle.\"\"\"\n"
          "    return math.pi * radius ** 2\n\n\n"
          (if changed "def circumference(radius):\n" "def perimeter(radius):\n")
          "    return 2 * math.pi * radius\n"
          (mapconcat (lambda (n) (format "\n\ndef f%d():\n    return %d\n" n n))
                     (number-sequence 1 40) "")))

(defun demo-commit (subject file content)
  "Write CONTENT to FILE and commit it as SUBJECT."
  (demo-write file content)
  (demo-git "add" file)
  (demo-git "commit" "-q" "-m" subject))

(defun demo-scene-build ()
  "Build main, a develop behind its origin/develop, and feature.  Called by demo.el."
  (setq ecc-review-style 'ediff
        ;; The control panel a window of the frame, so that it is in the
        ;; picture (demo/README.md).
        ediff-window-setup-function #'ediff-setup-windows-plain)
  (demo-fresh-repository)
  (demo-git "symbolic-ref" "HEAD" "refs/heads/main")
  (demo-commit "first" "app.py" "def main():\n    print(\"hi there\")\n")
  (demo-git "checkout" "-q" "-b" "develop")
  (demo-commit "lib" "lib.py" (demo-lib))
  ;; Two commits that reach origin/develop and not the local develop.
  (demo-commit "d1" "d1.py" "ONE = 1\n")
  (demo-commit "d2" "d2.py" "TWO = 2\n")
  (demo-git "update-ref" "refs/remotes/origin/develop" "HEAD")
  (demo-git "reset" "-q" "--hard" "HEAD~2")
  (demo-git "remote" "add" "origin" "https://example.com/demo.git")
  (demo-git "config" "branch.develop.remote" "origin")
  (demo-git "config" "branch.develop.merge" "refs/heads/develop")
  ;; feature, cut from what was fetched.
  (demo-git "checkout" "-q" "-b" "feature" "--no-track" "origin/develop")
  (demo-commit "rename" "lib.py" (demo-lib t))
  ;; And one change not committed yet.
  (demo-write "app.py" "def main():\n    print(\"hello there\")\n")
  (find-file (expand-file-name "app.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   theme %S   develop is 2 behind origin/develop; feature is cut from origin/develop"
                    (ecc-version) custom-enabled-themes))
  nil)

(defun demo-start-session ()
  "Start the session the comments go to."
  (setq demo-session (ecc-start demo-root "polish"))
  nil)

;;;; Typing

(defun demo-type (&rest chunks)
  "Type CHUNKS 0.8 s apart: a string is a key description, a function is called.
They go on `unread-command-events', where transient and the minibuffer
read them the way they read typing."
  (let ((delay 0.3))
    (dolist (chunk chunks)
      (if (functionp chunk)
          (run-at-time delay nil chunk)
        (let ((events (listify-key-sequence (kbd chunk))))
          (run-at-time delay nil
                       (lambda ()
                         (setq unread-command-events
                               (append unread-command-events events))))))
      (setq delay (+ delay (if (functionp chunk) 3.5 0.8)))))
  nil)

(defun demo-report-question ()
  "Say what the minibuffer asks and what it offers, with the annotations.
Run from a timer while the question is open; the list is shown too,
unless the configuration shows one by itself."
  (when-let* ((window (active-minibuffer-window)))
    (with-selected-window window
      (let* ((table minibuffer-completion-table)
             (annotate (completion-metadata-get
                        (completion-metadata "" table minibuffer-completion-predicate)
                        'annotation-function)))
        (demo-say (format "prompt: %S || offered: %s" (minibuffer-prompt)
                          (mapconcat (lambda (candidate)
                                       (concat candidate
                                               (or (and annotate (funcall annotate candidate))
                                                   "")))
                                     (all-completions "" table) " | ")))
        (unless (or (bound-and-true-p vertico-mode) (bound-and-true-p icomplete-mode)
                    (bound-and-true-p fido-mode))
          (minibuffer-completion-help)))))
  nil)

(defun demo-open-menu ()
  "Press C-c c D in app.py, the way the user's init binds it."
  (demo-say-key-in "app.py" "C-c c D")
  (demo-run-key-in "app.py" "C-c c D")
  nil)

(defun demo-branch ()
  "b, show the question, RET; show the next, RET."
  (demo-type "b" #'demo-report-question "RET" #'demo-report-question "RET"))

;;;; The review

(defun demo-control-buffer ()
  "Return the control buffer of the review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode) ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-report-review ()
  "Say what the review compares, its files and how much is still uncoloured."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "review %s  range %S  files %s  differences %d  uncoloured A %d B %d  colour timer %S"
                      (buffer-name (cdr ecc-review-ediff--buffers)) ecc-review--range
                      (mapconcat #'car ecc-review-ediff--sections " ")
                      ediff-number-of-differences
                      (length (buffer-local-value 'ecc-review-ediff--uncoloured ediff-buffer-A))
                      (length (buffer-local-value 'ecc-review-ediff--uncoloured ediff-buffer-B))
                      (and ecc-review-ediff--colour-timer t))))
  nil)

(defun demo-key (key)
  "Run what KEY does in the control panel."
  (demo-run-key-in (demo-control-buffer) key))

(defun demo-remapped (buffer face)
  "The background FACE is drawn with in BUFFER, after the review's remapping."
  (with-current-buffer buffer
    (let ((entry (cdr (assq face face-remapping-alist))))
      (or (seq-some (lambda (spec) (and (listp spec) (plist-get spec :background)))
                    (if (and (consp entry) (keywordp (car entry))) (list entry) entry))
          (face-attribute face :background nil t)))))

(defun demo-report-fine (n label)
  "Say, under LABEL, how difference N marks what changed inside its lines."
  (with-current-buffer (demo-control-buffer)
    (dolist (side '(A B))
      (let* ((buffer (if (eq side 'A) ediff-buffer-A ediff-buffer-B))
             (fine (and (ediff-valid-difference-p n) (ediff-get-fine-diff-vector n side)))
             (overlay (and fine (> (length fine) 0) (aref fine 0)))
             (current (if (eq side 'A) 'ediff-current-diff-A 'ediff-current-diff-B))
             (fine-face (if (eq side 'A) 'ediff-fine-diff-A 'ediff-fine-diff-B))
             (around (demo-remapped buffer (if (eq n ediff-current-difference) current
                                             (if (eq side 'A) 'diff-removed 'diff-added))))
             (marked (demo-remapped buffer fine-face)))
        (demo-say
         (if (not overlay)
             (format "[%s] difference %d %s: not refined" label (1+ n) side)
           (with-current-buffer buffer
             (format "[%s] difference %d %s%s: %S has overlay faces %S, text face %S; drawn on %s (L %.2f), marked %s (L %.2f) bold; theme gave %s %s"
                     label (1+ n) side (if (eq n ediff-current-difference) " (current)" "")
                     (buffer-substring-no-properties (overlay-start overlay) (overlay-end overlay))
                     (mapcar (lambda (o) (overlay-get o 'face))
                             (overlays-at (overlay-start overlay) t))
                     (get-text-property (overlay-start overlay) 'face)
                     around (or (ecc-review-ediff--lightness around) -1)
                     marked (or (ecc-review-ediff--lightness marked) -1)
                     fine-face (face-attribute fine-face :background nil t))))))))
  nil)

(defun demo-report-faces ()
  "Say how the current difference and the one after it mark their words."
  (with-current-buffer (demo-control-buffer)
    (let ((n ediff-current-difference))
      (demo-report-fine n "current")
      (demo-report-fine (1+ n) "beside it")))
  nil)

(defun demo-quit ()
  "Close the review, and the session."
  (when-let* ((control (demo-control-buffer)))
    (ecc-review-ediff-quit control))
  (ignore-errors (ecc-kill demo-session))
  nil)

(provide 'review-polish)
;;; review-polish.el ends here
