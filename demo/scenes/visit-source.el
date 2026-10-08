;;; visit-source.el --- RET and a click on code open the file at the line  -*- lexical-binding: t; -*-

;;; Commentary:

;; What feat/visit-source does, in a real frame: RET or a click on code
;; in the transcript opens the file beside the session, at the line.
;;
;; 1. a line of the diff of an Edit, after a later Edit moved it down;
;; 2. the heading of that Edit, and of a Read with an offset;
;; 3. a line of the Files section;
;; 4. a path in the reply, and one that is not there;
;; 5. a click on a diff line, through `follow-link';
;; 6. `o' and RET on a Bash heading, which still lay the node open.
;;
;; No CLI is started: the session is an archived one fed through
;; `ecc-dispatch', and the file on disk is what the two Edits left, so
;; the line that flashes can be read against what was asked for.  Every
;; step says where the file opened; `demo-save-log' keeps it as text.
;;
;; Played by demo/scenes/visit-source.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-dispatch)
(require 'ecc-protocol)
(require 'ecc-render)
(require 'ecc-visit)

(defvar demo-session nil
  "The session the calls are drawn in.")

(defvar demo-counter 0
  "Serial number of the messages this scene feeds in.")

(defvar demo-file nil
  "The file the calls change.")

(defconst demo-before
  '("\"\"\"Greetings, for the demo of visit-source.\"\"\"" "" ""
    "def one():" "    return 1" "" ""
    "def two():" "    return 2" "" ""
    "def three():" "    return 3" "" ""
    "def four():" "    return 4" ""
    "def greet(name):" "    return \"hi \" + name" "" ""
    "def farewell(name):" "    return \"bye \" + name" "" ""
    "def five():" "    return 5" "" ""
    "def six():" "    return 6")
  "The lines of greet.py before anything changes it.
Line 20 is the one the first Edit changes.")

(defun demo-lines (lines)
  "Return LINES as the text of a file."
  (concat (string-join lines "\n") "\n"))

(defun demo-after-first ()
  "The lines after the first Edit: line 20 says hello."
  (let ((lines (copy-sequence demo-before)))
    (setf (nth 19 lines) "    return \"hello \" + name")
    lines))

(defun demo-after-second ()
  "The lines after the second Edit: two imports above everything."
  (let ((lines (demo-after-first)))
    (append (list (car lines) "" "import os" "import sys")
            (cdr lines))))

;;;; What the scene is played on

(defun demo-scene-build ()
  "Build the project.  Called by demo.el."
  (setq ecc-use-spaces t
        demo-counter 0)
  (setq demo-root "/tmp/ecc-demo-visit-source/")
  (demo-fresh-repository)
  ;; What is on disk is what both Edits left: the line the first one
  ;; changed is at 23 now, not at the 20 its diff says.
  (demo-write "greet.py" (demo-lines (demo-after-second)))
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (setq demo-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc from %s" (abbreviate-file-name (locate-library "ecc-visit"))))
  nil)

(defun demo-open-session ()
  "Make the session and show it."
  (setq demo-session (ecc-model-create-session
                      :id "demo-visit-source"
                      :name "visit"
                      :project-root demo-root
                      :kind 'archived))
  (ecc-model-set-state demo-session 'idle)
  (ecc-session-ensure-buffer demo-session)
  (ecc-display-session demo-session)
  (demo-frame)
  (ecc-model-begin-turn demo-session "greet を hello にして、import も足して")
  nil)

;;;; Feeding the stream the CLI would have sent

(defun demo-feed (object)
  "Hand OBJECT, an alist, to `ecc-dispatch' the way the process filter would."
  (ecc-dispatch demo-session
                (ecc-protocol-parse-line (json-serialize object)))
  nil)

(defun demo-id (prefix)
  "Return a fresh id under PREFIX."
  (format "%s_%03d" prefix (cl-incf demo-counter)))

(defun demo-assistant (content)
  "Return an assistant message carrying CONTENT, a vector of blocks."
  `((type . "assistant")
    (message . ((model . "claude-opus-5")
                (id . ,(demo-id "msg"))
                (type . "message")
                (role . "assistant")
                (content . ,content)))
    (session_id . ,(ecc-session-id demo-session))
    (uuid . ,(demo-id "uuid"))))

(defun demo-call (name input result &optional structured)
  "Feed a whole call to NAME with INPUT answered by RESULT and STRUCTURED."
  (let ((use (demo-id "toolu")))
    (demo-feed (demo-assistant
                (vector `((type . "tool_use") (id . ,use)
                          (name . ,name) (input . ,input)))))
    (demo-feed
     `((type . "user")
       (message . ((role . "user")
                   (content . ,(vector `((tool_use_id . ,use)
                                         (type . "tool_result")
                                         (content . ,result))))))
       ,@(when structured (list (cons 'tool_use_result structured)))
       (session_id . ,(ecc-session-id demo-session))
       (uuid . ,(demo-id "uuid"))))
    use))

(defun demo-calls ()
  "Feed the Read, the two Edits, a Bash call and the reply."
  (demo-call "Read" `((file_path . ,demo-file) (offset . 15) (limit . 10))
             "    15\t\n    16\tdef four():\n"
             `((type . "text")
               (file . ((filePath . ,demo-file)
                        (content . ,(demo-lines demo-before))))))
  (demo-call "Edit"
             `((file_path . ,demo-file)
               (old_string . "    return \"hi \" + name")
               (new_string . "    return \"hello \" + name"))
             (format "The file %s has been updated." demo-file)
             `((filePath . ,demo-file)
               (originalFile . ,(demo-lines demo-before))
               (structuredPatch
                . ,(vector `((oldStart . 17) (oldLines . 7)
                             (newStart . 17) (newLines . 7)
                             (lines . ,(vector "     return 4" " "
                                               " def greet(name):"
                                               "-    return \"hi \" + name"
                                               "+    return \"hello \" + name"
                                               " " " "
                                               " def farewell(name):")))))))
  (demo-call "Edit"
             `((file_path . ,demo-file)
               (old_string . "\"\"\"Greetings, for the demo of visit-source.\"\"\"\n")
               (new_string . "\"\"\"Greetings, for the demo of visit-source.\"\"\"\n\nimport os\nimport sys\n"))
             (format "The file %s has been updated." demo-file)
             `((filePath . ,demo-file)
               (originalFile . ,(demo-lines (demo-after-first)))
               (structuredPatch
                . ,(vector `((oldStart . 1) (oldLines . 3)
                             (newStart . 1) (newLines . 6)
                             (lines . ,(vector " \"\"\"Greetings, for the demo of visit-source.\"\"\""
                                               "+"
                                               "+import os"
                                               "+import sys"
                                               " "
                                               " ")))))))
  (demo-call "Bash" '((command . "python3 -c 'import greet'")) "")
  (demo-feed (demo-assistant
              (vector '((type . "text")
                        (text . "Done.  The greeting is at `greet.py:23` now, after the imports.  There is no `missing.py:3`.")))))
  (demo-feed `((type . "result")
               (subtype . "success")
               (is_error . :false)
               (session_id . ,(ecc-session-id demo-session))
               (uuid . ,(demo-id "uuid"))))
  (demo-show-transcript)
  nil)

;;;; What the buffer holds

(defun demo-transcript ()
  "Return the transcript buffer of the session."
  (ecc-session-buffer demo-session))

(defun demo-show-transcript ()
  "Put the transcript on the screen and go to the end of it."
  (ecc-render-flush demo-session)
  (ecc-display-session demo-session)
  (when-let* ((window (get-buffer-window (demo-transcript) t)))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1)))
  (demo-frame)
  nil)

(defun demo-pattern (text)
  "Return a regexp for TEXT, with room for an icon after a heading's mark."
  (if (string-prefix-p "✓ " text)
      (concat "✓ .\\{0,3\\}" (regexp-quote (substring text 2)))
    (regexp-quote text)))

(defun demo-point-on (anchor text &optional files)
  "Put point on the first line holding TEXT after ANCHOR in the transcript.
With FILES the Files summary is unfolded first and ANCHOR is looked
for in it."
  (ecc-render-flush demo-session)
  (let ((buffer (demo-transcript)))
    (with-current-buffer buffer
      (when files
        (ecc-render-show-node "files")
        (ecc-render-show-node (concat "file:" demo-file)))
      (goto-char (point-min))
      (when files
        (goto-char (car (ecc-render-node-bounds (concat "file:" demo-file)))))
      ;; The user's configuration may draw an icon between the mark of a
      ;; heading and the name of the tool: `✓ Edit' is `✓ <icon>Edit'.
      (unless (and (re-search-forward (demo-pattern anchor) nil t)
                   (re-search-forward (demo-pattern text) nil t))
        (error "Not in the transcript: %s / %s" anchor text))
      (goto-char (match-beginning 0))
      (when-let* ((window (get-buffer-window buffer t)))
        (set-window-point window (point))
        (with-selected-window window (recenter)))
      (demo-say (format "point is on: %s"
                        (string-trim (buffer-substring-no-properties
                                      (line-beginning-position)
                                      (line-end-position))))))
    nil))

