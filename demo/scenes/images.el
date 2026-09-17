;;; images.el --- Pictures and video in the transcript  -*- lexical-binding: t; -*-

;;; Commentary:

;; 0.3.0 draws images and video in the transcript, and the four ways one
;; gets there are all in this scene: an image block on a message, an
;; image inside a `tool_result' (a Read of a .png, a screenshot from an
;; MCP tool), an image file a tool only named by `file_path', and the
;; images a prompt attached as `@path'.  The first is sent to a real
;; session and comes back through the CLI; the others are handed to the
;; dispatcher the way the stream brings them.
;;
;; What the scene is there to show: no base64 in the buffer, a line
;; naming each file so that a copy and a search still find it, a GIF
;; that moves and is stopped with `I', a video drawn as the first frame
;; ffmpeg pulls out of it, and `ecc-image-inline' turning the lot back
;; into lines.
;;
;; Played by demo/scenes/images.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-image)
(require 'ecc-dispatch)
(require 'ecc-render)
(require 'ecc-prompt)

(defvar demo-session nil "The session the pictures are drawn in.")
(defvar demo-png nil "A still, written by ffmpeg.")
(defvar demo-gif nil "An animation, written by ffmpeg.")
(defvar demo-video nil "A video, written by ffmpeg.")

;;;; The pictures

(defun demo-ffmpeg (&rest args)
  "Run ffmpeg with ARGS, quietly."
  (apply #'call-process (or (ecc-image-ffmpeg) "ffmpeg") nil nil nil
         (append '("-y" "-loglevel" "error") args)))

(defun demo-make-pictures ()
  "Write a still, an animation and a video into the project."
  (setq demo-png (expand-file-name "chart.png" demo-root)
        demo-gif (expand-file-name "spinner.gif" demo-root)
        demo-video (expand-file-name "clip.mp4" demo-root))
  (demo-ffmpeg "-f" "lavfi" "-i" "testsrc=size=480x270:rate=1" "-frames:v" "1" demo-png)
  (demo-ffmpeg "-f" "lavfi" "-i" "testsrc2=size=240x135:rate=8" "-t" "2"
               "-loop" "0" demo-gif)
  (demo-ffmpeg "-f" "lavfi" "-i" "testsrc=size=480x270:rate=10" "-t" "3"
               "-pix_fmt" "yuv420p" demo-video)
  nil)

(defun demo-scene-build ()
  "Build the project and its pictures.  Called by demo.el."
  (demo-fresh-repository)
  (demo-write "README.md" "# pictures\n\nA project with a chart in it.\n")
  (demo-make-pictures)
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "README.md" demo-root))
  (delete-other-windows)
  (demo-say (format "ffmpeg: %s   ecc-image-inline = %S"
                    (or (ecc-image-ffmpeg) "NOT FOUND") ecc-image-inline))
  nil)

;;;; The session

(defun demo-start-session ()
  "Start a real session in the project."
  (setq demo-session (ecc-start demo-root "pictures"))
  (demo-frame)
  nil)

(defun demo-attach-and-send ()
  "Attach the still to a prompt as @path and send it to the CLI."
  (with-current-buffer (ecc-session-buffer demo-session)
    (goto-char (point-max))
    (ecc-prompt-insert-image demo-png)
    (insert " -- answer in one short English sentence: what is in this picture?")
    (ecc-prompt-send))
  nil)

;;;; The other three ways in

(defun demo-message-image ()
  "An image block on an assistant message: a screenshot from an MCP tool."
  (ecc-dispatch demo-session
                `((type . "assistant") (uuid . "demo-image-1")
                  (message
                   . ((content
                       . [((type . "text")
                           (text . "Here is the screenshot the MCP tool returned:"))
                          ((type . "image")
                           (source . ((type . "base64") (media_type . "image/png")
                                      (data . ,(base64-encode-string
                                                (with-temp-buffer
                                                  (set-buffer-multibyte nil)
                                                  (insert-file-contents-literally demo-png)
                                                  (buffer-string))
                                                t)))))])))))
  (ecc-render-flush demo-session)
  nil)

