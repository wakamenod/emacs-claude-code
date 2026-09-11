;;; docshots.el --- Build the pictures of the documentation site  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives a throwaway GUI Emacs through the scenes the documentation site
;; needs a picture of, so that scripts/docshots.sh can capture them.
;;
;; Like scripts/screenshot.el, and for the same reasons: recorded
;; fixtures are replayed through the real dispatch and the real renderer,
;; so no CLI and no network are involved and the result is the same every
;; time.  The two differ in what they are for -- screenshot.el makes the
;; one animation of README.md, this one makes the stills and the short
;; animations a page of the site points at.
;;
;; The scenes, in the order the wrapper runs them:
;;
;;   switch   two sessions, the picker, and the window changing hands
;;   menu     `ecc-menu' open over a session
;;   resume   the session picker of `ecc-resume', with an icon per state
;;
;; The recordings the resume picker offers are invented here.  The real
;; ones are the conversations of whoever runs this, and their titles and
;; their first prompts would go into a picture on a public site.
;;
;; Run it through scripts/docshots.sh rather than by hand.

;;; Code:

;; `open' on macOS goes through LaunchServices, which does not pass the
;; shell environment on, so the wrapper hands these in with --eval.
(defvar shot-geometry-file "/tmp/ecc-docshot-geom.txt"
  "Where the frame geometry is written for screencapture to read.")

(defvar shot-error-file "/tmp/ecc-docshot-error.txt"
  "Where a failure during setup is written.")

(setq package-user-dir (expand-file-name "~/.emacs.d/elpa"))
(package-initialize)
(add-to-list 'load-path default-directory)
(add-to-list 'load-path (expand-file-name "test" default-directory))
(require 'ecc)
(require 'ecc-test-helpers)
(require 'server)

;; The pictures should show the completion UI most users of this package
;; have, rather than the one a bare Emacs falls back to: the candidates
;; as a list, in a frame of their own over the middle of the window.
(require 'vertico nil t)
(require 'vertico-posframe nil t)

(load-theme 'modus-vivendi t)

(setq ecc-render-debounce 0
      ecc-visual-enable-icons t
      ecc-visual-enable-spinner nil
      ecc-chat-text-width 64
      inhibit-startup-screen t
      frame-title-format "ecc")

(defconst shot-root "/tmp/greet"
  "The demo project.  The fixture's sandbox paths are rewritten to it.")

(defconst shot-file (expand-file-name "hello.py" shot-root))

(defconst shot-before "\
def greet(name):
    \"\"\"Say hi.\"\"\"
    return \"hi \" + name


def farewell(name):
    \"\"\"Say bye.\"\"\"
    return \"bye \" + name
")

(defconst shot-after
  (replace-regexp-in-string "return \"hi \"" "return \"hello \"" shot-before t t))

(defvar shot-main nil "The session the pictures are taken of.")
(defvar shot-other nil "The second session, so that switching has somewhere to go.")

(defun shot-fixture (name)
  "Return fixture NAME as parsed messages, its sandbox paths made ours."
  (delq nil
        (mapcar (lambda (line)
                  (let ((clean (replace-regexp-in-string
                                "\\\\?/private/tmp/claude-[0-9]+/[^\"\\\\ ]*?/sandbox"
                                shot-root line t t)))
                    (unless (string-match-p "despite your instruction" clean)
                      (ecc-protocol-parse-line clean))))
                (ecc-test-fixture-lines name))))

(defun shot-play (session fixture &optional from to)
  "Dispatch the messages of FIXTURE into SESSION and draw the result.
FROM and TO, 1-based and inclusive, narrow it to part of the recording."
  (let ((messages (shot-fixture fixture)))
    (dolist (message (seq-subseq messages (1- (or from 1)) (or to (length messages))))
      (ecc-dispatch session message)))
  (ecc-render-flush session))

(defun shot-allow (session)
  "Answer the permission SESSION is waiting on, and change the file for real."
  (dolist (request (copy-sequence (ecc-session-pending session)))
    (ecc-perm-allow-request request))
  (with-temp-file shot-file (insert shot-after))
  (ecc-render-flush session))

(defun shot-prepare ()
  "Create the demo project and the two sessions, and replay into them."
  (make-directory shot-root t)
  (with-temp-file shot-file (insert shot-before))
  (setq ecc--sessions (make-hash-table :test #'equal)
        ecc--session-order nil)
  (advice-add 'ecc-proc-send-json :override (lambda (&rest _) nil))
  (setq shot-main (ecc-model-create-session :name "greet"
                                            :project-root shot-root))
  (setq shot-other (ecc-model-create-session :name "notes"
                                             :project-root shot-root))
  (ecc-session-ensure-buffer shot-main)
  (ecc-session-ensure-buffer shot-other)
  ;; The recording ends with a permission nobody answered, which the
  ;; renderer rightly draws as denied.  Answering it where it was asked
  ;; leaves the transcript the way a session that went well looks: the
  ;; diff allowed, the result, the summary.
  (shot-play shot-main "edit-tool" 1 11)
  (shot-allow shot-main)
  (shot-play shot-main "edit-tool" 12)
  (shot-play shot-other "basic-turn"))

(defun shot-show (session)
  "Show the source on the left and SESSION on the right, scrolled to the end.
The session buffer is narrower than the frame, so a frame wide enough
for the menu would otherwise be half empty; and the source beside it is
what a session is actually looked at next to."
  ;; A scene before this one may have left the side windows ecc puts a
  ;; dashboard or a diff in, and a side window refuses to become the
  ;; only window unless its parameters are ignored.
  (let ((ignore-window-parameters t))
    (delete-other-windows))
  (find-file shot-file)
  (split-window-right 40)
  (other-window 1)
  (switch-to-buffer (ecc-session-buffer session))
  (ecc-chat--set-margins (selected-window))
  (goto-char (point-max))
  (recenter -1)
  (redisplay t))

;;;; The invented recordings of the resume picker

(defconst shot-elsewhere-id "8f2c1a64-elsewhere"
  "The recording the picker should mark as running in another process.")

(defun shot-fake-recordings (&rest _)
  "Return invented recordings, so that no real conversation is pictured."
  (list `((session-id . ,shot-elsewhere-id)
          (title . "parser: accept a trailing comma")
          (time . ,(time-subtract (current-time) (* 26 60)))
          (prompt . "The CSV reader chokes on a trailing comma -- fix it"))
        `((session-id . "3b7d90e2-recorded")
          (title . "docs: write the install page")
          (time . ,(time-subtract (current-time) (* 5 3600)))
          (prompt . "Draft the installation page from the README"))
        `((session-id . "c04e5517-recorded")
          (title . "flaky test in test_queue.py")
          (time . ,(time-subtract (current-time) (* 3 86400)))
          (prompt . "test_queue.py fails about one run in ten"))))

