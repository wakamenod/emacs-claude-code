;;; review-ediff-sides.el --- The review as two sides of one ediff  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-review-style' set to `ediff' opens `D' and `G' as one ediff
;; session rather than one diff buffer, and this is the half of it that
;; is about the screen rather than the keys (demo/scenes/review-ediff-help.el
;; has the keys and the help): every file of the review in one pair of
;; buffers under a `═══ path ═══' separator, both sides read-only, each
;; file fontified by its own major mode, the review taking the frame and
;; handing the windows back when it is quit, and `a' and `b' -- ediff's
;; own copy commands -- saying what a review is instead of failing with
;; `buffer-read-only'.
;;
;; The files are changed by a shell command, as they are in
;; demo/scenes/review-baseline.el: the review compares two git trees and
;; does not care what changed them.
;;
;; Played by demo/scenes/review-ediff-sides.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ediff)

(defvar demo-session nil
  "The session the review belongs to.")

(defvar demo-windows nil
  "What the windows of the tab held before the review opened.")

;;;; What the review is of

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-use-spaces t
        ecc-review-style 'ediff
        ;; The control panel is a frame of its own on a graphical Emacs,
        ;; and only this frame is recorded; worse, a run of this scene
        ;; stopped dead the moment the review opened -- every step after
        ;; it timed out -- with the panel in a frame nothing here could
        ;; see (2026-09-18).  A window like any other, as demo/README.md
        ;; says for a scene that wants the panel on camera.
        ediff-window-setup-function #'ediff-setup-windows-plain)
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    \"\"\"Say hi.\"\"\"\n    return \"hi \" + name\n\n\ndef farewell(name):\n    return \"bye \" + name\n")
  (demo-write "README.md" "# greet\n\nA greeting, and a goodbye.\n")
  (demo-write "data.txt" "one\ntwo\nthree\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc and which style this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc from %s   --   ecc-review-style = %S"
                    (abbreviate-file-name (locate-library "ecc-review-ediff"))
                    ecc-review-style))
  nil)

(defun demo-start-session ()
  "Start a real session, which is what takes the baseline."
  (let ((default-directory demo-root))
    (setq demo-session (ecc-start demo-root "review")))
  nil)

(defun demo-do-the-work ()
  "Change the files with a shell command, and write one git has not seen."
  (let ((default-directory demo-root))
    (call-process "sh" nil nil nil "-c"
                  "sed -i '' 's/\"hi \" + name/f\"hello {name}!\"/' greet.py")
    (call-process "sh" nil nil nil "-c" "printf 'four\\n' >> data.txt"))
  (demo-write "NOTES.md" "Written during the session.\n")
  (demo-say "sed changed greet.py, a shell append changed data.txt, NOTES.md is new")
  nil)

;;;; Opening it

(defun demo-remember-windows ()
  "Remember what the windows of this tab hold."
  (setq demo-windows (mapcar (lambda (window) (buffer-name (window-buffer window)))
                             (window-list nil 'no-minibuffer)))
  (demo-say (format "windows before the review: %s" (string-join demo-windows " | ")))
  nil)

(defun demo-report-windows ()
  "Say what the windows of this tab hold now."
  (demo-say (format "windows now: %s"
                    (mapconcat (lambda (window) (buffer-name (window-buffer window)))
                               (window-list nil 'no-minibuffer) " | ")))
  nil)

(defun demo-open-review ()
  "Open the review of everything that changed since the session started."
  (ecc-review demo-session)
  nil)

(defun demo-control-buffer ()
  "Return the control buffer of the ediff review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode)
                     (bound-and-true-p ecc-review-ediff--buffers))))
            (buffer-list)))

(defun demo-key (key &optional text prefix)
  "Run what KEY does in the ediff control panel."
  (demo-run-key-in (demo-control-buffer) key text prefix))

(defun demo-say-key (key)
  "Say what KEY runs in the control panel."
  (demo-say-key-in (demo-control-buffer) key))

(defun demo-place-panel ()
  "Put the control panel inside the picture when it is a frame of its own."
  (with-current-buffer (demo-control-buffer)
    (when (and (boundp 'ediff-control-frame) (frame-live-p ediff-control-frame))
      (set-frame-position ediff-control-frame 60 40)
      (raise-frame ediff-control-frame)))
  nil)

;;;; What the two sides are

(defun demo-sides ()
  "Return the two buffers of the review, as (A . B)."
  (buffer-local-value 'ecc-review-ediff--buffers (demo-control-buffer)))

(defun demo-report-sides ()
  "Say what the two sides are and whether either may be written to."
  (let ((a (car (demo-sides)))
        (b (cdr (demo-sides))))
    (demo-say
     (format "A: %s (read-only %S, %d lines)   B: %s (read-only %S, %d lines)   differences: %d"
             (buffer-name a) (buffer-local-value 'buffer-read-only a)
             (with-current-buffer a (count-lines (point-min) (point-max)))
             (buffer-name b) (buffer-local-value 'buffer-read-only b)
             (with-current-buffer b (count-lines (point-min) (point-max)))
             (buffer-local-value 'ediff-number-of-differences (demo-control-buffer)))))
  nil)

(defun demo-report-files ()
  "Say which files the two sides carry, by their separator lines."
  (with-current-buffer (cdr (demo-sides))
    (let (files)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "^═\\{3\\} \\(.*?\\) ═\\{3\\}$" nil t)
          (push (match-string 1) files)))
      (demo-say (format "one ediff session over %d file(s): %s"
                        (length files)
                        (string-join (nreverse files) ", ")))))
  nil)

(defun demo-report-fontified ()
  "Say whether the code in the sides carries faces of its own."
  (with-current-buffer (cdr (demo-sides))
    (let (faces)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((face (get-text-property (point) 'face)))
            (cl-pushnew face faces :test #'equal))
          (forward-char 1)))
      (demo-say (format "%d face(s) on the text of side B: %s"
                        (length faces)
                        (string-join (mapcar (lambda (f) (format "%S" f))
                                             (seq-take faces 6))
                                     ", ")))))
  nil)

(defun demo-copy-with (key)
  "Press KEY -- ediff's copy commands -- and say whether anything moved."
  (let* ((b (cdr (demo-sides)))
         (before (with-current-buffer b (buffer-hash))))
    (demo-key key)
    (run-at-time
     1.5 nil
     (lambda ()
       (demo-say
        (format "%s: side B %s" key
                (if (equal before (with-current-buffer b (buffer-hash)))
                    "is exactly as it was"
                  "CHANGED, which a review must not do"))))))
  nil)

(defun demo-report-copy-binding ()
  "Say what a and b run in this panel."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "in this panel a runs %S and b runs %S"
                      (key-binding (kbd "a")) (key-binding (kbd "b")))))
  nil)

(defun demo-report-message ()
  "Say what the last message of this Emacs was."
  (with-current-buffer "*Messages*"
    (save-excursion
      (goto-char (point-max))
      (forward-line -1)
      (demo-say (format "last message: %s"
                        (string-trim
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))))))
  nil)

(defun demo-cleanup ()
  "Put the style back and stop the session."
  (setq ecc-review-style 'diff)
  (when (and demo-session (process-live-p (ecc-session-process demo-session)))
    (ignore-errors (ecc-kill demo-session)))
  nil)

(provide 'review-ediff-sides)
;;; review-ediff-sides.el ends here
