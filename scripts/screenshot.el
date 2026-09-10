;;; screenshot.el --- Build the demo of docs/images/session.gif  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives a throwaway GUI Emacs through a short ecc session, so that
;; scripts/screenshot.sh can capture the frames of the documentation GIF
;; and its still.
;;
;; No CLI and no network are involved.  A recorded fixture is replayed
;; through the real dispatch and the real renderer, a step at a time, and
;; the file it edits really exists and really changes -- so the source
;; buffer on the left updates the way it does in use.  That makes the
;; demo reproducible and free.
;;
;; Two liberties are taken with the recording, both only so that the
;; picture shows the interface rather than the machine that recorded it:
;; the sandbox paths are rewritten to the demo project, and one recorded
;; sentence is left out because it answers an instruction this demo's
;; prompt does not give.
;;
;; Run it through scripts/screenshot.sh rather than by hand.

;;; Code:

;; `open' on macOS goes through LaunchServices, which does not pass the
;; shell environment on, so the wrapper hands these in with --eval.
(defvar shot-geometry-file "/tmp/ecc-shot-geom.txt"
  "Where the frame geometry is written for screencapture to read.")

(defvar shot-error-file "/tmp/ecc-shot-error.txt"
  "Where a failure during setup is written.")

(setq package-user-dir (expand-file-name "~/.emacs.d/elpa"))
(package-initialize)
(add-to-list 'load-path default-directory)
(add-to-list 'load-path (expand-file-name "test" default-directory))
(require 'ecc)
(require 'ecc-test-helpers)
(require 'server)

(load-theme 'modus-vivendi t)

(setq ecc-render-debounce 0
      ecc-visual-enable-icons t
      ecc-visual-enable-spinner nil
      ecc-chat-text-width 64
      inhibit-startup-screen t)

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

(defvar shot-session nil)
(defvar shot-lines nil "The fixture, cleaned, as parsed messages.")

(defun shot-prepare ()
  "Create the demo project and the session, and load the fixture."
  (make-directory shot-root t)
  (with-temp-file shot-file (insert shot-before))
  (setq ecc--sessions (make-hash-table :test #'equal)
        ecc--session-order nil)
  (setq shot-session (ecc-model-create-session :name "greet"
                                               :project-root shot-root))
  (advice-add 'ecc-proc-send-json :override (lambda (&rest _) nil))
  (ecc-session-ensure-buffer shot-session)
  (setq shot-lines
        (delq nil
              (mapcar
               (lambda (line)
                 (let ((clean (replace-regexp-in-string
                               "\\\\?/private/tmp/claude-[0-9]+/[^\"\\\\ ]*?/sandbox"
                               shot-root line t t)))
                   ;; The recording answers "read the file first, despite
                   ;; your instruction"; this demo never gives that
                   ;; instruction, so the sentence would not make sense.
                   (unless (string-match-p "despite your instruction" clean)
                     (ecc-protocol-parse-line clean))))
               (ecc-test-fixture-lines "edit-tool")))))

(defun shot-feed (from to)
  "Dispatch the fixture messages numbered FROM to TO, inclusive, 1-based."
  (dolist (message (seq-subseq shot-lines (1- from) to))
    (ecc-dispatch shot-session message))
  (ecc-render-flush shot-session)
  (shot-follow))

(defun shot-follow ()
  "Keep the end of the transcript in view."
  (when-let* ((window (get-buffer-window (ecc-session-buffer shot-session))))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1)))
  (redisplay t))

;;;; The steps the wrapper calls, in order

(defun shot-step-idle ()
  "Open the source on the left and the session on the right."
  (delete-other-windows)
  (find-file shot-file)
  (split-window-right 40)
  (other-window 1)
  (switch-to-buffer (ecc-session-buffer shot-session))
  (ecc-chat--set-margins (selected-window))
  (redisplay t))

(defun shot-step-type (text)
  "Type TEXT into the prompt region, as a person would."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-session))
    ;; `point-max' is the end of the footer, which is read-only; the
    ;; editable region is the prompt, and it ends where the rule begins.
    (ecc-chat-goto-prompt)
    (goto-char (ecc-chat-prompt-end))
    (insert text)
    (redisplay t)))

(defun shot-step-send ()
  "Send what is in the prompt region and start the turn."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-session))
    (let ((prompt (string-trim (buffer-substring-no-properties
                                (ecc-chat-prompt-start) (ecc-chat-prompt-end)))))
      (delete-region (ecc-chat-prompt-start) (ecc-chat-prompt-end))
      (ecc-model-begin-turn shot-session prompt)))
  (ecc-render-flush shot-session)
  (shot-follow))

(defun shot-step-allow ()
  "Answer the waiting permission, and let the file really change."
  (dolist (request (copy-sequence (ecc-session-pending shot-session)))
    (ecc-perm-allow-request request))
  (with-temp-file shot-file (insert shot-after))
  (ecc-render-flush shot-session)
  (shot-follow))

(defun shot-step-reread ()
  "Show the source buffer picking the change up."
  (with-current-buffer (find-file-noselect shot-file)
    (revert-buffer t t t))
  (redisplay t))

(defun shot-setup-frame ()
  "Size and dress the frame, then write its geometry out for capture.
On macOS the GUI frame is only created at the very end of startup, so
none of this can run while the file loads."
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (set-fringe-mode 8)
  (blink-cursor-mode -1)
  (set-frame-font "Menlo 13" nil t)
  (set-frame-size (selected-frame) 104 26)
  (set-frame-position (selected-frame) 220 140)
  (raise-frame)
  (x-focus-frame nil)
  (shot-prepare)
  (shot-step-idle)
  (setq server-name "ecc-shot")
  (server-start)
  (redisplay t)
  (with-temp-file shot-geometry-file
    (insert (format "%d %d %d %d %d %d"
                    (car (frame-position)) (cdr (frame-position))
                    (frame-pixel-width) (frame-pixel-height)
                    (frame-width) (frame-height))
            "\n")))

(add-hook 'window-setup-hook
          (lambda ()
            (run-at-time
             1.5 nil
             (lambda ()
               (condition-case err (shot-setup-frame)
                 (error (with-temp-file shot-error-file
                          (insert (format "%S" err)))))))))

;;; screenshot.el ends here
