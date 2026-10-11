;;; review-agent-watch.el --- The review follows the files, and nobody loses the keyboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 2 of the two-way review comments: an open review follows the
;; files (`ecc-review-auto-refresh').  What a batch test cannot see is
;; what this is for -- that a file changing on disk shows up in the review
;; on the screen by itself, with the comments and the place kept, while
;; the user typing in the prompt keeps the keyboard and the windows stay
;; where they are; and that a review out of sight is read again only when
;; it is shown.
;;
;; No model is asked anything.  Claude's review_open is called the way
;; the CLI calls it, and a tool finishing is `ecc-tool-finished-hook' run
;; as the dispatcher runs it on a tool result, so the scene costs nothing
;; and does the same every time.  The session is a real one.
;;
;; Every step reports what it found, and the scene ends by saving those
;; reports to /tmp/ecc-demo-review-agent-watch-log.txt, which is what the
;; run is judged from.
;;
;; Played by demo/scenes/review-agent-watch.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-agent)
(require 'ecc-mcp)

(defvar demo-session nil "The session the review belongs to.")

(defvar demo-hidden-in nil "The window the review was taken out of.")

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
  (setq ecc-review-style 'diff
        ecc-review-auto-refresh t)
  (demo-fresh-repository)
  (demo-write "calc.py" (concat "def add(a, b):\n    return a + b\n\n\n"
                                "def sub(a, b):\n    return a - b\n\n\n"
                                "def mul(a, b):\n    return a * b\n"))
  (demo-write "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "calc.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   ecc-use-spaces = %S   ecc-review-auto-refresh = %S"
                    (ecc-version) ecc-use-spaces ecc-review-auto-refresh))
  nil)

(defun demo-start-session ()
  "Start the session; its baseline is the tree as committed."
  (setq demo-session (ecc-start demo-root "review-watch"))
  nil)

(defun demo-claude-edits ()
  "Change calc.py the way the session would have: after it started."
  (demo-write "calc.py" (demo-calc))
  (demo-say "calc.py changed since the session started")
  nil)

;;;; Where everything is

(defun demo-session-window ()
  "The window of the session, on this frame."
  (get-buffer-window (ecc-session-buffer demo-session)))

(defun demo-review ()
  "The review buffer of the session."
  (get-buffer (ecc-review-buffer-name demo-session)))

(defun demo-prompt-text ()
  "What is typed in the session's prompt."
  (with-current-buffer (ecc-session-buffer demo-session)
    (ecc-chat-draft)))

