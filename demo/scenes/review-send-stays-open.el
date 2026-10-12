;;; review-send-stays-open.el --- C-c C-c sends the new comments and keeps the review  -*- lexical-binding: t; -*-

;;; Commentary:

;; C-c C-c in a review of files sends the comments and leaves the review
;; open: the sent ones stay, dimmed, for Claude's replies, the header
;; line counts them, and the next C-c C-c sends only those made since.
;; What a batch test cannot see is how that looks -- the dimmed comment
;; next to a new one, Claude's reply under it, the review still there.
;;
;; No model is asked anything.  The prompt C-c C-c sends is caught on its
;; way to the CLI (`demo-catch-prompts') and written to the log instead,
;; and Claude's replies are made through the MCP tool the CLI would call.
;; The session is a real one all the same.
;;
;; Every step reports what it found, and the scene ends by saving those
;; reports to /tmp/ecc-demo-review-send-stays-open-log.txt, which is what
;; the run is judged from.
;;
;; Played by demo/scenes/review-send-stays-open.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-agent)
(require 'ecc-mcp)

(defvar demo-session nil "The session the review belongs to.")

(defvar demo-prompts nil "The prompts C-c C-c sent, newest first.")

;;;; The project

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el."
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

(defun demo-catch-prompts ()
  "Keep the prompts C-c C-c sends here instead of sending them."
  (advice-add 'ecc-proc-send-prompt :override
              (lambda (_session text)
                (push text demo-prompts)
                (message "[prompt %d]\n%s\n[end of prompt %d]"
                         (length demo-prompts) text (length demo-prompts))
                'sent)
              '((name . demo-catch-prompts)))
  nil)

(defun demo-start-session ()
  "Start the session; its baseline is the tree as committed."
  (setq demo-session (ecc-start demo-root "send-stays-open"))
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

(defun demo-review ()
  "The review buffer of the session."
  (get-buffer (ecc-review-buffer-name demo-session)))

(defun demo-report (label)
  "Say, under LABEL, whether the review is open and what it holds."
  (let ((review (demo-review)))
    (if (not (buffer-live-p review))
        (demo-say (format "%s | review: CLOSED" label))
      (with-current-buffer review
        (demo-say (format "%s | review: %s | %s | prompts sent: %d"
                          label
                          (if (get-buffer-window review) "open, on the screen" "open, not shown")
                          (ecc-review--count-string)
                          (length demo-prompts)))
        (dolist (overlay (ecc-review-comment-overlays))
          (dolist (line (split-string (or (overlay-get overlay 'after-string)
                                          (overlay-get overlay 'before-string))
                                      "\n" t))
            (message "drawn: %S face %S"
                     (substring-no-properties line)
                     (when-let* ((hash (string-search "#" line)))
                       (get-text-property hash 'face line))))))))
  nil)

(defun demo-last-prompt ()
  "Say which comments the last prompt carried."
  (demo-say
   (if demo-prompts
       (format "Prompt %d carried: %s" (length demo-prompts)
               (string-join (mapcar (lambda (line) (substring line 9))
                                    (seq-filter (lambda (line) (string-prefix-p "Comment: " line))
                                                (split-string (car demo-prompts) "\n")))
                            " / "))
     "No prompt was sent"))
  nil)

;;;; Claude, called as the CLI calls it

(defun demo-tool (name &optional arguments)
  "Call the MCP tool NAME with ARGUMENTS as the session's CLI would."
  (let ((ecc-mcp--session-id (ecc-session-id demo-session)))
    (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool name arguments)))
      (message "[%s%s]\n%s" name (if failed " FAILED" "") text)
      (demo-say (format "Claude called %s%s: %s" name (if failed " (FAILED)" "")
                        (car (split-string text "\n"))))))
  nil)

;;;; The user

(defun demo-go-to-review-line (text)
  "Go to the review, as the user would, and to the line that is TEXT."
  (let ((window (get-buffer-window (demo-review))))
    (select-window window)
    (goto-char (point-min))
    (re-search-forward (concat "^" (regexp-quote text) "$"))
    (beginning-of-line)
    (set-window-point window (point)))
  nil)

(defun demo-key (key &optional text prefix)
  "Run what KEY does in the review."
  (demo-run-key-in (demo-review) key text prefix))

(defun demo-message-key (key)
  "Run what KEY does in the buffer C-u C-c C-c opened to read the prompt over."
  (demo-run-key-in (ecc-review-message-buffer-name demo-session) key))

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop the session and let prompts go to the CLI again."
  (advice-remove 'ecc-proc-send-prompt 'demo-catch-prompts)
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Session stopped.")
  nil)

(provide 'review-send-stays-open)
;;; review-send-stays-open.el ends here