(defun demo-result-image ()
  "A Read of a .png answered with the picture itself, inside the result."
  (ecc-dispatch demo-session
                `((type . "assistant") (uuid . "demo-image-2")
                  (message . ((content . [((type . "tool_use") (id . "demo-read")
                                           (name . "Read")
                                           (input . ((file_path . ,demo-png))))])))))
  (ecc-dispatch demo-session
                `((type . "user")
                  (message
                   . ((content
                       . [((type . "tool_result") (tool_use_id . "demo-read")
                           (content . [((type . "text") (text . "read 480x270 PNG"))
                                       ((type . "image")
                                        (source . ((type . "base64")
                                                   (media_type . "image/png")
                                                   (data . ,(base64-encode-string
                                                             (with-temp-buffer
                                                               (set-buffer-multibyte nil)
                                                               (insert-file-contents-literally demo-png)
                                                               (buffer-string))
                                                             t)))))]))])))))
  (ecc-render-flush demo-session)
  nil)

(defun demo-named-file (id path text)
  "A tool that only names PATH by `file_path', answered with TEXT."
  (ecc-dispatch demo-session
                `((type . "assistant") (uuid . ,(concat "u-" id))
                  (message . ((content . [((type . "tool_use") (id . ,id)
                                           (name . "Write")
                                           (input . ((file_path . ,path))))])))))
  (ecc-dispatch demo-session
                `((type . "user")
                  (message . ((content . [((type . "tool_result")
                                           (tool_use_id . ,id)
                                           (content . ,text))])))))
  (ecc-render-flush demo-session)
  nil)

(defun demo-gif-file ()
  "A tool that wrote the animation."
  (demo-named-file "demo-gif" demo-gif "wrote spinner.gif"))

(defun demo-video-file ()
  "A tool that wrote the video: ffmpeg pulls the first frame out of it."
  (demo-named-file "demo-video" demo-video "wrote clip.mp4"))

;;;; What the buffer holds

(defun demo-buffer-text ()
  "Return the transcript as plain text."
  (with-current-buffer (ecc-session-buffer demo-session)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun demo-report-no-base64 ()
  "Say that the payload is nowhere in the buffer, and the lines are."
  (let ((text (demo-buffer-text)))
    (demo-say (format "base64 in the buffer: %s   ·   lines naming a file: %d   ·   longest line: %d chars"
                      (if (string-match-p "base64\\|[A-Za-z0-9+/]\\{200\\}" text) "YES" "none")
                      (cl-count-if (lambda (line) (string-match-p "image · \\|video · " line))
                                   (split-string text "\n"))
                      (apply #'max (mapcar #'length (split-string text "\n"))))))
  nil)

(defun demo-report-files ()
  "Say what the session wrote into its image directory."
  (let ((dir (ecc-session-image-dir demo-session)))
    (demo-say (format "%s: %s" (abbreviate-file-name dir)
                      (string-join (directory-files dir nil "[^.]") "  "))))
  nil)

(defun demo-report-images ()
  "Say which of the drawn images Emacs really has displays for."
  (with-current-buffer (ecc-session-buffer demo-session)
    (let (kinds)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((image (get-text-property (point) 'display)))
            (when (and (consp image) (eq (car image) 'image))
              (push (format "%s" (plist-get (cdr image) :type)) kinds)))
          (forward-char 1)))
      (demo-say (format "image displays in the buffer: %s"
                        (or (string-join (nreverse (delete-dups kinds)) "  ") "none")))))
  nil)

;;;; v and I

(defun demo-goto-gif ()
  "Put point on the animation."
  (with-current-buffer (ecc-session-buffer demo-session)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (with-selected-window window
        (goto-char (point-max))
        (when (re-search-backward "spinner\\.gif" nil t)
          (goto-char (line-beginning-position))
          (forward-line 1)
          (recenter -6)))))
  nil)

(defun demo-report-animation ()
  "Say whether the picture at point is moving."
  (with-current-buffer (ecc-session-buffer demo-session)
    (let ((image (ecc-image-at-point)))
      (demo-say (format "the picture at point: %s"
                        (cond ((null image) "none here")
                              ((image-animate-timer image) "moving")
                              (t "still"))))))
  nil)

(defun demo-toggle-animation ()
  "v -- stop the picture at point, or set it moving again."
  (demo-run-key-in (ecc-session-buffer demo-session) "I"))

(defun demo-toggle-inline ()
  "I in the menu -- turn the drawing off, and on again."
  (ecc-image-toggle-inline)
  (demo-frame)
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session this scene left running."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'images)
;;; images.el ends here
