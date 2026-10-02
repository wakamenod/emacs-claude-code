;;; review-direct.el --- Reading an ediff review in its two windows  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 8 of the review comments.  What a batch test cannot see is the
;; review read in its own windows on a real frame: the keyboard in the
;; right window when ediff opens, the header line of keys over each
;; window, n and c typed there, the other window following point --
;; inside a difference and between two -- an isearch followed once it
;; ends, v scrolling both, and RET opening the file in a frame of its
;; own while the review frame stays as it was.
;;
;; No session runs a model: the session is an archived one with no
;; process, which a review needs only to belong to.  The keys are typed
;; with `execute-kbd-macro' in the window they belong to, not looked up
;; and called (`demo-run-key-in'): the review's windows relay what was
;; typed to the control panel and follow point after a command, and
;; both need the command loop -- the keys of the command and the hooks
;; after it.  A key that reads the minibuffer has its answer in the same
;; macro.
;;
;; Every step reports what it found -- which window has the keyboard,
;; the difference ediff is on, the line each window has point on and how
;; far down its window, the comments, the frames -- and the scene ends by
;; saving the reports to /tmp/ecc-demo-review-direct-log.txt, which is
;; what the run is judged from.
;;
;; Played by demo/scenes/review-direct.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-direct)

(defvar demo-session nil "The session the review belongs to.")

(defun demo-lines (edit)
  "Return 80 lines of src/table.py, with EDIT, a function of N, changing some."
  (mapconcat (lambda (n)
               (or (funcall edit n)
                   (format "    row_%02d = lookup(table, %d)  # unchanged\n" n n)))
             (number-sequence 1 80) ""))

(defun demo-old (n)
  "The old text of line N of src/table.py, where it is not the plain one."
  (pcase n
    (1 "def build(table):\n")
    (12 "    total = sum(table)\n")
    (60 "    return total\n")
    (_ nil)))

(defun demo-new (n)
  "The new text of line N of src/table.py, where it is not the plain one."
  (pcase n
    (1 "def build(table):\n")
    (12 "    total = sum(row.value for row in table)\n")
    (30 "    row_30 = lookup(table, 30)  # unchanged\n    cache = {}\n    cache.clear()\n")
    ((or 44 45) "")
    (60 "    return total, cache\n")
    (_ nil)))

;;;; What the scene is played on

