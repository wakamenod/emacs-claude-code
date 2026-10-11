;;; review-talk.el --- T, t and M in a review, and the reply pane  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 7 of the review comments.  What a batch test cannot see is the
;; reply pane at the bottom of an ediff review that has the frame to
;; itself in the user's own frame: what Claude says streaming into it,
;; each tool call on a line, a permission request shown whole and
;; answered with y from the control panel, and the keyboard never
;; leaving the control panel.
;;
;; No model is asked anything.  The session is an archived one whose
;; process is a `cat': T, t and M really send their prompt -- it goes to
;; the cat and nowhere else -- and what Claude would answer is handed to
;; `ecc-dispatch' the way the process filter hands it a line, streamed
;; text, tool calls, a permission request and the result.  The review
;; tools are called through `ecc-mcp-call-tool' with the session id
;; bound, as the CLI would call them, so the navigation and the comments
;; happen in the review on camera.
;;
;; Every step reports what it found -- the windows, what the pane says,
;; the difference ediff is on, the comments, what was sent -- and the
;; scene ends by saving the reports to /tmp/ecc-demo-review-talk-log.txt,
;; which is what the run is judged from.
;;
;; Played by demo/scenes/review-talk.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-dispatch)
(require 'ecc-protocol)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-talk)
(require 'ecc-review-agent)

(defvar demo-session nil "The session the review belongs to.")

(defvar demo-counter 0 "Serial number of the messages this scene feeds in.")

(defvar demo-sent nil "The prompts the session sent to its cat, oldest first.")

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
  "Build the project: two files committed, then both changed.  Called by demo.el."
  (setq ecc-review-style 'ediff
        ecc-review-files-shown nil
        ecc-review-talk-reply-height 9
        demo-counter 0
        demo-sent nil
        ;; The control panel a window of the frame, so that it is in the
        ;; picture (demo/README.md).
        ediff-window-setup-function #'ediff-setup-windows-plain)
  (demo-fresh-repository)
  (demo-write "src/cache.py" demo-cache-old)
  (demo-write "src/app.py" demo-app-old)
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-write "src/cache.py" demo-cache-new)
  (demo-write "src/app.py" demo-app-new)
  (find-file (expand-file-name "src/app.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   theme %S   ecc-use-spaces %S   reply pane %S lines"
                    (ecc-version) custom-enabled-themes ecc-use-spaces
                    ecc-review-talk-reply-height))
  nil)

(defun demo-catch-sent (process output)
  "Keep the prompts the cat PROCESS gives back in OUTPUT, for the reports."
  (ignore process)
  (dolist (line (split-string output "\n" t))
    (let ((message (ecc-protocol-parse-line line)))
      (when (equal (alist-get 'type message) "user")
        (let ((content (alist-get 'content (alist-get 'message message))))
          (when (stringp content)
            (setq demo-sent (append demo-sent (list content)))))))))

(defun demo-open-session ()
  "Make the session, with MCP, a cat for a process, and show it."
  (setq demo-session (ecc-model-create-session
                      :id "demo-review-talk"
                      :name "talk"
                      :project-root demo-root
                      :kind 'archived
                      :options '(:mcp t)))
  (setf (ecc-session-process demo-session)
        (make-process :name "demo-review-talk-cat" :command '("cat")
                      :connection-type 'pipe :noquery t
                      :filter #'demo-catch-sent))
  (ecc-model-set-state demo-session 'idle)
  (ecc-session-ensure-buffer demo-session)
  (ecc-display-session demo-session)
  (demo-frame)
  nil)

;;;; Feeding the stream the CLI would have sent

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

(defun demo-stream (text &optional pieces)
  "Stream TEXT as Claude saying it, in PIECES words at a time, a beat apart."
  (let* ((words (split-string text " "))
         (pieces (or pieces 3))
         (chunks nil))
    (while words
      (push (concat (string-join (seq-take words pieces) " ")
                    (if (nthcdr pieces words) " " ""))
            chunks)
      (setq words (nthcdr pieces words)))
    (setq chunks (nreverse chunks))
    (demo-event '((type . "message_start")))
    (demo-event '((type . "content_block_start") (index . 0)
                  (content_block . ((type . "text") (text . "")))))
    (let ((delay 0.0))
      (dolist (chunk chunks)
        (run-at-time delay nil #'demo-delta chunk)
        (setq delay (+ delay 0.25)))
      (run-at-time (+ delay 0.1) nil
                   #'demo-event '((type . "content_block_stop") (index . 0)))))
  nil)

(defun demo-delta (chunk)
  "Feed CHUNK as the next piece of the text being streamed."
  (demo-event `((type . "content_block_delta") (index . 0)
                (delta . ((type . "text_delta") (text . ,chunk))))))

