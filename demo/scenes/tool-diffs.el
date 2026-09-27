;;; tool-diffs.el --- What a call that changes a file shows  -*- lexical-binding: t; -*-

;;; Commentary:

;; The five things feat/tool-diffs changed about a call that writes to a
;; file, in a real frame, on a real project:
;;
;; 1. an Edit, a MultiEdit, a Write and a NotebookEdit come up open,
;;    showing the diff, rather than folded behind their heading;
;; 2. a MultiEdit has a diff at all -- in the transcript and in the
;;    permission prompt, which used to ask to change a file without
;;    saying what it would change;
;; 3. the heading says +N -M, in the numbers and the faces the rows of
;;    the Files summary use;
;; 4. a NotebookEdit shows the source of the cell it writes;
;; 5. a finished call draws the structuredPatch the CLI reported rather
;;    than the diff guessed from the file as it stood before the call.
;;
;; No CLI is started: the session is an archived one and every message
;; is handed to `ecc-dispatch', which is the door a live message comes
;; in by, so the scene is the same every time and costs nothing.  What
;; is on camera is the renderer, which is what changed.
;;
;; Played by demo/scenes/tool-diffs.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-dispatch)
(require 'ecc-protocol)
(require 'ecc-render)

(defvar demo-session nil
  "The session the diffs are drawn in.")

(defvar demo-counter 0
  "Serial number of the messages this scene feeds in.")

(defvar demo-file nil
  "The file the calls change.")

(defvar demo-notebook nil
  "The notebook the NotebookEdit writes a cell of.")

(defvar demo-unread nil
  "A file nothing has read and nothing can read.")

(defconst demo-source
  "def greet(name):\n    \"\"\"Say hi.\"\"\"\n    return \"hi \" + name\n\n\ndef farewell(name):\n    \"\"\"Say bye.\"\"\"\n    return \"bye \" + name\n"
  "What greet.py holds before anything changes it.")

;;;; What the scene is played on

(defun demo-scene-build ()
  "Build the project and the session.  Called by demo.el."
  (setq ecc-use-spaces t
        demo-counter 0)
  ;; A project of this scene's own: `demo-fresh-repository' deletes
  ;; `demo-root', and two scenes sharing one took each other's files.
  (setq demo-root "/tmp/ecc-demo-tool-diffs/")
  (demo-fresh-repository)
  (demo-write "greet.py" demo-source)
  (demo-write "notes.ipynb" "{\"cells\": [], \"nbformat\": 4}\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (setq demo-file (expand-file-name "greet.py" demo-root)
        demo-notebook (expand-file-name "notes.ipynb" demo-root))
  (find-file demo-file)
  (demo-say (format "ecc from %s   --   ecc-render-inhibit-inline-diff = %S, max %d lines"
                    (abbreviate-file-name (locate-library "ecc-render"))
                    ecc-render-inhibit-inline-diff ecc-render-diff-max-lines))
  nil)

(defun demo-open-session ()
  "Make the session the calls are drawn in and show it."
  (setq demo-session (ecc-model-create-session
                      :id "demo-tool-diffs"
                      :name "diffs"
                      :project-root demo-root
                      :kind 'archived))
  (ecc-model-set-state demo-session 'idle)
  (ecc-session-ensure-buffer demo-session)
  (ecc-display-session demo-session)
  (demo-frame)
  (ecc-model-begin-turn demo-session "greet.py を直して")
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
  "Feed a whole call to NAME with INPUT answered by RESULT.
STRUCTURED, when given, is the tool_use_result the CLI reports beside
the text.  Returns the id of the call."
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

(defun demo-read ()
  "Read greet.py, which is how the session comes to know what is in it."
  (demo-call "Read" `((file_path . ,demo-file))
             (concat "     1\tdef greet(name):\n     2\t    \"\"\"Say hi.\"\"\"\n"
                     "     3\t    return \"hi \" + name\n")
             `((type . "text")
               (file . ((filePath . ,demo-file) (content . ,demo-source)))))
  nil)

(defun demo-edit ()
  "One Edit: the call that already had a diff, now open and counted."
  (demo-call "Edit"
             `((file_path . ,demo-file)
               (old_string . "    return \"hi \" + name")
               (new_string . "    return \"hello \" + name"))
             (format "The file %s has been updated." demo-file))
  nil)