(defun demo-scene-build ()
  "Build the project: a file committed, then changed in four places.
Called by demo.el."
  (setq ecc-review-style 'ediff
        ecc-review-files-shown nil
        ecc-review-talk-reply-height nil
        ;; The control panel a window of the frame, so that it is in the
        ;; picture (demo/README.md).
        ediff-window-setup-function #'ediff-setup-windows-plain
        ;; The file RET opens goes in a frame named apart from the one
        ;; being recorded, which `demo-main-frame' finds by its name.
        ecc-review-direct-make-frame-function
        (lambda () (make-frame '((name . "ecc review files") (width . 90) (height . 30)))))
  (demo-fresh-repository)
  (demo-write "src/table.py" (demo-lines #'demo-old))
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-write "src/table.py" (demo-lines #'demo-new))
  (find-file (expand-file-name "src/table.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   theme %S   ecc-use-spaces %S"
                    (ecc-version) custom-enabled-themes ecc-use-spaces))
  nil)

(defun demo-open-session ()
  "Make the session the review belongs to."
  (setq demo-session (ecc-model-create-session
                      :id "demo-review-direct"
                      :name "direct"
                      :project-root demo-root
                      :kind 'archived))
  (ecc-model-set-state demo-session 'idle)
  nil)

(defun demo-open-ediff ()
  "Open the review of everything uncommitted, in ediff, as G opens it."
  (ecc-review-worktree demo-session "HEAD" demo-root)
  (let ((window (demo-side-window 'B)))
    (demo-say (format "right point just after opening: %d (window %d, start %d)"
                      (with-current-buffer (window-buffer window) (point))
                      (window-point window) (window-start window)))
    (redisplay t)
    (demo-say (format "right point after a redisplay: %d (window %d, start %d)"
                      (with-current-buffer (window-buffer window) (point))
                      (window-point window) (window-start window))))
  nil)

;;;; Looking

(defun demo-control-buffer ()
  "Return the control buffer of the ediff review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode) ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-side-window (side)
  "Return the window of SIDE, `A' or `B', of the review."
  (buffer-local-value (if (eq side 'A) 'ediff-window-A 'ediff-window-B)
                      (demo-control-buffer)))

(defun demo-place (side)
  "Return \"LINE (row ROW)\": the line of the file SIDE's window has point on."
  (let* ((control (demo-control-buffer))
         (window (demo-side-window side)))
    (with-current-buffer control
      (format "L%s row %d"
              (cdr (ecc-review-ediff--file-place side (window-point window)))
              (with-current-buffer (window-buffer window)
                (count-lines (window-start window)
                             (save-excursion (goto-char (window-point window))
                                             (line-beginning-position))))))))

(defun demo-report (label)
  "Say, under LABEL, the keyboard, the difference and where each side is."
  (let ((control (demo-control-buffer)))
    (demo-say
     (format "[%s] keyboard in %s; difference %s of %d; left %s; right %s; start of right %d"
             label
             (let ((selected (frame-selected-window (demo-main-frame))))
               (cond ((eq selected (demo-side-window 'A)) "the LEFT window")
                     ((eq selected (demo-side-window 'B)) "the RIGHT window")
                     (t (buffer-name (window-buffer selected)))))
             (let ((n (buffer-local-value 'ediff-current-difference control)))
               (if (>= n 0) (1+ n) "none"))
             (buffer-local-value 'ediff-number-of-differences control)
             (demo-place 'A) (demo-place 'B)
             (window-start (demo-side-window 'B)))))
  nil)

(defun demo-report-headers ()
  "Say the header lines of the two windows and what the control panel says."
  (let ((control (demo-control-buffer)))
    (with-current-buffer control
      (demo-say (format "left header:  %s"
                        (buffer-local-value 'header-line-format ediff-buffer-A)))
      (demo-say (format "right header: %s"
                        (buffer-local-value 'header-line-format ediff-buffer-B)))
      (demo-say (format "control panel: %s" (string-trim (buffer-string))))))
  nil)

(defun demo-report-comments ()
  "Say the comments of the review: their side, line and text."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "comments: %s"
                      (mapconcat (lambda (note)
                                   (format "#%d %s L%s %S" (ecc-review-note-id note)
                                           (ecc-review-note-side note)
                                           (ecc-review-note-line note)
                                           (ecc-review-note-text note)))
                                 ecc-review--notes "; "))))
  nil)

(defun demo-report-frames (label)
  "Say, under LABEL, the frames and what each shows."
  (demo-say
   (format "[%s] frames: %s" label
           (mapconcat (lambda (frame)
                        (format "%S: %s" (frame-parameter frame 'name)
                                (mapconcat (lambda (window)
                                             (format "%s@L%d" (buffer-name (window-buffer window))
                                                     (with-current-buffer (window-buffer window)
                                                       (line-number-at-pos (window-point window)))))
                                           (window-list frame 'no-minibuffer) ", ")))
                      (seq-filter #'frame-visible-p (frame-list)) " | ")))
  nil)

;;;; Doing

(defun demo-type (side keys &optional text)
  "Type KEYS in the window of SIDE, and TEXT and RET into what it reads.
Scheduled, so that the server has its answer before the keys run."
  (run-at-time
   0.2 nil
   (lambda ()
     (let ((window (demo-side-window side)))
       (with-selected-frame (window-frame window)
         (select-window window)
         (execute-kbd-macro (vconcat (kbd keys)
                                     (and text (vconcat text (kbd "RET")))))))))
  nil)

(defun demo-goto (side line)
  "Put point on LINE of src/table.py in the window of SIDE, as a move would.
The window is selected and the hook a command runs after it is run."
  (let* ((control (demo-control-buffer))
         (window (demo-side-window side))
         (position (with-current-buffer control
                     (ecc-review-ediff--file-position side (cons "src/table.py" line)))))
    (with-selected-frame (window-frame window)
      (select-window window)
      (goto-char position)
      (let ((this-command 'next-line))
        (run-hooks 'post-command-hook))))
  nil)

(defun demo-search (side text)
  "Search for TEXT in the window of SIDE with an isearch, ended with RET."
  (demo-type side "C-s" text))

(defun demo-close ()
  "Close the frame files went to, and the review."
  (when (frame-live-p ecc-review-direct--files-frame)
    (delete-frame ecc-review-direct--files-frame))
  (when-let* ((control (demo-control-buffer)))
    (ecc-review-ediff-quit control))
  nil)

(provide 'review-direct)
;;; review-direct.el ends here
