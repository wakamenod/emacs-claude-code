;;; task-notification.el --- A CLI task notification is not a prompt  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of fix/task-notification-prompt.  A CLI that resumes a
;; session whose previous process left a background task behind injects
;; a <task-notification> into the conversation as a plain `user'
;; message, and until this branch every reader of a recording took it
;; for a prompt the user had typed.
;;
;; There is no need to invent one: this machine's own recordings hold
;; several dozen.  The scene finds one -- the kind the bug was reported
;; on first, the notice about a task the previous process left running
;; -- cuts the turns up to it out into a recording of its own, and opens
;; that recording twice: once with the filter of this branch switched
;; off, which is the bug as it was reported, and once with it on.  Then
;; it hands the same notice to the live stream, which is the other way
;; in.
;;
;; Played by demo/scenes/task-notification.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc-history)
(require 'ecc-protocol)
(require 'ecc-dispatch)
(require 'ecc-render)

(defvar demo-recording (expand-file-name "task-notice.jsonl" demo-root)
  "The excerpt of a real recording this scene is played on.")

(defvar demo-source nil
  "The recording the excerpt was cut from.")

(defvar demo-notice-text nil
  "The notice the CLI wrote, as it stands in that recording.")

(defvar demo-before nil
  "The session the recording is read into with the fix switched off.")

(defvar demo-after nil
  "The session the recording is read into with the fix on.")

;;;; Finding a real notice

(defun demo-notice-line-p (line)
  "Return non-nil when LINE of a recording is an injected task notice."
  (when-let* ((message (ecc-protocol-history-parse line)))
    (and (equal (alist-get 'type message) "user")
         (equal (ecc-protocol-origin-kind message) "task-notification"))))

(defun demo-prompt-line-p (line)
  "Return non-nil when LINE of a recording is a prompt somebody typed."
  (when-let* ((message (ecc-protocol-history-parse line)))
    (and (equal (alist-get 'type message) "user")
         (not (equal (ecc-protocol-origin-kind message) "task-notification"))
         (ecc-protocol-history-prompt message))))

(defun demo-notice-index (lines)
  "Return the index of the first injected task notice among LINES, or nil."
  (cl-loop for i from 0 for line in lines
           when (demo-notice-line-p line) return i))

(defun demo-line-text (lines index)
  "Return the text of the message LINES holds at INDEX."
  (ecc-protocol-history-text (ecc-protocol-history-parse (nth index lines))))

(defun demo-excerpt (lines index)
  "Return the turns of LINES up to and including the notice at INDEX.
The notice is left at the end, which is where the round trip of `t' and
`/exit' puts it; it is then also what the resume list and the dashboard
call the session's last prompt.  The `last-prompt' lines are left out:
they name a leaf that is not in the excerpt, and every line would look
like an abandoned branch."
  (let ((start (or (cl-loop for i downfrom (1- index) to 0
                            with seen = 0
                            when (demo-prompt-line-p (nth i lines))
                            do (cl-incf seen)
                            when (>= seen 2) return i)
                   0)))
    (seq-remove (lambda (line) (string-match-p "\"last-prompt\"" line))
                (seq-subseq lines start (1+ index)))))