(defun demo-line-at (buffer position)
  "The text of the line of BUFFER at POSITION."
  (with-current-buffer buffer
    (save-excursion
      (goto-char position)
      (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))

(defun demo-report (label)
  "Say where everything is, under LABEL, for the log."
  (let* ((review (demo-review))
         (window (and review (get-buffer-window review))))
    (demo-say
     (format "%s | selected: %s | prompt: %S | review: %s | stale: %S | files: %s | has: %s | windows: %d | tab: %s"
             label
             (buffer-name (window-buffer (selected-window)))
             (demo-prompt-text)
             (if window
                 (format "at %S (top %S)"
                         (demo-line-at review (window-point window))
                         (demo-line-at review (window-start window)))
               "not shown")
             (and review (buffer-local-value 'ecc-review--stale review))
             (if review
                 (with-current-buffer review
                   (mapconcat #'identity (ecc-review-agent--paths) ", "))
               "-")
             (if review
                 (with-current-buffer review
                   (mapconcat (lambda (line)
                                (format "%s=%S" line
                                        (and (string-search (concat "\n" line "\n")
                                                            (buffer-string))
                                             t)))
                              '("+import math" "+def farewell(name):" "+def div(a, b):")
                              " "))
               "-")
             (length (window-list))
             (and (fboundp 'tab-bar--current-tab)
                  (alist-get 'name (tab-bar--current-tab))))))
  nil)

(defun demo-report-comments ()
  "Say what the review's header line counts, and each comment where it is."
  (with-current-buffer (demo-review)
    (demo-say (format "%s || %s"
                      (ecc-review--count-string)
                      (mapconcat #'ecc-review-note-label ecc-review--notes " / "))))
  nil)

(defun demo-report-top ()
  "Say what the first lines of the review are."
  (with-current-buffer (demo-review)
    (demo-say (format "review starts: %S"
                      (buffer-substring-no-properties
                       (point-min) (min (point-max) (+ (point-min) 160))))))
  nil)

;;;; Claude, and the CLI

(defun demo-tool (name &optional arguments)
  "Call the MCP tool NAME with ARGUMENTS as the session's CLI would."
  (let ((ecc-mcp--session-id (ecc-session-id demo-session)))
    (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool name arguments)))
      (demo-say (format "Claude called %s%s: %s" name (if failed " (FAILED)" "")
                        (car (split-string text "\n"))))))
  nil)

(defun demo-tool-finished (what)
  "A tool of the session has finished, having done WHAT to the files.
Run as the dispatcher runs it when a tool result arrives."
  (run-hook-with-args 'ecc-tool-finished-hook demo-session nil)
  (demo-say (format "A Bash call of the session finished: %s" what))
  nil)

(defun demo-shell-edit-above ()
  "Change calc.py on disk above the commented lines, as a shell command would."
  (demo-write "calc.py" (demo-calc "import math" "" ""))
  nil)

(defun demo-shell-edit-below ()
  "Change calc.py again, at its end."
  (demo-write "calc.py" (concat (demo-calc "import math" "" "")
                                "\n\ndef div(a, b):\n    return a / b\n"))
  nil)

(defun demo-save-greet ()
  "Save greet.py from a buffer of Emacs, without going to it."
  (with-current-buffer (find-file-noselect (expand-file-name "greet.py" demo-root))
    (goto-char (point-max))
    (insert "\n\ndef farewell(name):\n    return \"bye \" + name\n")
    (save-buffer))
  (demo-say "greet.py was saved in Emacs (in a buffer nobody is looking at)")
  nil)

(defun demo-revert-all ()
  "Put every file back as it was committed, as git checkout would."
  (when-let* ((buffer (get-file-buffer (expand-file-name "greet.py" demo-root))))
    (with-current-buffer buffer (set-buffer-modified-p nil))
    (kill-buffer buffer))
  (demo-git "checkout" "--" ".")
  nil)

;;;; The user

(defun demo-type-in-prompt (text)
  "Be in the session's prompt and type TEXT, as the user would."
  (let ((window (demo-session-window)))
    (select-window window)
    (with-current-buffer (window-buffer window)
      (ecc-chat-goto-prompt)
      (insert text)
      (set-window-point window (point))))
  nil)

(defun demo-keep-typing (text)
  "Type TEXT wherever the keyboard is -- which must still be the prompt."
  (if (eq (window-buffer (selected-window)) (ecc-session-buffer demo-session))
      (with-current-buffer (window-buffer (selected-window))
        (ecc-chat-goto-prompt)
        (insert text)
        (set-window-point (selected-window) (point))
        (demo-say (format "Still in the prompt: %S" (demo-prompt-text))))
    (demo-say (format "WRONG: the keyboard is in %s now"
                      (buffer-name (window-buffer (selected-window))))))
  nil)

(defun demo-go-to-review-line (text)
  "Go to the review, as the user would, and to the line that is TEXT."
  (let ((window (get-buffer-window (demo-review))))
    (select-window window)
    (goto-char (point-min))
    (re-search-forward (concat "^" (regexp-quote text) "$"))
    (beginning-of-line)
    (set-window-point window (point)))
  nil)

(defun demo-key (key &optional text)
  "Run what KEY does in the review."
  (demo-run-key-in (demo-review) key text))

(defun demo-hide-review ()
  "Put calc.py where the review was, without selecting that window."
  (let ((window (get-buffer-window (demo-review))))
    (setq demo-hidden-in window)
    (set-window-buffer window (find-file-noselect (expand-file-name "calc.py" demo-root))))
  (demo-say "The review is out of sight: its window shows calc.py now")
  nil)

(defun demo-show-review ()
  "Put the review back in the window it left, without selecting it."
  (set-window-buffer demo-hidden-in (demo-review))
  (demo-say "The review is shown again")
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop the session."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Session stopped.")
  nil)

(provide 'review-agent-watch)
;;; review-agent-watch.el ends here
