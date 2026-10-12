;;; review-agent-comments.el --- Claude comments on the review, and nobody loses the keyboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 1 of the two-way review comments: Claude opens the review,
;; puts comments on its lines and scrolls it, over the MCP tools of
;; `ecc-review-agent.el'.  What a batch test cannot see is what this is
;; for -- that the user typing in the prompt keeps the keyboard while the
;; review comes up and moves, what Claude's comments look like, and which
;; window a review Claude opens goes into.
;;
;; No model is asked anything.  A step calls a tool the way the CLI
;; would, through `ecc-mcp-call-tool' with the session id bound, so the
;; scene costs nothing and does the same every time.  The session is a
;; real one all the same: its buffer, its window and its Space are what
;; the quiet display has to leave alone.
;;
;; Every step reports what it found -- which window is selected, what the
;; prompt says, where the review is and on which line -- and the scene
;; ends by saving those reports to /tmp/ecc-demo-review-agent-comments-log.txt,
;; which is what the run is judged from.
;;
;; Played by demo/scenes/review-agent-comments.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-agent)
(require 'ecc-mcp)

(defvar demo-session nil "The session the review belongs to.")

;;;; The project

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el."
  ;; The tools always use the diff buffer; the keys shown at the end are
  ;; the diff buffer's, and this machine's init reviews in ediff.
  (setq ecc-review-style 'diff)
  (demo-fresh-repository)
  (demo-write "calc.py" (concat "def add(a, b):\n    return a + b\n\n\n"
                                "def sub(a, b):\n    return a - b\n\n\n"
                                "def mul(a, b):\n    return a * b\n"))
  (demo-write "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "calc.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   ecc-use-spaces = %S   ecc-review-style = %S"
                    (ecc-version) ecc-use-spaces ecc-review-style))
  nil)

(defun demo-start-session ()
  "Start the session; its baseline is the tree as committed."
  (setq demo-session (ecc-start demo-root "review-agent"))
  nil)

(defun demo-claude-edits ()
  "Change both files the way the session would have: after it started."
  (demo-write "calc.py" (concat "def add(a, b):\n    \"\"\"Add two numbers.\"\"\"\n"
                                "    return a + b\n\n\n"
                                "def sub(a, b):\n    result = a - b\n    return result\n\n\n"
                                "def mul(a, b):\n    return a * b\n"))
  (demo-write "greet.py" (concat "def greet(name):\n    return f\"hello {name}!\"\n\n\n"
                                 "def farewell(name):\n    return f\"bye {name}\"\n"))
  (demo-say "calc.py and greet.py changed since the session started")
  nil)

;;;; Where everything is

(defun demo-session-window ()
  "The window of the session, on this frame."
  (get-buffer-window (ecc-session-buffer demo-session)))

(defun demo-review (&optional range)
  "The review buffer of the session, of RANGE when given."
  (get-buffer (ecc-review-buffer-name demo-session nil range)))

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
  (let* ((review (seq-find (lambda (buffer) (get-buffer-window buffer))
                           (delq nil (list (demo-review) (demo-review "HEAD")))))
         (window (and review (get-buffer-window review))))
    (demo-say
     (format "%s | selected: %s | prompt: %S | review: %s | windows: %d | tab: %s"
             label
             (buffer-name (window-buffer (selected-window)))
             (demo-prompt-text)
             (if window
                 (format "%s at %S (top %S)" (buffer-name review)
                         (demo-line-at review (window-point window))
                         (demo-line-at review (window-start window)))
               "not shown")
             (length (window-list))
             (and (fboundp 'tab-bar--current-tab)
                  (alist-get 'name (tab-bar--current-tab))))))
  nil)

(defun demo-report-comments ()
  "Say what the review's header line counts, and each comment where it is."
  (with-current-buffer (demo-review)
    (demo-say (format "%s || %s"
                      (ecc-review--count-string)
                      (mapconcat #'ecc-review-note-label ecc-review--notes " / ")))
    ;; Line by line, with the face of that line's own "#": a reply is
    ;; drawn in the same string as the comment it answers, and has a face
    ;; of its own.
    (dolist (overlay (ecc-review-comment-overlays))
      (dolist (line (split-string (or (overlay-get overlay 'after-string)
                                      (overlay-get overlay 'before-string))
                                  "\n" t))
        (message "drawn: %S face %S"
                 (substring-no-properties line)
                 (when-let* ((hash (string-search "#" line)))
                   (get-text-property hash 'face line))))))
  nil)

;;;; The tools, called as the CLI calls them

(defun demo-tool (name &optional arguments)
  "Call the MCP tool NAME with ARGUMENTS as the session's CLI would."
  (let ((ecc-mcp--session-id (ecc-session-id demo-session)))
    (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool name arguments)))
      (message "[%s%s]\n%s" name (if failed " FAILED" "") text)
      (demo-say (format "Claude called %s%s: %s" name (if failed " (FAILED)" "")
                        (car (split-string text "\n"))))))
  nil)

;;;; The user

(defun demo-type-in-prompt (text)
  "Be in the session's prompt and type TEXT, as the user would."
  (let ((window (demo-session-window)))
    (select-window window)
    (with-current-buffer (window-buffer window)
      ;; The end of the draft, not of the buffer: the footer under the
      ;; prompt is read-only.
      (ecc-chat-goto-prompt)
      (insert text)
      (set-window-point window (point))))
  nil)

(defun demo-keep-typing (text)
  "Type TEXT wherever the keyboard is -- which must still be the prompt."
  (if (eq (window-buffer (selected-window)) (ecc-session-buffer demo-session))
      ;; A step arrives with emacsclient's buffer current, whatever the
      ;; selected window shows.
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
  "Run what KEY does in the review that is on the screen."
  (demo-run-key-in (or (seq-find #'get-buffer-window
                                 (delq nil (list (demo-review "HEAD") (demo-review))))
                       (demo-review))
                   key text))

(defun demo-go-to-source ()
  "Go to the source window, as the user would: click into the code."
  (let ((window (seq-find (lambda (window)
                            (not (ecc-window-own-buffer-p (window-buffer window))))
                          (window-list))))
    (if window
        (progn (select-window window)
               (switch-to-buffer (find-file-noselect (expand-file-name "greet.py" demo-root))))
      (demo-say "WRONG: no window of code is left on the screen")))
  nil)

(defun demo-edit-above ()
  "Change calc.py on disk above the commented lines."
  (demo-write "calc.py" (concat "import math\n\n\n"
                                "def add(a, b):\n    \"\"\"Add two numbers.\"\"\"\n"
                                "    return a + b\n\n\n"
                                "def sub(a, b):\n    result = a - b\n    return result\n\n\n"
                                "def mul(a, b):\n    return a * b\n"))
  (demo-say "Three lines added at the top of calc.py, above every comment")
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop the session."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Session stopped.")
  nil)

(provide 'review-agent-comments)
;;; review-agent-comments.el ends here
