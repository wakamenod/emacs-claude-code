;;; review-ediff-feedback.el --- Header keys, the file at point, the reply pane's colours  -*- lexical-binding: t; -*-

;;; Commentary:

;; What a batch test cannot see of feat/review-ediff-feedback, on a
;; real frame with the user's own init and theme:
;;
;; - one above the other, both header lines are the same line of keys
;;   and nothing else, fitted to the width, and a narrower window -- the
;;   files pane shown -- drops keys from the end and keeps `? all keys';
;; - the mode line of each window says the file its point is in, and
;;   follows n and p across a file, C-n and v; the right one goes on
;;   with `N/M' and what a filter hides;
;; - side by side, the keys are cut in two again and the mode lines
;;   still say the file and where the review is;
;; - the reply pane coloured as the transcript: the prompt, a tool line,
;;   the reply in the assistant face while it streams and its Markdown
;;   once it is done.
;;
;; No model is asked anything: the session is an archived one whose
;; process is a `cat', and what Claude would say is handed to
;; `ecc-dispatch' the way the process filter hands it a line, as
;; review-talk.el does.  Keys of the review are typed with
;; `execute-kbd-macro' in the window they belong to, as review-layout.el
;; does, so that the hooks after a command run.
;;
;; Every step reports what it found -- the header lines, the mode lines,
;; the widths, the faces in the pane -- and the scene ends by saving the
;; reports to /tmp/ecc-demo-review-ediff-feedback-log.txt.
;;
;; Played by demo/scenes/review-ediff-feedback.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-dispatch)
(require 'ecc-protocol)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-direct)
(require 'ecc-review-talk)
(require 'ecc-review-agent)

(defvar demo-session nil "The session the review belongs to.")

(defvar demo-counter 0 "Serial number of the messages this scene feeds in.")

(defun demo-lines (edit)
  "Return 70 lines of src/table.py, with EDIT, a function of N, changing some."
  (mapconcat (lambda (n)
               (or (funcall edit n)
                   (format "    row_%02d = lookup(table, %d)  # unchanged\n" n n)))
             (number-sequence 1 70) ""))

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
    (40 "    row_40 = lookup(table, 40)  # unchanged\n    cache = {}\n")
    (60 "    return total, cache\n")
    (_ nil)))

(defconst demo-cache-old
  "import os\n\n\ndef read(path, cache):\n    if path in cache:\n        return cache[path]\n    with open(path) as f:\n        text = f.read()\n    cache[path] = text\n    return text\n"
  "src/cache.py before the change.")

(defconst demo-cache-new
  "import os\n\n\ndef read(path, cache):\n    key = (path, os.stat(path).st_mtime)\n    if key in cache:\n        return cache[key]\n    with open(path) as f:\n        text = f.read()\n    cache[key] = text\n    return text\n"
  "src/cache.py after the change: keyed by path and mtime.")

(defconst demo-app-old
  "from cache import read\n\nCACHE = {}\n\n\ndef show(path):\n    print(read(path, CACHE))\n"
  "src/app.py before the change.")

(defconst demo-app-new
  "from cache import read\n\nCACHE = {}\n\n\ndef show(path):\n    text = read(path, CACHE)\n    print(text.rstrip())\n"
  "src/app.py after the change.")

;;;; What the scene is played on

(defun demo-scene-build ()
  "Build the project: three files committed, then all changed.  Called by demo.el."
  (setq ecc-review-style 'ediff
        ecc-review-files-shown nil
        ecc-review-talk-reply-height 12
        ecc-review-talk-reply-place 'auto
        ecc-review-ediff-layout 'stacked
        demo-counter 0)
  (demo-fresh-repository)
  (demo-write "src/app.py" demo-app-old)
  (demo-write "src/cache.py" demo-cache-old)
  (demo-write "src/table.py" (demo-lines #'demo-old))
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-write "src/app.py" demo-app-new)
  (demo-write "src/cache.py" demo-cache-new)
  (demo-write "src/table.py" (demo-lines #'demo-new))
  (find-file (expand-file-name "src/table.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s from %s   theme %S   ecc-use-spaces %S"
                    (ecc-version) (file-name-directory (locate-library "ecc-review-direct"))
                    custom-enabled-themes ecc-use-spaces))
  nil)

(defun demo-open-session ()
  "Make the session, with MCP and a cat for a process."
  (setq demo-session (ecc-model-create-session
                      :id "demo-review-ediff-feedback"
                      :name "feedback"
                      :project-root demo-root
                      :kind 'archived
                      :options '(:mcp t)))
  (setf (ecc-session-process demo-session)
        (make-process :name "demo-review-ediff-feedback-cat" :command '("cat")
                      :connection-type 'pipe :noquery t
                      :filter #'ignore))
  (ecc-model-set-state demo-session 'idle)
  nil)

(defun demo-open-ediff ()
  "Open the review of everything uncommitted, in ediff, as G opens it."
  (ecc-review-range demo-session "HEAD" demo-root)
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

(defun demo-header-string (header)
  "Return HEADER as text, a stretch of space written as [->ALIGN-TO]."
  (let ((out "") (i 0))
    (while (< i (length header))
      (let ((next (or (next-single-property-change i 'display header) (length header)))
            (display (get-text-property i 'display header)))
        (setq out (concat out (if (eq (car-safe display) 'space)
                                  (format "[->%S]" (plist-get (cdr display) :align-to))
                                (substring-no-properties header i next))))
        (setq i next)))
    out))

(defun demo-line-of (window)
  "Return the line of its buffer WINDOW has point on."
  (with-current-buffer (window-buffer window)
    (line-number-at-pos (window-point window))))

(defun demo-report (label)
  "Say, under LABEL, the layout, both header lines and both mode lines."
  (let* ((control (demo-control-buffer))
         (a (demo-side-window 'A))
         (b (demo-side-window 'B)))
    (with-current-buffer control
      (demo-say
       (format "[%s] %s; widths A %d B %d; difference %s/%d; keyboard in %s"
               label
               (if (< (cadr (window-edges a)) (cadr (window-edges b))) "STACKED" "SIDE BY SIDE")
               (window-width a) (window-width b)
               (if (ediff-valid-difference-p ediff-current-difference)
                   (1+ ediff-current-difference) "-")
               ediff-number-of-differences
               (let ((selected (frame-selected-window (demo-main-frame))))
                 (cond ((eq selected a) "A") ((eq selected b) "B")
                       (t (buffer-name (window-buffer selected)))))))
      (dolist (side '(A B))
        (let ((buffer (if (eq side 'A) ediff-buffer-A ediff-buffer-B))
              (window (if (eq side 'A) a b)))
          (demo-say (format "[%s] %s header (%d cols): %s" label side
                            (string-width (ecc-review-direct-header-text buffer window))
                            (demo-header-string
                             (ecc-review-direct-header-text buffer window))))
          (demo-say (format "[%s] %s mode line: %s   (point on line %d; %S)" label side
                            (substring-no-properties (ecc-review-direct-mode-line-text buffer))
                            (demo-line-of window)
                            (buffer-local-value 'mode-line-buffer-identification buffer)))))
      (demo-say (format "[%s] headers equal: %S" label
                        (equal (ecc-review-direct-header-text ediff-buffer-A a)
                               (ecc-review-direct-header-text ediff-buffer-B b))))))
  nil)

(defun demo-faces-at (string &optional skip-prompt)
  "Return the faces at the start of STRING in the reply pane, or `absent'.