(defun shot-fake-registry (session-id)
  "Say that only `shot-elsewhere-id' is running in another process."
  (and (equal session-id shot-elsewhere-id)
       '((pid . 4271) (sessionId . "8f2c1a64-elsewhere"))))

;;;; The scenes the wrapper calls

(defun shot-scene-switch-start ()
  "The frame showing the first session, before anything is switched."
  (shot-show shot-main))

(defun shot-later (function)
  "Run FUNCTION once this server request has been answered.
A command that reads from the minibuffer enters a recursive edit, and
one entered while a server request is still being served never lets
that request answer -- `emacsclient' then waits for ever.  The delay is
what keeps the two apart."
  (run-at-time 0.5 nil function))

(defun shot-scene-switch-pick ()
  "Open the picker of `ecc-switch-session' and leave it on screen."
  (shot-later (lambda () (call-interactively #'ecc-switch-session))))

(defun shot-keys (keys)
  "Feed KEYS, a `kbd' string, to whatever is reading input.
The wrapper drives this Emacs through the server, and a server request
is served from inside whatever read loop is running -- a minibuffer, a
transient.  `execute-kbd-macro' there quits; leaving the events on
`unread-command-events' lets that read loop pick them up itself."
  (setq unread-command-events
        (append (listify-key-sequence (kbd keys)) unread-command-events)))

(defun shot-scene-type (text)
  "Type TEXT into whatever is reading from the minibuffer."
  (shot-keys (mapconcat #'string text " ")))

(defun shot-scene-return ()
  "Answer the minibuffer with what is typed."
  (shot-keys "RET"))

(defun shot-scene-menu ()
  "Open `ecc-menu' over the session."
  (shot-show shot-main)
  (shot-later (lambda () (call-interactively #'ecc-menu))))

(defun shot-scene-menu-quit ()
  "Close the menu again."
  (shot-keys "C-g"))

(defun shot-scene-resume ()
  "Open the session picker of `ecc-resume', over invented recordings."
  (shot-show shot-main)
  (advice-add 'ecc-history-recordings :override #'shot-fake-recordings)
  (advice-add 'ecc-registry-session :override #'shot-fake-registry)
  ;; A session with a live process is drawn as running; one without, as a
  ;; session this Emacs holds that has stopped.  `sleep' is only there to
  ;; be alive.
  (setf (ecc-session-process shot-main) (start-process "shot-alive" nil "sleep" "600"))
  ;; Both sessions answered a moment ago, which makes every line of the
  ;; picker say "just now"; spreading them out shows the column doing
  ;; its work.
  (setf (ecc-session-last-result-time shot-main) (current-time))
  (setf (ecc-session-last-result-time shot-other)
        (time-subtract (current-time) (* 12 60)))
  (shot-later
   (lambda ()
     ;; `ecc-read-session' takes the session of the current buffer when
     ;; there is one, which is the whole point everywhere but here.
     (let ((ecc-render--session nil))
       (with-temp-buffer (ecc-read-session "Resume: "))))))

(defun shot-place-frame-bottom-right ()
  "Put the frame in the bottom right corner of its monitor.
The capture is a region of the screen, so the frame has to stand
somewhere nothing else will be doing anything -- the rest of the screen
belongs to whoever is running this.  The bottom margin is generous
because the frame grows downwards when the minibuffer does, and a frame
that would grow past the screen is moved instead -- which would shift
it out from under the rectangle being captured."
  (let* ((area (frame-monitor-workarea))
         (margin-x 24)
         (margin-y 260)
         (x (max (nth 0 area)
                 (- (+ (nth 0 area) (nth 2 area)) (frame-pixel-width) margin-x)))
         (y (max (nth 1 area)
                 (- (+ (nth 1 area) (nth 3 area)) (frame-pixel-height) margin-y))))
    (set-frame-position (selected-frame) x y)))

(defun shot-report-geometry ()
  "Write where the frame is now, for the wrapper to capture.
Opening the menu, or a minibuffer with a list under it, resizes the
frame and can move it, so the rectangle is asked for again before every
picture rather than once at the start."
  (redisplay t)
  ;; `frame-position' is the outer window, title bar included, while
  ;; `frame-pixel-height' is only the text area -- capturing that
  ;; rectangle loses the last line of the frame to the height of the
  ;; title bar.  `frame-geometry' reports the outer window as one thing.
  (let* ((geometry (frame-geometry))
         (position (alist-get 'outer-position geometry))
         (size (alist-get 'outer-size geometry))
         ;; The title bar is left out of the picture.  macOS writes the
         ;; new size into it whenever the frame is resized -- opening
         ;; the menu resizes it -- and nothing in Emacs clears that
         ;; again, so a picture that includes it says "(144 x 38)".
         (title-bar (or (cdr (alist-get 'title-bar-size geometry)) 0)))
    (with-temp-file shot-geometry-file
      (insert (format "%d %d %d %d %d %d"
                      (or (car position) (car (frame-position)))
                      (+ (or (cdr position) (cdr (frame-position))) title-bar)
                      (or (car size) (frame-pixel-width))
                      (- (or (cdr size) (frame-pixel-height)) title-bar)
                      (frame-width) (frame-height))
              "\n"))))

(defun shot-setup-frame ()
  "Size and dress the frame, then write its geometry out for capture."
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (set-fringe-mode 8)
  (blink-cursor-mode -1)
  (set-frame-font "Menlo 13" nil t)
  ;; Tall enough for `ecc-menu', which is two rows of columns and the
  ;; longest of them has ten lines.
  (set-frame-size (selected-frame) 112 44)
  (redisplay t)
  (shot-place-frame-bottom-right)
  (raise-frame)
  (x-focus-frame nil)
  ;; The candidates are worth seeing as a list.
  (cond
   ((featurep 'vertico)
    (setq vertico-count 8)
    (vertico-mode 1)
    (when (featurep 'vertico-posframe)
      (setq vertico-posframe-border-width 5
            vertico-posframe-parameters '((left-fringe . 8) (right-fringe . 8)))
      (set-face-background 'vertico-posframe-border "#323445" nil)
      (vertico-posframe-mode 1)))
   (t
    (fido-vertical-mode 1)
    (setq icomplete-prospects-height 8)))
  (shot-prepare)
  (shot-show shot-main)
  (setq server-name "ecc-docshot")
  (server-start)
  (shot-report-geometry))

(add-hook 'window-setup-hook
          (lambda ()
            (run-at-time
             1.5 nil
             (lambda ()
               (condition-case err (shot-setup-frame)
                 (error (with-temp-file shot-error-file
                          (insert (format "%S" err)))))))))

;;; docshots.el ends here