(defun demo-multi-edit ()
  "A MultiEdit: two edits at once, which drew nothing at all before."
  (demo-call "MultiEdit"
             `((file_path . ,demo-file)
               (edits . ,(vector
                          `((old_string . "\"\"\"Say bye.\"\"\"")
                            (new_string . "\"\"\"Say goodbye.\"\"\""))
                          `((old_string . "    return \"bye \" + name")
                            (new_string . "    return \"goodbye \" + name")))))
             (format "Applied 2 edits to %s" demo-file))
  nil)

(defun demo-write-call ()
  "A Write over the file that is there: every line of the difference."
  (demo-call "Write"
             `((file_path . ,demo-file)
               (content . ,(concat demo-source
                                   "\n\ndef shout(name):\n"
                                   "    return greet(name).upper()\n")))
             (format "The file %s has been updated." demo-file))
  nil)

(defun demo-notebook-edit ()
  "A NotebookEdit, which had no diff of any kind before this branch."
  (demo-call "NotebookEdit"
             `((file_path . ,demo-notebook)
               (cell_id . "cell-3")
               (cell_type . "code")
               (edit_mode . "replace")
               (new_source . ,(concat "from greet import greet\n"
                                      "print(greet(\"world\"))\n")))
             "Updated cell cell-3")
  nil)

(defun demo-patch-wins ()
  "An Edit on a file nobody read and nobody can read, with the CLI\='s patch.
The file is not on disk and no Read has been seen, so the guess has
nothing but the two strings the call named: no context and no line
numbers at all.  The structuredPatch is the whole hunk, and that is
what is drawn now."
  (setq demo-unread (expand-file-name "never-written.py" demo-root))
  (demo-say (format "the guess, with the file unknown: %S"
                    (substring-no-properties
                     (or (ecc-diff-for-tool "Edit" (demo-unread-input) nil) ""))))
  (demo-call "Edit" (demo-unread-input)
             (format "The file %s has been updated." demo-unread)
             `((filePath . ,demo-unread)
               (structuredPatch
                . ,(vector `((oldStart . 3) (oldLines . 5)
                             (newStart . 3) (newLines . 5)
                             (lines . ,(vector " " " def main():"
                                               "-    print(\"one\")"
                                               "+    print(\"two\")"
                                               " ")))))))
  nil)

(defun demo-unread-input ()
  "Return the input of the Edit on the file nobody read."
  `((file_path . ,demo-unread)
    (old_string . "    print(\"one\")")
    (new_string . "    print(\"two\")")))

(defun demo-finish-turn ()
  "Close the turn the way a result message does."
  (demo-feed `((type . "result")
               (subtype . "success")
               (is_error . :false)
               (session_id . ,(ecc-session-id demo-session))
               (uuid . ,(demo-id "uuid"))))
  nil)

;;;; The permission prompt

(defun demo-permission-multi-edit ()
  "Ask permission for a MultiEdit, which is where the empty diff hurt.
A prompt that will not say what it is about to change is a prompt
nobody can answer."
  (demo-feed
   `((type . "control_request")
     (request_id . ,(demo-id "req"))
     (request . ((subtype . "can_use_tool")
                 (tool_name . "MultiEdit")
                 (display_name . "MultiEdit")
                 (description . "greet.py")
                 (input . ((file_path . ,demo-file)
                           (edits . ,(vector
                                      `((old_string . "def greet(name):")
                                        (new_string . "def greet(name: str) -> str:"))
                                      `((old_string . "def farewell(name):")
                                        (new_string . "def farewell(name: str) -> str:"))))))))
     (session_id . ,(ecc-session-id demo-session))
     (uuid . ,(demo-id "uuid"))))
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

(defun demo-report-folds ()
  "Say which tool nodes are folded and what their headings count."
  (with-current-buffer (demo-transcript)
    (let (rows)
      (maphash
       (lambda (id node)
         (when (eq (ecc-node-type node) 'tool)
           (push (cons (ecc-node-id node)
                       (format "%s %s"
                               (or (ecc-model-node-get node 'name) "?")
                               (if (ecc-render--wanted-hidden-p id) "folded" "OPEN")))
                 rows)))
       (ecc-session-nodes demo-session))
      (demo-say (format "tool nodes: %s"
                        (or (string-join
                             (mapcar #'cdr (sort rows (lambda (a b)
                                                        (string< (car a) (car b)))))
                             " | ")
                            "none")))))
  nil)

(defun demo-report-headings ()
  "Say every line of the transcript that counts a change.
The words are the CLI\='s own, on the line under the heading: \"Added 1
line, removed 1 line\"."
  (ecc-render-flush demo-session)
  (with-current-buffer (demo-transcript)
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (re-search-forward "^.*\\(Added\\|Removed\\) [0-9]+ line.*$" nil t)
          (push (string-trim (match-string-no-properties 0)) rows))
        (demo-say (format "%d line(s) counting a change: %s"
                          (length rows)
                          (string-join (nreverse rows) "  //  "))))))
  nil)

(defun demo-report-diffs ()
  "Say how many diff lines of each kind are drawn, by their faces.
The faces are what a batch test cannot see and the reason for the
camera: a diff drawn in the colour of ordinary text is not a diff."
  (ecc-render-flush demo-session)
  (with-current-buffer (demo-transcript)
    (let ((added 0) (removed 0) (headers 0) (position (point-min)))
      (while (< position (point-max))
        (let ((faces (ensure-list (get-text-property position 'face))))
          (cond ((memq 'diff-added faces) (cl-incf added))
                ((memq 'diff-removed faces) (cl-incf removed))
                ((memq 'diff-hunk-header faces) (cl-incf headers))))
        (setq position (next-single-property-change position 'face nil (point-max))))
      (demo-say (format "runs of diff faces in the buffer: %d added, %d removed, %d hunk headers"
                        added removed headers))))
  nil)

(defun demo-report-multi-edit ()
  "Say what the MultiEdit call draws, which used to be nothing."
  (let ((node (seq-find (lambda (node)
                          (equal (ecc-model-node-get node 'name) "MultiEdit"))
                        (hash-table-values (ecc-session-nodes demo-session)))))
    (if (null node)
        (demo-say "no MultiEdit in the transcript")
      (let ((diff (ecc-render--tool-diff node)))
        (demo-say (format "MultiEdit diff: %s"
                          (if diff
                              (format "%d lines, %S"
                                      (length (split-string (string-trim diff) "\n"))
                                      (ecc-diff-text-counts diff))
                            "nil -- nothing to show"))))))
  nil)

;;;; The keys of the transcript

(defun demo-transcript-key (key &optional text prefix)
  "Run what KEY is bound to in the transcript."
  (demo-run-key-in (demo-transcript) key text prefix))

(defun demo-point-on-tool (name)
  "Put point on the heading of the tool call to NAME."
  (let ((buffer (demo-transcript)))
    (with-current-buffer buffer
      (let ((position (point-min)) found)
        (while (and (not found)
                    (setq position (next-single-property-change position 'ecc-node)))
          (when-let* ((id (get-text-property position 'ecc-node))
                      (node (ecc-model-node demo-session id)))
            (when (and (eq (ecc-node-type node) 'tool)
                       (equal (ecc-model-node-get node 'name) name)
                       (get-text-property position 'ecc-heading))
              (setq found position))))
        (unless found (error "No call to %s in the transcript" name))
        (goto-char found)
        (when-let* ((window (get-buffer-window buffer t)))
          (set-window-point window found)
          (with-selected-window window (recenter -8)))
        (demo-say (format "point is on: %s"
                          (string-trim
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position))))))))
  nil)

(defun demo-fold-at-point ()
  "Fold, or unfold, what point is on, the way TAB does."
  (demo-transcript-key "TAB")
  nil)

(defun demo-diff-inline-off ()
  "Ask for the diffs to be folded and draw the transcript again.
The remembered folds go with it: what the reader did by hand wins over
the default, so a run of this scene that has already pressed TAB would
otherwise show the memory rather than the setting."
  (setq ecc-render-inhibit-inline-diff t)
  (with-current-buffer (demo-transcript)
    (clrhash ecc-render--visibility-cache))
  (ecc-render-refresh demo-session)
  (demo-say (format "ecc-render-inhibit-inline-diff = %S"
                    ecc-render-inhibit-inline-diff))
  (demo-show-transcript)
  nil)

(defun demo-diff-inline-on ()
  "Turn it back on."
  (setq ecc-render-inhibit-inline-diff nil)
  (with-current-buffer (demo-transcript)
    (clrhash ecc-render--visibility-cache))
  (ecc-render-refresh demo-session)
  (demo-say (format "ecc-render-inhibit-inline-diff = %S"
                    ecc-render-inhibit-inline-diff))
  (demo-show-transcript)
  nil)

(defun demo-show-files ()
  "Unfold the Files summary, whose rows count the changes the same way."
  (ecc-render-flush demo-session)
  ;; The folds and their memory are buffer-local to the transcript.
  (with-current-buffer (demo-transcript)
    (ecc-render-show-node "files")
    (dolist (entry (ecc-model-files demo-session))
      (ecc-render-show-node (concat "file:" (ecc-file-entry-path entry)))))
  (demo-show-transcript)
  nil)

(defun demo-cleanup ()
  "Nothing is running; this is here so the scene ends like the others."
  nil)

(provide 'tool-diffs)
;;; tool-diffs.el ends here