(defun demo-call (name input)
  "Have Claude call the tool NAME with INPUT: the call, its effect, its result.
A review tool is called through `ecc-mcp-call-tool' as the CLI would."
  (let* ((use (demo-id "toolu"))
         (short (string-remove-prefix (format "mcp__%s__" ecc-mcp-server-name) name)))
    (demo-feed `((type . "assistant")
                 (message . ((id . ,(demo-id "msg")) (type . "message") (role . "assistant")
                             (content . ,(vector `((type . "tool_use") (id . ,use)
                                                   (name . ,name) (input . ,input))))))
                 (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))
    (let ((result (if (equal short name)
                      "ok"
                    (let ((ecc-mcp--session-id (ecc-session-id demo-session)))
                      (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool short input)))
                        (demo-say (format "Claude called %s%s: %s" short
                                          (if failed " (FAILED)" "")
                                          (car (split-string text "\n"))))
                        text)))))
      (demo-feed `((type . "user")
                   (message . ((role . "user")
                               (content . ,(vector `((tool_use_id . ,use)
                                                     (type . "tool_result")
                                                     (content . ,result))))))
                   (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))))
  nil)

(defvar demo-asked-use nil "The id of the call permission was asked for.")

(defun demo-ask (name input)
  "Have Claude call NAME with INPUT and ask permission for it, as the CLI does.
The call comes first, then the request that names it."
  (setq demo-asked-use (demo-id "toolu"))
  (demo-feed `((type . "assistant")
               (message . ((id . ,(demo-id "msg")) (type . "message") (role . "assistant")
                           (content . ,(vector `((type . "tool_use") (id . ,demo-asked-use)
                                                 (name . ,name) (input . ,input))))))
               (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))
  (demo-feed `((type . "control_request")
               (request_id . ,(demo-id "req"))
               (request . ((subtype . "can_use_tool") (tool_name . ,name)
                           (input . ,input) (tool_use_id . ,demo-asked-use)))))
  nil)

(defun demo-asked-result (text)
  "The call permission was asked for ran, and said TEXT."
  (demo-feed `((type . "user")
               (message . ((role . "user")
                           (content . ,(vector `((tool_use_id . ,demo-asked-use)
                                                 (type . "tool_result")
                                                 (content . ,text))))))
               (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))
  nil)

(defun demo-result ()
  "End the turn."
  (demo-feed `((type . "result") (subtype . "success") (is_error . :false)
               (duration_ms . 4000) (num_turns . 1) (result . "")
               (total_cost_usd . 0.0)
               (session_id . ,(ecc-session-id demo-session)) (uuid . ,(demo-id "uuid"))))
  nil)

;;;; Looking

(defun demo-control-buffer ()
  "Return the control buffer of the ediff review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode) ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-report-windows (label)
  "Say, under LABEL, the windows of the frame from the top left, and which is selected."
  (demo-say
   (format "[%s] windows: %s" label
           (mapconcat (lambda (window)
                        (format "%s%s(%dx%d%s)"
                                (buffer-name (window-buffer window))
                                (if (window-parameter window 'window-side)
                                    (format " side:%s " (window-parameter window 'window-side))
                                  " ")
                                (window-total-width window) (window-total-height window)
                                (if (eq window (frame-selected-window (window-frame window)))
                                    ", selected" "")))
                      (window-list (demo-main-frame) 'no-minibuffer)
                      " | ")))
  nil)

(defun demo-report-pane (label)
  "Say, under LABEL, what the reply pane says and its mode line."
  (when-let* ((control (demo-control-buffer)))
    (let ((pane (buffer-local-value 'ecc-review-talk--pane control)))
      (demo-say (format "[%s] pane %s: %s  ‖ mode line:%s" label
                        (if (and (buffer-live-p pane) (get-buffer-window pane t)) "shown" "hidden")
                        (if (buffer-live-p pane)
                            (string-join (split-string (with-current-buffer pane
                                                         (buffer-substring-no-properties
                                                          (point-min) (point-max)))
                                                       "\n" t)
                                         " / ")
                          "(no pane)")
                        (if (buffer-live-p pane)
                            (with-current-buffer pane (ecc-review-talk--mode-line))
                          "")))))
  nil)

(defun demo-report-review (label)
  "Say, under LABEL, the difference ediff is on and the comments of the review."
  (when-let* ((control (demo-control-buffer)))
    (with-current-buffer control
      (demo-say (format "[%s] on difference %d of %d; comments: %s" label
                        (1+ ediff-current-difference) ediff-number-of-differences
                        (mapconcat (lambda (note)
                                     (format "#%d %s %s: %s" (ecc-review-note-id note)
                                             (ecc-review-note-author note)
                                             (ecc-review-note-where note)
                                             (ecc-review-note-text note)))
                                   ecc-review--notes " / ")))))
  nil)

(defun demo-report-sent (label)
  "Say, under LABEL, the prompts sent, what is queued and what is waiting."
  (demo-say (format "[%s] sent: %S; queued: %S; pending: %S; state %s" label
                    demo-sent (ecc-session-input-queue demo-session)
                    (mapcar #'ecc-request-tool-name (ecc-session-pending demo-session))
                    (ecc-session-state demo-session)))
  nil)

(defun demo-report-help ()
  "Say the lines of the ediff control panel."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "control panel: %s"
                      (string-join (split-string (buffer-substring-no-properties
                                                  (point-min) (point-max))
                                                 "\n" t)
                                   " // "))))
  nil)

;;;; Doing

(defun demo-open-ediff ()
  "Open the review of everything uncommitted, in ediff, as G opens it."
  (ecc-review-range demo-session "HEAD" demo-root)
  nil)

(defun demo-key (key &optional text)
  "Run what KEY does in the control panel, TEXT answering the minibuffer."
  (demo-run-key-in (demo-control-buffer) key text)
  nil)

(defun demo-answer (choice)
  "Press y in the control panel and then CHOICE, a character, for the question."
  (demo-key "y")
  (run-at-time 1.5 nil (lambda () (setq unread-command-events
                                        (append unread-command-events (list choice)))))
  nil)

;;;;; What Claude says

(defun demo-tour-1 ()
  "The first stop of the tour: navigate, explain, comment."
  (demo-call "mcp__emacs__review_hunks" nil)
  (demo-call "mcp__emacs__review_navigate" '((file . "src/cache.py") (line . 5)))
  (demo-stream "The most important change is in src/cache.py: the cache is now keyed by the path and the file's mtime, so a file changed on disk is read again instead of served stale.")
  nil)

(defun demo-tour-1-comment ()
  "Comment on what needs attention, then end the turn."
  (demo-call "mcp__emacs__review_comment"
             '((file . "src/cache.py") (line . 5)
               (text . "Old keys are never evicted: every save of a file adds an entry.")))
  (demo-result)
  nil)

(defun demo-tour-2 ()
  "The next stop, in src/app.py."
  (demo-call "mcp__emacs__review_navigate" '((file . "src/app.py") (line . 8)))
  (demo-stream "Next, src/app.py: show now strips the trailing newline before printing. That is the whole tour; ask me about anything you want to look at again.")
  nil)

(defun demo-answer-message ()
  "Claude's answer to M: it wants to run the tests, and asks."
  (demo-stream "Keeping the old entries is a leak. I can drop the entries of a path when its mtime changes; first let me run the tests to see what covers the cache.")
  nil)

(defun demo-ask-tests ()
  "Ask permission to run the tests."
  (demo-ask "Bash" '((command . "python -m pytest tests/test_cache.py -q")
                     (description . "Run the cache tests")))
  nil)

(defun demo-after-allow ()
  "The tests ran; the turn ends."
  (demo-asked-result "3 passed in 0.02s")
  (demo-stream "The tests pass. Say the word and I will evict the stale entries.")
  nil)

(defun demo-quit ()
  "Close the review, and the cat."
  (when-let* ((control (demo-control-buffer)))
    (let ((pane (buffer-local-value 'ecc-review-talk--pane control)))
      (ecc-review-ediff-quit control)
      (demo-say (format "ediff quit; the reply pane %s"
                        (if (buffer-live-p pane) "is still there" "is gone")))))
  (when (process-live-p (ecc-session-process demo-session))
    (delete-process (ecc-session-process demo-session)))
  nil)

(provide 'review-talk)
;;; review-talk.el ends here
