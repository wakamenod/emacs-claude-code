;;; images-inline.el --- Pictures and video in the transcript  -*- lexical-binding: t; -*-

;;; Commentary:

;; The four ways a picture reaches the transcript in 0.3.0, on a real
;; session in a real frame: an image block on an assistant message, an
;; image inside a tool_result, an image file a tool named by `file_path'
;; with no picture in its result, and the images a prompt attached as
;; `@path'.  Then the video, whose first frame ffmpeg pulls out; the GIF
;; that moves by itself and the `v' that stops it; `RET', which opens
;; one; and `ecc-image-inline', which turns the whole of it off.
;;
;; The session is real and the last picture is really sent to it.  The
;; first three arrive by feeding the stream the CLI would have sent
;; through `ecc-dispatch', which is the same door a live message comes
;; in by, so that the scene is the same every time and costs one turn
;; rather than four.
;;
;; The pictures are made here with ffmpeg rather than committed.
;;
;; Played by demo/scenes/images-inline.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-image)
(require 'ecc-dispatch)
(require 'ecc-protocol)

(defvar demo-session nil
  "The session the pictures are drawn in.")

(defvar demo-picture nil
  "A still, drawn by ffmpeg.")

(defvar demo-gif nil
  "A GIF that moves.")

(defvar demo-video nil
  "A video, which no buffer can draw.")

(defvar demo-counter 0
  "Serial number of the messages this scene feeds in.")

;;;; What the scene is played on

(defun demo-ffmpeg (&rest args)
  "Run ffmpeg with ARGS, saying nothing."
  (apply #'call-process "ffmpeg" nil nil nil "-y" "-loglevel" "error" args))

(defun demo-make-pictures ()
  "Draw the still, the GIF and the video into the demo project."
  (demo-ffmpeg "-f" "lavfi" "-i" "testsrc=size=480x270:rate=1" "-frames:v" "1"
               demo-picture)
  (demo-ffmpeg "-f" "lavfi" "-i" "testsrc2=size=240x135:rate=10" "-t" "2"
               "-vf" "scale=240:135" "-loop" "0" demo-gif)
  (demo-ffmpeg "-f" "lavfi" "-i" "testsrc=size=480x270:rate=10" "-t" "3"
               "-pix_fmt" "yuv420p" demo-video)
  nil)

(defun demo-scene-build ()
  "Build the project, draw the pictures and open it."
  (setq ecc-use-spaces t
        demo-counter 0)
  ;; A project of this scene's own.  `demo-root' is one path for
  ;; every scene, and `demo-fresh-repository' deletes it: a second
  ;; scene starting while this one runs took the worktrees of this
  ;; one out from under it (2026-09-17).
  (setq demo-root "/tmp/ecc-demo-images-inline/")
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (setq demo-picture (expand-file-name "picture.png" demo-root)
        demo-gif (expand-file-name "moving.gif" demo-root)
        demo-video (expand-file-name "clip.mp4" demo-root))
  (demo-make-pictures)
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc from %s   --   ecc-image-inline = %S, max height %d, ffmpeg %s"
                    (abbreviate-file-name (locate-library "ecc-image"))
                    ecc-image-inline ecc-image-max-height
                    (or (ecc-image-ffmpeg) "not found")))
  nil)

(defun demo-open-source ()
  "Show the project, and say which ecc and which settings this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc from %s   --   ecc-image-inline = %S, max height %d, ffmpeg %s"
                    (abbreviate-file-name (locate-library "ecc-image"))
                    ecc-image-inline ecc-image-max-height
                    (or (ecc-image-ffmpeg) "not found")))
  nil)

(defun demo-start-session ()
  "Start a real session in the project."
  (let ((default-directory demo-root))
    (setq demo-session (ecc-start demo-root "pictures")))
  nil)

;;;; Feeding the stream the CLI would have sent

(defun demo-base64 (path)
  "Return the bytes of PATH, base64 encoded."
  (base64-encode-string
   (with-temp-buffer
     (set-buffer-multibyte nil)
     (insert-file-contents-literally path)
     (buffer-string))
   t))

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
    (message . ((model . "claude-haiku-4-5-20251001")
                (id . ,(demo-id "msg"))
                (type . "message")
                (role . "assistant")
                (content . ,content)))
    (session_id . ,(ecc-session-id demo-session))
    (uuid . ,(demo-id "uuid"))))

(defun demo-open-turn (prompt)
  "Open a turn under PROMPT, so the pictures have somewhere to be drawn."
  (ecc-model-begin-turn demo-session prompt)
  nil)

(defun demo-message-image ()
  "An image block on an assistant message: the first of the four ways."
  (demo-feed
   (demo-assistant
    (vector `((type . "text")
              (text . "Here is the picture you asked for."))
            `((type . "image")
              (source . ((type . "base64")
                         (media_type . "image/png")
                         (data . ,(demo-base64 demo-picture))))))))
  nil)

(defun demo-tool-result-image ()
  "An image inside a tool_result: a Read of a .png, as the CLI sends it."
  (let ((use (demo-id "toolu")))
    (demo-feed
     (demo-assistant
      (vector `((type . "tool_use")
                (id . ,use)
                (name . "Read")
                (input . ((file_path . ,demo-picture)))))))
    (demo-feed
     `((type . "user")
       (message . ((role . "user")
                   (content . ,(vector
                                `((tool_use_id . ,use)
                                  (type . "tool_result")
                                  (content . ,(vector
                                               `((type . "image")
                                                 (source . ((type . "base64")
                                                            (media_type . "image/png")
                                                            (data . ,(demo-base64 demo-picture))))))))))))
       (session_id . ,(ecc-session-id demo-session))
       (uuid . ,(demo-id "uuid")))))
  nil)

(defun demo-file-path-image ()
  "A tool that named a GIF and whose result carried no picture of its own."
  (let ((use (demo-id "toolu")))
    (demo-feed
     (demo-assistant
      (vector `((type . "tool_use")
                (id . ,use)
                (name . "Read")
                (input . ((file_path . ,demo-gif)))))))
    (demo-feed
     `((type . "user")
       (message . ((role . "user")
                   (content . ,(vector `((tool_use_id . ,use)
                                         (type . "tool_result")
                                         (content . "Read 1 image"))))))
       (session_id . ,(ecc-session-id demo-session))
       (uuid . ,(demo-id "uuid")))))
  nil)

