;;; ecc-image.el --- The images of a session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Everything to do with an image or a video of a session, on the way
;; out and on the way in: the directory a session writes them to, the
;; file an image block is decoded into, and what a path is drawn as.
;;
;; It is a leaf: it requires `ecc-core' and `ecc-model' and nothing
;; else.  That is the point of it.  `ecc-prompt' already requires
;; `ecc-render', so the helpers that write an image to disk cannot live
;; in `ecc-prompt' and be called from the renderer as well; they live
;; here, below both.
;;
;; Nothing here draws.  `ecc-image-string' returns a propertized string
;; and `ecc-render' is what inserts it, the way `ecc-markdown' hands
;; over fontified text.

;;; Code:

(require 'cl-lib)
;; `image-animate' and its timer are not autoloaded, and a machine whose
;; Emacs happens to have image.el loaded already will compile this
;; without saying so.
(require 'image)
(require 'browse-url)
(require 'ecc-core)
(require 'ecc-model)

;;;; Options

(defvar ecc-image-dir (expand-file-name "ecc-images" temporary-file-directory)
  "Directory the images of a session are written to.
Each session gets a subdirectory of its own.  Both the images pasted
into a prompt and the ones the CLI sends back land there.")

(defvar ecc-image-cleanup 'on-exit
  "What becomes of the images of a session when it ends.
`on-exit' deletes the directory of the session, `never' keeps it.  The
recording refers to the files by path, so keeping them is what makes an
old conversation readable again.")

(defcustom ecc-image-inline t
  "Non-nil draws an image in the transcript rather than naming it.
A transcript read as text, or one on the far end of a slow connection,
is better off with the line that names the file; the line is drawn
either way and the picture sits on top of it."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-image-max-height 400
  "Most pixels tall an image is drawn in the transcript.
The width follows `ecc-chat-text-width\=' and the window; the height is
what keeps one screenshot from filling the screen."
  :type 'integer
  :group 'ecc)

(defvar ecc-image-extensions
  '(("png" . png) ("jpg" . jpeg) ("jpeg" . jpeg) ("gif" . gif)
    ("webp" . webp) ("svg" . svg) ("bmp" . bmp) ("tiff" . tiff)
    ("tif" . tiff) ("ico" . ico) ("pbm" . pbm) ("xpm" . xpm))
  "Extensions Emacs can draw, and the image type each one is.
The type is what `image-type-available-p\=' is asked about: a build
without librsvg draws a PNG and not an SVG, and the answer differs per
type rather than per build.")

(defvar ecc-image-video-extensions
  '("mp4" "mov" "webm" "mkv" "avi" "m4v" "mpg" "mpeg" "ogv" "gif")
  "Extensions taken for a video.
`gif\=' is in both tables and `ecc-image-kind\=' calls it animated: Emacs
draws it, and it moves.")

;;;; What a path is

(defun ecc-image--extension-of (path)
  "Return the downcased extension of PATH, or nil."
  (when-let* ((extension (file-name-extension (or path ""))))
    (downcase extension)))

(defun ecc-image-type (path)
  "Return the Emacs image type PATH would be drawn as, or nil."
  (alist-get (ecc-image--extension-of path) ecc-image-extensions
             nil nil #'equal))

(defun ecc-image-kind (path)
  "Return what PATH is: `image\=', `animated\=', `video\=' or nil.
The extension decides.  Nothing is read: this says how to draw a file,
not whether it is one."
  (let ((extension (ecc-image--extension-of path)))
    (cond ((null extension) nil)
          ((equal extension "gif") 'animated)
          ((member extension ecc-image-video-extensions) 'video)
          ((ecc-image-type path) 'image))))

(defun ecc-image-file-p (path)
  "Return non-nil when PATH is an image or a video this module draws."
  (and (ecc-image-kind path) t))

(defun ecc-image-video-p (path)
  "Return non-nil when PATH is a video Emacs cannot draw by itself."
  (eq (ecc-image-kind path) 'video))

(defun ecc-image-available-p (path)
  "Return non-nil when PATH can be drawn in this frame.
A terminal frame and a batch Emacs draw nothing, and a build without
the library for one type still has the others."
  (and ecc-image-inline
       (display-graphic-p)
       (when-let* ((type (ecc-image-type path)))
         (image-type-available-p type))))

;;;; Where they live

(defun ecc-session-image-dir (session)
  "Return the directory the images of SESSION are written to, creating it."
  (let ((dir (or (ecc-session-tmp-dir session)
                 (setf (ecc-session-tmp-dir session)
                       (file-name-as-directory
                        (expand-file-name (ecc-session-id session)
                                          ecc-image-dir))))))
    (make-directory dir t)
    dir))

(defun ecc-image-cleanup-session (session)
  "Delete the image directory of SESSION when the setting says so."
  (let ((dir (ecc-session-tmp-dir session)))
    (when (and (eq ecc-image-cleanup 'on-exit) dir (file-directory-p dir))
      (delete-directory dir t)
      (setf (ecc-session-tmp-dir session) nil)
      dir)))

(defun ecc-image--extension (mime)
  "Return the file extension for MIME, such as png."
  (let ((name (format "%s" mime)))
    (cond ((string-match "image/\\([a-zA-Z0-9]+\\)" name)
           (let ((type (downcase (match-string 1 name))))
             (if (equal type "jpeg") "jpg" type)))
          (t "png"))))

(defun ecc-image-save (session data mime &optional name)
  "Write DATA, an image of type MIME, into the directory of SESSION.
NAME, without an extension, names the file; the default is the time it
was written, which is what a paste wants.  Returns the file."
  (let ((file (expand-file-name
               (format "%s.%s"
                       (or name (format-time-string "%Y%m%d-%H%M%S-%3N"))
                       (ecc-image--extension mime))
               (ecc-session-image-dir session))))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert data))
    file))

;;;; What arrives from the CLI

(defun ecc-image-materialize (session source)
  "Write the image SOURCE of SESSION to a file and describe it.
SOURCE is what an image content block carries under `source\='.  The
answer is an alist of `path\=' or `url\=', `media-type\=' and `bytes\=', or
nil when the block names an image this side cannot reach.

The file is named by the hash of what is in it, so that the same image
arriving twice — once while the turn streams and once in the message
that closes it — is one file and one name.  A name that changed
between the two would redraw the transcript differently each time."
  (let ((kind (alist-get 'type source))
        (media (or (alist-get 'media_type source) "image/png")))
    (cond
     ((equal kind "base64")
      (when-let* ((data (alist-get 'data source)))
        (let ((bytes (base64-decode-string data)))
          (list (cons 'path (ecc-image-save session bytes media (sha1 bytes)))
                (cons 'media-type media)
                (cons 'bytes (length bytes))))))
     ;; Nothing is fetched here: the renderer must not go to the
     ;; network.  The URL is drawn as a link and the browser opens it.
     ((equal kind "url")
      (when-let* ((url (alist-get 'url source)))
        (list (cons 'url url) (cons 'media-type media))))
     (t nil))))

;;;; What it is drawn as

(defun ecc-image-label (path &optional bytes name)
  "Return the line naming PATH, of BYTES bytes when that is known.
NAME is said instead of the name of the file: an image decoded out of a
message is named by the hash of its bytes, which nobody wants to read,
and the call it came back from usually named a file itself.

Only the last component is named: the rest is a session id and a hash,
which say nothing and would differ between two machines reading the
same recording."
  (let ((kind (or (ecc-image-kind path) 'image)))
    (concat (if (eq kind 'video) "video" "image")
            " · " (file-name-nondirectory (or name path ""))
            (if bytes
                (concat " · " (file-size-human-readable bytes 'si " " "B"))
              ""))))

(defun ecc-image-descriptor (path width height)
  "Return the image descriptor for PATH, at most WIDTH by HEIGHT pixels.
Returns nil when PATH cannot be drawn.  A file that is not the image it
claims to be leaves a line in the log and the label in its place; a
signal here would take the whole redraw down with it."
  (when (and (ecc-image-available-p path) (file-readable-p path))
    (condition-case err
        (create-image path (ecc-image-type path) nil
                      :max-width width :max-height height :ascent 'center)
      (error (ecc-log "image" "%s: %s" path (error-message-string err))
             nil))))

(defun ecc-image-string (path width height &optional bytes name)
  "Return the string PATH is drawn as, at most WIDTH by HEIGHT pixels.
NAME is passed to the label.
The text of it is `ecc-image-label\=', so that a copy of the region, a
search through it and a snapshot of it all find the name of the file.
The picture rides on top in a `display\=' property, and is simply absent
where this frame cannot draw one.  BYTES is passed to the label.

Nothing is inserted here.  `ecc-render\=' is what draws."
  (let* ((label (ecc-image-label path bytes name))
         (string (propertize label
                             'face 'ecc-dim-face
                             'ecc-image-file path
                             'mouse-face 'highlight
                             'help-echo (if (ecc-image-video-p path)
                                            "RET plays it outside Emacs"
                                          "RET opens it, v views it")))
         (image (ecc-image-descriptor path width height)))
    (when image
      (put-text-property 0 (length string) 'display image string))
    string))

(provide 'ecc-image)

;;; ecc-image.el ends here
