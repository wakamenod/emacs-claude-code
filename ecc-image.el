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

(provide 'ecc-image)

;;; ecc-image.el ends here
