;;; review-comment-follows-line.el --- A sent line comment follows its line down  -*- lexical-binding: t; -*-

;;; Commentary:

;; A comment on a line of the diff review, sent with C-c C-c, and then
;; two lines put in right above that line, in the same hunk: the review
;; following the files reads the diff again and the comment is still on
;; its line, two lines further down and still dimmed as sent.  Before the
;; fix of 2026-10-11 it went "[outdated, was L10 (new)]": the line above
;; it had changed, and that was taken for the line itself changing.
;;
;; No model is asked anything.  The prompt C-c C-c sends is caught on its
;; way to the CLI and written to the log, the edits are written straight
;; to the file, and the review hears of them the way it hears of a tool
;; of the session finishing.  The session is a real one all the same.
;;
;; Every step reports what it found, and the scene ends by saving those
;; reports to /tmp/ecc-demo-review-comment-follows-line-log.txt.
;;
;; Played by demo/scenes/review-comment-follows-line.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-agent)
(require 'ecc-mcp)

(defvar demo-session nil "The session the review belongs to.")

(defvar demo-prompts nil "The prompts C-c C-c sent, newest first.")

(defconst demo-summary
  (concat "class Summary:\n"
          "    def __init__(self, rows):\n"
          "        self.rows = rows\n"
          "\n"
          "    def total(self):\n"
          "        return sum(self.rows)\n")
  "summary.py as committed.")

(defconst demo-share
  (concat demo-summary
          "\n"
          "    def share(self, part):\n"
          "        total = self.total()\n"
          "        return part / total\n")
  "summary.py once share() is added: its return is L10.")

;;;; The project

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el."
  (setq ecc-review-style 'diff)
  (demo-fresh-repository)
  (demo-write "summary.py" demo-summary)
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "summary.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   ecc-review-style = %S   ecc-review-auto-refresh = %S"
                    (ecc-version) ecc-review-style ecc-review-auto-refresh))
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
  (setq demo-session (ecc-start demo-root "comment-follows-line"))
  nil)

(defun demo-claude-writes (text say)
  "Make summary.py TEXT, as a tool of the session would, and SAY so."
  (demo-write "summary.py" text)
  (with-current-buffer (find-buffer-visiting (expand-file-name "summary.py" demo-root))
    (revert-buffer t t t))
  ;; What a tool of the session finishing does: the review is marked
  ;; stale and read again once Emacs is idle.
  (ecc-review--on-session-change demo-session)
  (demo-say say)
  nil)

;;;; Where everything is

(defun demo-review ()
  "The review buffer of the session."
  (get-buffer (ecc-review-buffer-name demo-session)))

(defun demo-report (label)
  "Say, under LABEL, where each comment is and how it is drawn."
  (let ((review (demo-review)))
    (if (not (buffer-live-p review))
        (demo-say (format "%s | review: CLOSED" label))
      (with-current-buffer review
        (demo-say
         (format "%s | %s | %s" label (ecc-review--count-string)
                 (mapconcat (lambda (note)
                              (format "#%d L%s %s%s%s"
                                      (ecc-review-note-id note)
                                      (ecc-review-note-line note)
                                      (ecc-review-note-side note)
                                      (if (ecc-review-note-sent note) " sent" "")
                                      (if (ecc-review-note-outdated note) " OUTDATED" "")))
                            ecc-review--notes ", ")))
        (dolist (overlay (ecc-review-comment-overlays))
          (message "drawn under %S: %S"
                   (save-excursion
                     (goto-char (overlay-start overlay))
                     (buffer-substring-no-properties (line-beginning-position)
                                                     (line-end-position)))
                   (substring-no-properties
                    (or (overlay-get overlay 'after-string)
                        (overlay-get overlay 'before-string))))))))
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

(defun demo-open-review ()
  "Open the session's review, as `ecc-review' does."
  (let ((ecc-mcp--session-id (ecc-session-id demo-session)))
    (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool "review_open" nil)))
      (demo-say (format "review_open%s: %s" (if failed " FAILED" "")
                        (car (split-string text "\n"))))))
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop the session and let prompts go to the CLI again."
  (advice-remove 'ecc-proc-send-prompt 'demo-catch-prompts)
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Session stopped.")
  nil)

(provide 'review-comment-follows-line)
;;; review-comment-follows-line.el ends here
