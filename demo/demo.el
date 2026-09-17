;;; demo.el --- The Emacs side of a recorded demonstration  -*- lexical-binding: t; -*-

;;; Commentary:

;; What `demo/record.sh' loads into the Emacs it records: the user's own
;; configuration, this checkout's ecc in front of whatever that
;; configuration points at, and the handful of things a scene needs to
;; be driven from outside -- a caption, a frame of the size the video is
;; taken at, and a way to run a key of a buffer that does not have the
;; keyboard.
;;
;; What is recorded is this frame's own window, so the demonstration
;; neither raises itself nor takes the keyboard: it can be played beside
;; somebody working.
;;
;; A scene is two files under demo/scenes: NAME.el, loaded here, which
;; says what to build and defines the steps; and NAME.sh, read by the
;; recorder, which is the order they are played in and how long each is
;; held.  demo/README.md says how to write one.
;;
;; Everything here is for a demonstration, and none of it is loaded by
;; ecc or touched by the tests.

;;; Code:

(require 'seq)

(defvar demo-scene-file nil
  "The NAME.el of the scene being played.  Set by the recorder.")

(defvar demo-server-name "ecc-demo"
  "The server the recorder steps this Emacs through.")

(defvar demo-ready-file "/tmp/ecc-demo-ready.txt"
  "Written once the scene is built, with the ecc this Emacs is running.")

(defvar demo-frame-title "ecc demo"
  "The title of the frame the demonstration is played in.
It is how `demo-main-frame\\=' finds it among the frames a scene opens,
and how the recorder finds the window to record.  The recorder sets it
to a name of its own, one per scene, so that two runs at once do not
record each other's frame.")