(defun demo-key (key)
  "Run what KEY is bound to in the transcript, and say what that is."
  (demo-say-key-in (demo-transcript) key)
  (demo-run-key-in (demo-transcript) key)
  nil)

(defun demo-ret-safely ()
  "Run RET in the transcript, saying the error a missing file gives."
  (run-at-time
   0.2 nil
   (lambda ()
     (when-let* ((window (demo-window-of (demo-transcript))))
       (with-selected-window window
         (condition-case err
             (call-interactively (key-binding (kbd "RET")))
           (user-error (demo-say (format "RET said: %s"
                                         (error-message-string err)))))))))
  nil)

(defun demo-click ()
  "Click mouse-1 at point in the transcript, the way a real click arrives.
`mouse-on-link-p' is asked what the click is, which is the question
`follow-link' answers and batch cannot put; a link -- a URL, and
nothing else in the transcript -- turns the click into the mouse-2 that
`ecc-chat-follow-link' is bound to."
  (let ((window (demo-window-of (demo-transcript))))
    (with-selected-window window
      (let* ((posn (posn-at-point (window-point window) window))
             (link (mouse-on-link-p posn)))
        (demo-say (format "mouse-on-link-p here: %S; mouse-face here: %S"
                          link (get-char-property (point) 'mouse-face)))
        (when link
          (funcall (key-binding [mouse-2] nil nil posn)
                   (list 'mouse-2 posn))))))
  nil)

(defun demo-report-opened ()
  "Say where greet.py is open, at which line, and what that line says."
  (let* ((buffer (get-file-buffer demo-file))
         (window (and buffer (get-buffer-window buffer t))))
    (if (not (window-live-p window))
        (demo-say "greet.py is not in a window")
      (with-current-buffer buffer
        (let ((line (line-number-at-pos (window-point window))))
          (demo-say (format "greet.py open at line %d: %S  | windows: %s | transcript still shown: %s"
                            line
                            (save-excursion
                              (goto-char (window-point window))
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))
                            (length (window-list (window-frame window) 'no-mini))
                            (and (get-buffer-window (demo-transcript) t) t)))))))
  nil)

(defun demo-report-selected ()
  "Say which buffer the selected window of the frame shows."
  (demo-say (format "selected window shows: %s"
                    (buffer-name (window-buffer (frame-selected-window
                                                 (demo-main-frame))))))
  nil)

(defun demo-report-detail ()
  "Say whether the detail buffer is on the screen, and what it is of."
  (let ((buffer (seq-find (lambda (b) (string-prefix-p "*ecc-detail" (buffer-name b)))
                          (buffer-list))))
    (demo-say (format "detail buffer shown: %s -- %s"
                      (and buffer (get-buffer-window buffer t) t)
                      (if buffer
                          (with-current-buffer buffer
                            (save-excursion
                              (goto-char (point-min))
                              (forward-line 2)
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position))))
                        "none"))))
  nil)

(defun demo-close-detail ()
  "Take the detail buffer off the screen, so the next step has to show it."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-detail" (buffer-name buffer))
      (kill-buffer buffer)))
  nil)

(defun demo-park ()
  "Put greet.py back at its first line, so the next step has to move it."
  (when-let* ((buffer (get-file-buffer demo-file)))
    (with-current-buffer buffer (goto-char (point-min)))
    (dolist (window (get-buffer-window-list buffer nil t))
      (set-window-point window 1)))
  nil)

(defun demo-back ()
  "Go back to the transcript, leaving greet.py where it is."
  (when-let* ((window (demo-window-of (demo-transcript))))
    (select-window window))
  nil)

(defun demo-cleanup ()
  "Nothing is running; this is here so the scene ends like the others."
  nil)

(provide 'visit-source)
;;; visit-source.el ends here