SKIP-PROMPT looks under the prompt line."
  (let ((pane (buffer-local-value 'ecc-review-talk--pane (demo-control-buffer))))
    (with-current-buffer pane
      (save-excursion
        (goto-char (point-min))
        (when skip-prompt (forward-line 1))
        (if (search-forward string nil t)
            (get-text-property (match-beginning 0) 'face)
          'absent)))))

(defun demo-report-pane (label)
  "Say, under LABEL, what the reply pane says and the faces on it."
  (let ((pane (buffer-local-value 'ecc-review-talk--pane (demo-control-buffer))))
    (demo-say (format "[%s] pane %s: %s" label
                      (if (get-buffer-window pane t) "shown" "hidden")
                      (string-join (split-string (with-current-buffer pane
                                                   (buffer-substring-no-properties
                                                    (point-min) (point-max)))
                                                 "\n" t)
                                   " / ")))
    (demo-say (format "[%s] faces: prompt %S; tool %S; heading %S; text %S; code %S; fence %S; bold %S"
                      label
                      (demo-faces-at "› ")
                      (demo-faces-at "review_navigate" t)
                      (demo-faces-at "The cache key" t)
                      (demo-faces-at "is now keyed" t)
                      (demo-faces-at "(path, mtime)" t)
                      (demo-faces-at "key = (path" t)
                      (demo-faces-at "Old entries" t))))
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

(defun demo-close ()
  "Close the review, and the cat."
  (when-let* ((control (demo-control-buffer)))
    (ecc-review-ediff-quit control))
  (when (process-live-p (ecc-session-process demo-session))
    (delete-process (ecc-session-process demo-session)))
  nil)

;;;; What Claude says, fed as the CLI would

(defun demo-feed (object)
  "Hand OBJECT, an alist, to `ecc-dispatch' the way the process filter would."
  (ecc-dispatch demo-session (ecc-protocol-parse-line (json-serialize object)))
  nil)

(defun demo-id (prefix)
  "Return a fresh id under PREFIX."
  (format "%s_%03d" prefix (cl-incf demo-counter)))

(defun demo-event (event)
  "Feed the stream_event EVENT."
  (demo-feed `((type . "stream_event") (event . ,event) (parent_tool_use_id . :null)
               (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid")))))

(defun demo-delta (chunk)
  "Feed CHUNK as the next piece of the text being streamed."
  (demo-event `((type . "content_block_delta") (index . 0)
                (delta . ((type . "text_delta") (text . ,chunk))))))

(defconst demo-reply
  "## The cache key\n\nThe cache is now keyed by `(path, mtime)`, so a file changed on disk is read again instead of served stale.\n\n```python\nkey = (path, os.stat(path).st_mtime)\n```\n\n- **Old entries** are never evicted: every save adds one.\n- `show` strips the trailing newline before printing."
  "What Claude says, Markdown with a heading, inline code, a fence and a list.")

(defun demo-stream ()
  "Stream `demo-reply' a few words at a time, a beat apart; leave it open."
  (let ((words (split-string demo-reply " "))
        (chunks nil))
    (while words
      (push (concat (string-join (seq-take words 3) " ") (if (nthcdr 3 words) " " "")) chunks)
      (setq words (nthcdr 3 words)))
    (demo-event '((type . "message_start")))
    (demo-event '((type . "content_block_start") (index . 0)
                  (content_block . ((type . "text") (text . "")))))
    (let ((delay 0.0))
      (dolist (chunk (nreverse chunks))
        (run-at-time delay nil #'demo-delta chunk)
        (setq delay (+ delay 0.3)))))
  nil)

(defun demo-stream-end ()
  "Close the streamed text and end the turn."
  (demo-event '((type . "content_block_stop") (index . 0)))
  (demo-feed `((type . "result") (subtype . "success") (is_error . :false)
               (duration_ms . 4000) (num_turns . 1) (result . "")
               (total_cost_usd . 0.0)
               (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))
  nil)

(defun demo-ask ()
  "A turn of the session, as T would begin it, and Claude moving the review.
review_navigate is called through `ecc-mcp-call-tool' as the CLI would."
  (ecc-model-begin-turn demo-session "Walk me through the cache change.")
  (let* ((use (demo-id "toolu"))
         (input '((file . "src/cache.py") (line . 5))))
    (demo-feed `((type . "assistant")
                 (message . ((id . ,(demo-id "msg")) (type . "message") (role . "assistant")
                             (content . ,(vector `((type . "tool_use") (id . ,use)
                                                   (name . "mcp__emacs__review_navigate")
                                                   (input . ,input))))))
                 (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))
    (let ((result (let ((ecc-mcp--session-id (ecc-session-id demo-session)))
                    (cdr (ecc-mcp-call-tool "review_navigate" input)))))
      (demo-feed `((type . "user")
                   (message . ((role . "user")
                               (content . ,(vector `((tool_use_id . ,use)
                                                     (type . "tool_result")
                                                     (content . ,result))))))
                   (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))))
  nil)

(provide 'review-ediff-feedback)
;;; review-ediff-feedback.el ends here