(defun demo-video-thumbnail ()
  "A tool that named a video: ffmpeg pulls the first frame out."
  (let ((use (demo-id "toolu")))
    (demo-feed
     (demo-assistant
      (vector `((type . "tool_use")
                (id . ,use)
                (name . "Read")
                (input . ((file_path . ,demo-video)))))))
    (demo-feed
     `((type . "user")
       (message . ((role . "user")
                   (content . ,(vector `((tool_use_id . ,use)
                                         (type . "tool_result")
                                         (content . "Read 1 video"))))))
       (session_id . ,(ecc-session-id demo-session))
       (uuid . ,(demo-id "uuid")))))
  nil)

(defun demo-finish-turn ()
  "Close the turn the way a result message does."
  (demo-feed `((type . "result")
               (subtype . "success")
               (is_error . :false)
               (session_id . ,(ecc-session-id demo-session))
               (uuid . ,(demo-id "uuid"))))
  nil)

;;;; What the buffer holds

(defun demo-transcript ()
  "Return the transcript buffer of the session."
  (ecc-session-buffer demo-session))

(defun demo-show-transcript ()
  "Put the transcript on the screen and go to the end of it."
  (ecc-display-session demo-session)
  (when-let* ((window (get-buffer-window (demo-transcript) t)))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1)))
  (demo-frame)
  nil)

(defun demo-image-positions ()
  "Return the positions of the images drawn in the transcript."
  (with-current-buffer (demo-transcript)
    (let ((position (point-min)) found)
      (while (setq position (next-single-property-change position 'display))
        (when (eq (car-safe (get-text-property position 'display)) 'image)
          (push position found)))
      (nreverse found))))

(defun demo-report-images ()
  "Say how many pictures are drawn, and what the lines beside them name."
  (with-current-buffer (demo-transcript)
    (let ((positions (demo-image-positions)))
      (demo-say
       (format "%d image(s) drawn: %s"
               (length positions)
               (or (mapconcat
                    (lambda (position)
                      (let ((descriptor (get-text-property position 'display)))
                        (format "%s%s"
                                (file-name-nondirectory
                                 (or (plist-get (cdr descriptor) :file) "?"))
                                (if (plist-get (cdr descriptor) :animate) " (animating)" ""))))
                    positions ", ")
                   "none")))))
  nil)

(defun demo-point-on-tool ()
  "Put point on the heading of the first tool call of the transcript.
`TAB\=' folds the node point is on, and a picture drawn inside a tool\='s
body is not that node: on the picture it answers \"Nothing to fold
here\" (2026-09-18)."
  (let ((buffer (demo-transcript)))
    (with-current-buffer buffer
      (let ((position (point-min)) found)
        (while (and (not found)
                    (setq position (next-single-property-change position 'ecc-node)))
          (when-let* ((id (get-text-property position 'ecc-node))
                      (node (ecc-model-node demo-session id)))
            (when (eq (ecc-node-type node) 'tool)
              (setq found position))))
        (unless found (error "No tool call in the transcript"))
        (goto-char found)
        (when-let* ((window (get-buffer-window buffer t)))
          (set-window-point window found)
          (with-selected-window window (recenter -6)))
        (demo-say (format "point is on the tool heading: %s"
                          (string-trim
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position))))))))
  nil)

(defun demo-report-folds ()
  "Say which tool nodes of the transcript are folded.
A tool call starts folded, and the images of a tool are drawn inside its
body: a `Read\=' of a .png drew a heading with the picture behind the
fold until 2026-09-17.  One that brought a picture opens now, and `TAB\='
still folds it."
  (with-current-buffer (demo-transcript)
    (let (rows)
      (maphash
       (lambda (id node)
         (when (eq (ecc-node-type node) 'tool)
           (push (format "%s %s"
                         (or (ecc-model-node-get node 'name) "?")
                         (if (ecc-render--wanted-hidden-p id) "folded" "OPEN"))
                 rows)))
       (ecc-session-nodes demo-session))
      (demo-say (format "tool nodes: %s"
                        (or (string-join (nreverse rows) " | ") "none")))))
  nil)

(defun demo-fold-at-point ()
  "Fold what point is on, the way TAB does in the transcript."
  (demo-transcript-key "TAB")
  nil)

(defun demo-report-no-base64 ()
  "Say whether any base64 reached the buffer, which is what this fixes."
  (with-current-buffer (demo-transcript)
    (save-excursion
      (goto-char (point-min))
      (demo-say
       (if (re-search-forward "[A-Za-z0-9+/]\\{200,\\}" nil t)
           (format "base64 in the buffer at %d -- that is the bug" (point))
         "no run of 200 base64 characters anywhere in the transcript"))))
  nil)

(defun demo-report-image-dir ()
  "Say what was written into the session's image directory."
  (let* ((directory (ecc-session-image-dir demo-session))
         (files (and (file-directory-p directory)
                     (directory-files directory nil "\\`[^.]"))))
    (demo-say (format "%s holds %d file(s): %s"
                      (abbreviate-file-name directory)
                      (length files)
                      (string-join files ", "))))
  nil)

(defun demo-report-timers ()
  "Say how many image animation timers Emacs is carrying."
  (demo-say (format "timers running image-animate: %d"
                    (seq-count (lambda (timer)
                                 (string-match-p
                                  "image-animate"
                                  (format "%S" (timer--function timer))))
                               (append timer-list timer-idle-list))))
  nil)

;;;; The keys of the transcript

(defun demo-transcript-key (key &optional text prefix)
  "Run what KEY is bound to in the transcript."
  (demo-run-key-in (demo-transcript) key text prefix))

(defun demo-say-transcript-key (key)
  "Say what KEY runs in the transcript."
  (demo-say-key-in (demo-transcript) key))

(defun demo-point-on-image (name)
  "Put point on the image whose file is called NAME."
  (when-let* ((window (get-buffer-window (demo-transcript) t)))
    (with-selected-window window
      (with-current-buffer (demo-transcript)
        (let ((found (seq-find
                      (lambda (position)
                        (string-match-p
                         (regexp-quote name)
                         (or (plist-get (cdr (get-text-property position 'display))
                                        :file)
                             "")))
                      (demo-image-positions))))
          (unless found (error "No picture called %s is drawn" name))
          (goto-char found)
          (set-window-point window found)
          (recenter -4)))))
  (demo-report-images))

(defun demo-report-opened ()
  "Say what buffer `RET' on a picture left on the screen."
  (demo-say (format "windows now: %s"
                    (mapconcat (lambda (window)
                                 (format "%s (%s)"
                                         (buffer-name (window-buffer window))
                                         (buffer-local-value
                                          'major-mode (window-buffer window))))
                               (window-list nil 'no-minibuffer) " | ")))
  nil)

(defun demo-close-image-buffer ()
  "Close whatever `RET' opened, leaving the transcript."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'major-mode buffer) 'image-mode)
      (kill-buffer buffer)))
  (demo-show-transcript)
  nil)

(defun demo-toggle-inline ()
  "Turn the drawing off, or on, the way `I' in the menu does."
  (ecc-image-toggle-inline)
  (demo-say (format "ecc-image-inline = %S" ecc-image-inline))
  nil)

;;;; The prompt's own attachment

(defun demo-send-with-attachment ()
  "Send a prompt that attaches the still as `@path', the fourth way in."
  (ecc-proc-send-prompt
   demo-session
   (format "@%s  Reply with exactly: seen" demo-picture))
  nil)

(defun demo-cleanup ()
  "Stop the session."
  (when (and demo-session (process-live-p (ecc-session-process demo-session)))
    (ignore-errors (ecc-kill demo-session)))
  nil)

(provide 'images-inline)
;;; images-inline.el ends here