(defvar demo-frame-position '(40 . 140)
  "Where the frame is held, in pixels.
The top left is left clear of it: the ediff control panel is a frame of
its own, placed above the top of this one.")

(defvar demo-frame-size '(1700 . 950)
  "How big the frame is held, in pixels.")

(defvar demo-root "/tmp/ecc-demo-project/"
  "The throwaway project a scene builds.")

;;;; The configuration this is played in

;; The point of a demonstration is the change as the user will meet it,
;; so this is the user's own init rather than a dressed-up -Q.  `open' on
;; macOS does not pass the shell environment on, and an Emacs started
;; that way with this init never processes its command line, so it is all
;; loaded here by hand (see the comment in demo/record.sh).
(defvar demo-init-file (expand-file-name "~/.emacs.d/init.el")
  "The configuration the demonstration is played in.")

(defun demo-load-configuration ()
  "Load the user's configuration, then this checkout's ecc."
  (setq package-user-dir (expand-file-name "~/.emacs.d/elpa"))
  (load (expand-file-name "~/.emacs.d/early-init.el") t t)
  (package-initialize)
  (load demo-init-file t t)
  ;; The init points ecc at a worktree of its own, which is not
  ;; necessarily the one being demonstrated.  This one wins, and
  ;; `demo-ready-file' says which one it was.
  (let ((checkout (directory-file-name
                   (file-name-directory
                    (directory-file-name
                     (file-name-directory (or load-file-name buffer-file-name)))))))
    (add-to-list 'load-path checkout))
  (require 'ecc))

;;;; Saying what is going on

(defun demo-say (text)
  "Put TEXT in the echo area, where the camera can read it."
  (let ((message-log-max 1000))
    (message "%s" text))
  nil)

;;;; The frame the video is taken of

(defun demo-main-frame ()
  "Return the frame the demonstration is played in."
  (seq-find (lambda (frame)
              (equal (frame-parameter frame 'name) demo-frame-title))
            (frame-list)))

(defun demo-float ()
  "Do nothing, and stay callable: the scenes written before this call it.
It used to hold every frame of this Emacs above the windows of other
applications, because the recording was of the screen and anything in
front of the frame was in the picture -- including the Emacs the user
was working in, which is the one macOS keeps in front (2026-09-16).

What is recorded now is the frame\='s own window
\(demo/record-window.swift), composited whatever covers it, so there is
nothing to raise.  Raising was not free: it put itself in front of the
user\='s work and took the keyboard with it."
  nil)

(defun demo-frame ()
  "Give the frame the size the recording is taken at.
The size is what matters -- it is the shape of the video -- and the
position no longer does: the window is recorded where it stands.  The
frame is neither raised nor given the keyboard, so a recording can run
beside somebody working."
  (when-let* ((frame (demo-main-frame)))
    (set-frame-size frame (car demo-frame-size) (cdr demo-frame-size) t)
    (set-frame-position frame (car demo-frame-position) (cdr demo-frame-position))
    ;; A warning window opens over the scene and says nothing about it.
    (when-let* ((window (get-buffer-window "*Warnings*" t)))
      (delete-window window)))
  nil)

(defvar demo-pin-timer nil
  "The timer that holds the frame in place.")

(defvar demo-pin-tick 0
  "How many times the pin has fired.")

(defun demo-pin ()
  "Hold the frame at the size the recording is taken at.
Something on this machine moves the frame back to the corner it started
in some time after a scene rearranges the screen; neither ecc nor the
init moves a frame, and what does was not found (2026-09-16).  Where it
sits no longer matters, but a frame that is moved is a frame that may be
resized, and the size is the shape of the video."
  (setq demo-pin-tick (1+ demo-pin-tick))
  (when-let* ((frame (demo-main-frame)))
    (unless (equal (frame-position frame) demo-frame-position)
      (set-frame-size frame (car demo-frame-size) (cdr demo-frame-size) t)
      (set-frame-position frame (car demo-frame-position)
                          (cdr demo-frame-position)))))

(defun demo-pin-start ()
  "Start holding the frame in place."
  (unless demo-pin-timer
    (setq demo-pin-timer (run-at-time 1 0.5 #'demo-pin)))
  nil)

;;;; Running a step

(defun demo-window-of (buffer)
  "Return a window showing BUFFER on any frame, or nil."
  (and (buffer-live-p (get-buffer buffer))
       (get-buffer-window (get-buffer buffer) t)))

(defun demo-run-key-in (buffer key &optional text prefix)
  "Run what KEY is bound to in BUFFER, as if it had been typed there.
TEXT, when given, is the answer a command that reads from the minibuffer
gets; it is left on `unread-command-events\\=' the way real typing would
arrive, and a RET is put after it.  PREFIX is the prefix argument.

The keys are not fed to the command loop the way a scene of
`scripts/docshots.el\\=' feeds them.  This Emacs is not the one macOS has
in front, so the frame it selects is not the frame the keyboard goes to:
a `?\\=' meant for an ediff control panel went into the review buffer
instead and was answered with \"Buffer is read-only\" (2026-09-16).
Looking the key up in the buffer and calling what is bound there runs
the same command through the same keymap.

It is scheduled rather than run: Emacs does not answer the server while
it is reading from the minibuffer, so a step that opens one has to
return first."
  (run-at-time
   0.2 nil
   (lambda ()
     (when-let* ((window (demo-window-of buffer)))
       (with-selected-frame (window-frame window)
         (with-selected-window window
           (with-current-buffer (get-buffer buffer)
             (let ((command (key-binding (kbd key))))
               (when text
                 (setq unread-command-events
                       (append (string-to-list text)
                               (listify-key-sequence (kbd "RET")))))
               (let ((current-prefix-arg prefix))
                 (call-interactively command)))))))))
  nil)

(defun demo-say-key-in (buffer key)
  "Say what KEY runs in BUFFER, which is worth seeing for a key that changed."
  (with-current-buffer (get-buffer buffer)
    (demo-say (format "%s runs %S" key (key-binding (kbd key)))))
  nil)

;;;; The throwaway project

(defun demo-git (&rest args)
  "Run git with ARGS in `demo-root\\='."
  (let ((default-directory demo-root))
    (apply #'call-process "git" nil nil nil args)))

(defun demo-write (name content)
  "Write CONTENT into NAME of `demo-root\\='."
  (let ((path (expand-file-name name demo-root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert content))))

(defun demo-fresh-repository ()
  "Make `demo-root\\=' an empty git repository, replacing what was there."
  (delete-directory demo-root t)
  (make-directory demo-root t)
  (demo-git "init" "-q")
  (demo-git "config" "user.email" "demo@example.com")
  (demo-git "config" "user.name" "demo")
  nil)

;;;; Setting up

(declare-function demo-scene-build "the scene")

(defun demo-setup ()
  "Lay the frame out and build the scene, once there is a frame to lay out."
  (if (not (and (display-graphic-p) (frame-visible-p (selected-frame))))
      (run-at-time 0.5 nil #'demo-setup)
    (demo-frame)
    (demo-scene-build)
    (demo-pin-start)
    ;; The recorder waits for this file, and reads it: a demonstration
    ;; of a branch is worth nothing if it ran the ecc of another one.
    (with-temp-file demo-ready-file
      (insert (format "%s\n" (locate-library "ecc"))))))

(demo-load-configuration)

(setq native-comp-async-report-warnings-errors 'silent
      warning-minimum-level :error
      inhibit-startup-screen t
      frame-title-format demo-frame-title
      ;; A demonstration pauses for the camera; a caption should not
      ;; clear itself while it is being read.
      minibuffer-message-timeout 10)

(setq server-name demo-server-name)
(require 'server)
(server-start)

(load demo-scene-file nil t)

(run-at-time 1 nil #'demo-setup)

(provide 'demo)
;;; demo.el ends here