(defun demo-candidates ()
  "Return the recordings that hold a task notice, the reported kind first.
The bug was reported on what a resume writes about a task the previous
process left running, which says `stopped'; the others are the same
message about a task that ended while the session was up."
  (let (stopped others)
    (dolist (file (ecc-history-files))
      (let* ((lines (ecc-history-lines file))
             (index (demo-notice-index lines)))
        (when (and index (> index 0))
          (if (string-match-p "<status>stopped</status>"
                              (or (demo-line-text lines index) ""))
              (push (list file lines index) stopped)
            (push (list file lines index) others)))))
    (append (nreverse stopped) (nreverse others))))

(defun demo-cut-a-recording ()
  "Write the turns up to a real task notice into `demo-recording'.
Returns the file, or nil when this machine has no such recording."
  (when-let* ((candidate (car (demo-candidates))))
    (pcase-let ((`(,file ,lines ,index) candidate))
      (setq demo-source file
            demo-notice-text (demo-line-text lines index))
      (demo-write (file-name-nondirectory demo-recording)
                  (concat (string-join (demo-excerpt lines index) "\n") "\n"))
      demo-recording)))

;;;; What the scene is played on

(defun demo-scene-build ()
  "Cut the recording out and say what it is.  Called by demo.el."
  (demo-fresh-repository)
  (unless (demo-cut-a-recording)
    (error "No recording on this machine holds a task notification"))
  (find-file demo-recording)
  (goto-char (point-min))
  (demo-say (format "ecc from %s" (abbreviate-file-name (locate-library "ecc"))))
  nil)

(defun demo-show-the-notice ()
  "Say what the CLI wrote into the conversation, by its own summary."
  (demo-say (format "The CLI injected a <task-notification>: %s"
                    (or (ecc-protocol-task-notification-summary demo-notice-text)
                        "?")))
  nil)

(defun demo-show-the-line ()
  "Show the recorded line itself: a plain user message, origin and all."
  (with-current-buffer (find-file-noselect demo-recording)
    (goto-char (point-max))
    (forward-line -1)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (set-window-point window (point))
      (with-selected-window window (recenter -2))))
  (demo-say "No isMeta, no sidechain, no local command: only origin.kind says who wrote it")
  nil)

;;;; The two readings

(defun demo-read-into (id name)
  "Read `demo-recording' into a session called NAME with the id ID."
  (let ((session (ecc-history-session id demo-recording)))
    (setf (ecc-session-name session) name)
    (ecc-session-ensure-buffer session)
    (ecc-history-load session 8 demo-recording)
    (ecc-display-session session)
    (demo-frame)
    session))

(defun demo-with-the-fix-off (function)
  "Call FUNCTION with the filter of this branch switched off.
That is the code as it was: nothing tells the injected notice from a
prompt, so `ecc-protocol-history-prompt' takes it for one."
  (let ((injected (symbol-function 'ecc-protocol-injected-p))
        (notice (symbol-function 'ecc-protocol-task-notification-p)))
    (unwind-protect
        (progn (fset 'ecc-protocol-injected-p #'ignore)
               (fset 'ecc-protocol-task-notification-p #'ignore)
               (funcall function))
      (fset 'ecc-protocol-injected-p injected)
      (fset 'ecc-protocol-task-notification-p notice))))

(defun demo-open-before ()
  "Read the recording the way the reported bug had it read."
  (setq demo-before (demo-with-the-fix-off
                     (lambda () (demo-read-into "demo-before" "before"))))
  nil)

(defun demo-open-after ()
  "Read the same recording with this branch's filter in place."
  (setq demo-after (demo-read-into "demo-after" "after"))
  nil)

;;;; What each reading did with it

(defun demo-goto-notice (session)
  "Put point on what SESSION made of the notice.
The heading is looked for first and the notice itself only failing
that: the note keeps the whole of what the CLI wrote under its fold, so
a search for the notice finds the body of the note rather than the
heading, and `ecc-chat-toggle\=' on a body line folds rather than
unfolds.  Point is left on the text, not at the start of the line: the
padding before the fold cell carries no node at all."
  (when-let* ((buffer (ecc-session-buffer session))
              (window (get-buffer-window buffer t)))
    (with-selected-window window
      (goto-char (point-max))
      (when (or (re-search-backward "background task" nil t)
                (progn (goto-char (point-max))
                       (re-search-backward "<task-notification>" nil t)))
        (goto-char (match-beginning 0))
        (recenter -4))))
  nil)

(defun demo-goto-notice-before ()
  "Put point on the notice as the reading with the fix off drew it."
  (demo-goto-notice demo-before))

(defun demo-goto-notice-after ()
  "Put point on the note the reading with the fix on made of it."
  (demo-goto-notice demo-after))

(defun demo-report-turns (session what)
  "Say what SESSION made of the notice, calling the reading WHAT."
  (let* ((prompts (seq-filter #'identity
                              (mapcar #'ecc-turn-prompt
                                      (ecc-session-turns session))))
         (opened (seq-find (lambda (prompt)
                             (string-prefix-p "<task-notification>"
                                              (string-trim prompt)))
                           prompts)))
    (demo-say (format "%s: %d turns, %s"
                      what (length prompts)
                      (if opened
                          "the last one opened by the notice, under the user mark"
                        "none of them opened by the notice"))))
  nil)

(defun demo-report-turns-before ()
  "Say what the reading with the fix off made of it."
  (demo-report-turns demo-before "Before"))

(defun demo-report-turns-after ()
  "Say what the reading with the fix on made of it."
  (demo-report-turns demo-after "After"))

(defun demo-report-resume-line (what)
  "Say what the resume list and the dashboard call the last prompt, as WHAT."
  (let ((info (ecc-history-scan-file demo-recording)))
    (demo-say (format "%s -- last prompt in the resume list and the dashboard: %s"
                      what
                      (ecc--truncate
                       (string-join
                        (split-string (or (alist-get 'prompt info) "(none)") "\n" t)
                        " ")
                       80))))
  nil)

(defun demo-report-resume-line-before ()
  "Say what that list said before the fix."
  (demo-with-the-fix-off (lambda () (demo-report-resume-line "Before"))))

(defun demo-report-resume-line-after ()
  "Say what that list says now."
  (demo-report-resume-line "After"))

(defun demo-notice-nodes (session)
  "Return the nodes SESSION kept a task notice on."
  (seq-filter (lambda (node)
                (eq 'task-notice (ecc-model-node-get node 'kind)))
              (hash-table-values (ecc-session-nodes session))))

(defun demo-report-note ()
  "Say how the note reads."
  (let ((node (car (demo-notice-nodes demo-after))))
    (demo-say (format "A folded note beside the conversation: %s"
                      (if node (ecc-render--system-heading node) "(none)"))))
  nil)

(defun demo-unfold-note ()
  "Open the fold the notice itself waits under, where point is."
  (demo-run-key-in (ecc-session-buffer demo-after) "TAB"))

;;;; The live stream

(defun demo-live-notice ()
  "Hand the same notice to the dispatcher, the way the stream brings it."
  (let ((turns (length (seq-filter #'ecc-turn-prompt
                                   (ecc-session-turns demo-after))))
        (notes (length (demo-notice-nodes demo-after))))
    (ecc-dispatch demo-after
                  `((type . "user")
                    (origin . ((kind . "task-notification")))
                    (message . ((role . "user") (content . ,demo-notice-text)))))
    (ecc-render-flush demo-after)
    (demo-say (format "The live stream agrees: turns %d -> %d, notes %d -> %d"
                      turns (length (seq-filter #'ecc-turn-prompt
                                                (ecc-session-turns demo-after)))
                      notes (length (demo-notice-nodes demo-after)))))
  nil)

(provide 'task-notification)
;;; task-notification.el ends here
