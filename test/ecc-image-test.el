;;; ecc-image-test.el --- Tests for ecc-image  -*- lexical-binding: t; -*-

;;; Commentary:

;; The directory a session writes its images to, what a file is named
;; and when it is swept away.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-image)

(defmacro ecc-image-test--with-dir (&rest body)
  "Run BODY with `ecc-image-dir' pointing at a directory of its own."
  (declare (indent 0))
  `(let ((ecc-image-dir (make-temp-file "ecc-images" t)))
     (unwind-protect (progn ,@body)
       (when (file-directory-p ecc-image-dir)
         (delete-directory ecc-image-dir t)))))

(ert-deftest ecc-image-test-save-writes-under-the-session ()
  "An image lands in the directory of its session, named by its type."
  (ecc-test-with-fake-session session
    (ecc-image-test--with-dir
      (let ((file (ecc-image-save session "\x89PNG-data" "image/png")))
        (should (file-exists-p file))
        (should (equal (file-name-extension file) "png"))
        (should (string-prefix-p (expand-file-name (ecc-session-id session)
                                                   ecc-image-dir)
                                 file))
        ;; jpeg keeps the extension the CLI expects.
        (should (equal (file-name-extension
                        (ecc-image-save session "x" "image/jpeg"))
                       "jpg"))
        ;; A name given by hand is what the file is called.
        (should (equal (file-name-nondirectory
                        (ecc-image-save session "x" "image/png" "abc123"))
                       "abc123.png"))
        (should (ecc-image-cleanup-session session))
        (should-not (file-exists-p file))))))

(ert-deftest ecc-image-test-images-can-be-kept ()
  "With cleanup off the files outlive the session."
  (ecc-test-with-fake-session session
    (let ((ecc-image-cleanup 'never))
      (ecc-image-test--with-dir
        (let ((file (ecc-image-save session "x" "image/png")))
          (should-not (ecc-image-cleanup-session session))
          (should (file-exists-p file)))))))

;;;; What a path is

(ert-deftest ecc-image-test-kind ()
  "An extension says how a file is drawn, whatever its case."
  (should (eq (ecc-image-kind "/tmp/a.png") 'image))
  (should (eq (ecc-image-kind "/tmp/a.JPEG") 'image))
  (should (eq (ecc-image-kind "/tmp/a.svg") 'image))
  (should (eq (ecc-image-kind "/tmp/a.gif") 'animated))
  (should (eq (ecc-image-kind "/tmp/a.mp4") 'video))
  (should (eq (ecc-image-kind "/tmp/a.MOV") 'video))
  (should-not (ecc-image-kind "/tmp/a.txt"))
  (should-not (ecc-image-kind "/tmp/a"))
  (should-not (ecc-image-kind nil))
  (should (ecc-image-file-p "/tmp/a.png"))
  (should (ecc-image-video-p "/tmp/a.mp4"))
  (should-not (ecc-image-video-p "/tmp/a.png"))
  (should (eq (ecc-image-type "/tmp/a.jpg") 'jpeg)))

;;;; What arrives from the CLI

(ert-deftest ecc-image-test-materialize-writes-the-bytes ()
  "A base64 source becomes a file of exactly those bytes, named by its hash."
  (ecc-test-with-fake-session session
    (ecc-image-test--with-dir
      (let* ((png (ecc-test-image-bytes))
             (source `((type . "base64") (media_type . "image/png")
                       (data . ,(base64-encode-string png t))))
             (entry (ecc-image-materialize session source))
             (path (alist-get 'path entry)))
        (should (file-exists-p path))
        (should (equal (alist-get 'bytes entry) (length png)))
        (should (equal (alist-get 'media-type entry) "image/png"))
        (should (equal (file-name-nondirectory path)
                       (concat (sha1 png) ".png")))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally path)
          (should (equal (buffer-string) png)))
        ;; The same image twice is the same file: the name is the hash,
        ;; so a streamed block and the message that closes it agree.
        (should (equal (alist-get 'path (ecc-image-materialize session source))
                       path))))))

(ert-deftest ecc-image-test-a-url-is-not-fetched ()
  "A URL source is carried as a URL and nothing is written."
  (ecc-test-with-fake-session session
    (ecc-image-test--with-dir
      (let ((entry (ecc-image-materialize
                    session '((type . "url") (url . "https://example.com/a.png")))))
        (should (equal (alist-get 'url entry) "https://example.com/a.png"))
        (should-not (alist-get 'path entry))
        (should-not (file-directory-p
                     (expand-file-name (ecc-session-id session) ecc-image-dir))))
      (should-not (ecc-image-materialize session '((type . "file") (file_id . "x")))))))

;;;; What it is drawn as

(ert-deftest ecc-image-test-label-names-the-file-alone ()
  "The label carries the name and the size, never the directory."
  (should (equal (ecc-image-label "/tmp/ecc-images/abc/deadbeef.png" 79)
                 "image · deadbeef.png · 79 B"))
  (should (equal (ecc-image-label "/tmp/a.png" 1300) "image · a.png · 1.3 kB"))
  (should (equal (ecc-image-label "/tmp/clip.mp4") "video · clip.mp4")))

(ert-deftest ecc-image-test-string-falls-back-to-the-label ()
  "Where nothing can be drawn the string is the label and no more."
  (let ((path (ecc-test-image-file)))
    (let ((string (ecc-image-string path 400 400 79)))
      ;; Batch draws nothing, so this is the path every test takes.
      (should (equal (substring-no-properties string)
                     (ecc-image-label path 79)))
      (should-not (get-text-property 0 'display string))
      (should (equal (get-text-property 0 'ecc-image-file string) path)))
    ;; And with the setting off, nothing is drawn even in a window.
    (let ((ecc-image-inline nil))
      (should-not (ecc-image-available-p path)))))

(ert-deftest ecc-image-test-a-broken-file-does-not-signal ()
  "A file that is not the image it claims to be leaves a log line."
  (ecc-image-test--with-dir
    (let ((path (expand-file-name "broken.png" ecc-image-dir)))
      (with-temp-file path (insert "not a png"))
      (should-not (ecc-image-descriptor path 400 400)))))


;;;; Videos

(ert-deftest ecc-image-test-no-ffmpeg-no-thumbnail ()
  "Without ffmpeg there is no first frame and nothing is started."
  (ecc-test-with-fake-session session
    (ecc-image-test--with-dir
      (let ((ecc-image-ffmpeg-program "ecc-no-such-ffmpeg")
            (ecc-image--ffmpeg 'unset))
        (should-not (ecc-image-ffmpeg))
        (should-not (ecc-image-thumbnail session (ecc-test-image-file)))))))

(ert-deftest ecc-image-test-a-video-ffmpeg-cannot-read-is-tried-once ()
  "A video that yields no frame is asked for once, not on every redraw."
  (ecc-test-with-fake-session session
    (ecc-image-test--with-dir
      (let* ((video (expand-file-name "broken.mp4" ecc-image-dir))
             (started 0)
             (ecc-image--ffmpeg "/bin/false")
             (ecc-image--thumbnails (make-hash-table :test 'equal)))
        (with-temp-file video (insert "not a video"))
        (cl-letf (((symbol-function 'ecc-image--start-thumbnail)
                   (lambda (_video file _ready)
                     (cl-incf started)
                     (puthash file 'failed ecc-image--thumbnails))))
          (should-not (ecc-image-thumbnail session video))
          (should-not (ecc-image-thumbnail session video))
          (should-not (ecc-image-thumbnail session video))
          (should (= started 1)))))))

(ert-deftest ecc-image-test-a-thumbnail-already-made-is-reused ()
  "A first frame on disk is returned without starting anything."
  (ecc-test-with-fake-session session
    (ecc-image-test--with-dir
      (let* ((video (expand-file-name "clip.mp4" ecc-image-dir))
             (ecc-image--ffmpeg "/bin/false")
             (ecc-image--thumbnails (make-hash-table :test 'equal)))
        (with-temp-file video (insert "x"))
        (let ((thumb (ecc-image--thumbnail-file session video)))
          (copy-file (ecc-test-image-file) thumb)
          (cl-letf (((symbol-function 'ecc-image--start-thumbnail)
                     (lambda (&rest _) (error "Should not be started"))))
            (should (equal (ecc-image-thumbnail session video) thumb))))))))

(ert-deftest ecc-image-test-a-video-is-drawn-by-its-first-frame ()
  "The string of a video names the video and shows the frame."
  (let ((video "/tmp/clip.mp4"))
    (should (equal (substring-no-properties
                    (ecc-image-string video 400 400 nil (ecc-test-image-file)))
                   "video · clip.mp4"))
    ;; And the file RET reaches is the video, not the still.
    (should (equal (get-text-property
                    0 'ecc-image-file
                    (ecc-image-string video 400 400 nil (ecc-test-image-file)))
                   video))))

;;;; Looking at one

(ert-deftest ecc-image-test-view-picks-by-kind ()
  "A video goes outside Emacs and a still opens in a buffer."
  (let (outside inside)
    (cl-letf (((symbol-function 'ecc-image-open-externally)
               (lambda (path) (setq outside path)))
              ((symbol-function 'find-file-other-window)
               (lambda (path) (setq inside path))))
      (with-temp-buffer
        (insert (propertize "clip" 'ecc-image-file "/tmp/clip.mp4"))
        (goto-char (point-min))
        (ecc-image-view-at-point)
        (should (equal outside "/tmp/clip.mp4")))
      (with-temp-buffer
        (insert (propertize "shot" 'ecc-image-file "/tmp/shot.png"))
        (goto-char (point-min))
        (ecc-image-view-at-point)
        (should (equal inside "/tmp/shot.png")))
      (with-temp-buffer
        (insert "plain text")
        (goto-char (point-min))
        (should-error (ecc-image-view-at-point) :type 'user-error)))))

(provide 'ecc-image-test)

;;; ecc-image-test.el ends here
