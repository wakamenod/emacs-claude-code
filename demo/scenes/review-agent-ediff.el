;;; review-agent-ediff.el --- Claude's comments in the ediff review  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 3 of the two-way review comments: the review in ediff
;; (`ecc-review-style' `ediff').  What a batch test cannot see is what
;; this is for -- Claude's comments drawn under their lines on the left
;; and on the right; review_navigate putting ediff on a difference and
;; the two sides on a line while the keyboard stays in the control panel;
;; the user answering Claude with c; and a file changing on disk while
;; the review is on the screen, the review following it with the
;; difference being read and the comments kept.
;;
;; No model is asked anything.  The tools are called the way the CLI
;; calls them, and a tool finishing is `ecc-tool-finished-hook' run as
;; the dispatcher runs it, so the scene costs nothing.  The session is a
;; real one.
;;
;; Every step reports what it found, and the scene ends by saving those
;; reports to /tmp/ecc-demo-review-agent-ediff-log.txt, which is what
;; the run is judged from.
;;
;; Played by demo/scenes/review-agent-ediff.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-agent)
(require 'ecc-mcp)

(defvar demo-session nil "The session the review belongs to.")

;;;; The project

(defun demo-calc (&rest extra-top)
  "The text of calc.py, as changed by the session, with EXTRA-TOP lines above."
  (concat (mapconcat (lambda (line) (concat line "\n")) extra-top "")
          "def add(a, b):\n    \"\"\"Add two numbers.\"\"\"\n"
          "    return a + b\n\n\n"
          "def sub(a, b):\n    result = a - b\n    return result\n\n\n"
          "def mul(a, b):\n    return a * b\n"))

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el."
  (setq ecc-review-style 'ediff
        ecc-review-auto-refresh t)
  (demo-fresh-repository)
  (demo-write "calc.py" (concat "def add(a, b):\n    return a + b\n\n\n"
                                "def sub(a, b):\n    return a - b\n\n\n"
                                "def mul(a, b):\n    return a * b\n"))
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "calc.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   ecc-review-style = %S   ecc-review-auto-refresh = %S"
                    (ecc-version) ecc-review-style ecc-review-auto-refresh))
  nil)

(defun demo-start-session ()
  "Start the session; its baseline is the tree as committed."
  (setq demo-session (ecc-start demo-root "review-ediff"))
  nil)

(defun demo-claude-edits ()
  "Change calc.py the way the session would have: after it started."
  (demo-write "calc.py" (demo-calc))
  (demo-say "calc.py changed since the session started")
  nil)

(defun demo-open-review ()
  "Open the review as the user does with D: in ediff, taking the frame."
  (ecc-review demo-session)
  nil)

;;;; Where everything is

(defun demo-control-buffer ()
  "Return the control buffer of the review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode) ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-place-panel ()
  "Put the control panel above the frame, inside the picture."
  (demo-float)
  (with-current-buffer (demo-control-buffer)
    (when (frame-live-p ediff-control-frame)
      (set-frame-position ediff-control-frame 40 20)
      (raise-frame ediff-control-frame)))
  nil)

(defun demo-key (key &optional text prefix)
  "Run what KEY does in the control panel.  TEXT and PREFIX as in demo.el."
  (demo-run-key-in (demo-control-buffer) key text prefix))

(defun demo-line-at (buffer position)
  "The text of the line of BUFFER at POSITION."
  (with-current-buffer buffer
    (save-excursion
      (goto-char position)
      (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))

(defun demo-drawn (buffer)
  "What the comments draw in BUFFER, one line."
  (with-current-buffer (demo-control-buffer)
    (string-trim
     (replace-regexp-in-string
      "\n+" " / "
      (mapconcat (lambda (overlay)
                   (if (eq (overlay-buffer overlay) buffer)
                       (or (overlay-get overlay 'after-string)
                           (overlay-get overlay 'before-string) "")
                     ""))
                 ecc-review--comments "")))))

(defun demo-report (label)
  "Say where everything is, under LABEL, for the log."
  (with-current-buffer (demo-control-buffer)
    (let ((a ediff-window-A) (b ediff-window-B))
      (demo-say
       (format "%s | selected: %s (frame %s) | difference: %d of %d | A at %S | B at %S | stale: %S | B has import math: %S"
               label
               (buffer-name (window-buffer (selected-window)))
               (frame-parameter (selected-frame) 'name)
               (1+ ediff-current-difference) ediff-number-of-differences
               (and (window-live-p a) (demo-line-at ediff-buffer-A (window-point a)))
               (and (window-live-p b) (demo-line-at ediff-buffer-B (window-point b)))
               ecc-review--stale
               (and (string-search "import math"
                                   (with-current-buffer ediff-buffer-B (buffer-string)))
                    t)))))
  nil)

(defun demo-report-comments ()
  "Say each comment where it is, and what each side draws."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "%s || left draws: %s || right draws: %s"
                      (mapconcat #'ecc-review-note-label ecc-review--notes " / ")
                      (demo-drawn ediff-buffer-A)
                      (demo-drawn ediff-buffer-B))))
  nil)

;;;; Claude, and the CLI

(defun demo-tool (name &optional arguments)
  "Call the MCP tool NAME with ARGUMENTS as the session's CLI would."
  (let ((ecc-mcp--session-id (ecc-session-id demo-session)))
    (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool name arguments)))
      (demo-say (format "Claude called %s%s: %s" name (if failed " (FAILED)" "")
                        (string-replace "\n" " | " text)))))
  nil)

(defun demo-tool-finished (what)
  "A tool of the session has finished, having done WHAT to the files."
  (run-hook-with-args 'ecc-tool-finished-hook demo-session nil)
  (demo-say (format "A Bash call of the session finished: %s" what))
  nil)

(defun demo-shell-edit-above ()
  "Change calc.py on disk above everything, as a shell command would."
  (demo-write "calc.py" (demo-calc "import math" "" ""))
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Close the review and stop the session."
  (when-let* ((control (demo-control-buffer)))
    (ecc-review-ediff-quit control))
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Session stopped.")
  nil)

(provide 'review-agent-ediff)
;;; review-agent-ediff.el ends here
