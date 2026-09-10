;;; screenshot.el --- Build the buffer of docs/images/session.png  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds a representative ecc session buffer for the documentation
;; screenshot.  No CLI and no network are involved: two recorded fixtures
;; are replayed through the real dispatch and the real renderer, so the
;; picture is reproducible and costs nothing.
;;
;; Only the sandbox paths inside the recordings are rewritten, so that the
;; picture shows the interface rather than the temp directory of whichever
;; machine recorded the fixture.
;;
;; Driven by scripts/screenshot.sh, which captures the frame this leaves
;; on screen.  Run it that way rather than by hand.

;;; Code:

;; `open' on macOS goes through LaunchServices, which does not pass the
;; shell environment on, so the wrapper hands these in with --eval rather
;; than as environment variables.
(defvar shot-geometry-file "/tmp/ecc-shot-geom.txt"
  "Where the frame geometry is written for screencapture to read.")

(defvar shot-error-file "/tmp/ecc-shot-error.txt"
  "Where a failure during frame setup is written.")

(setq package-user-dir (expand-file-name "~/.emacs.d/elpa"))
(package-initialize)
(add-to-list 'load-path default-directory)
(add-to-list 'load-path (expand-file-name "test" default-directory))
(require 'ecc)
(require 'ecc-test-helpers)

(load-theme 'modus-vivendi t)

(setq ecc-render-debounce 0
      ecc-visual-enable-icons t
      ecc-visual-enable-spinner nil
      ecc-chat-text-width 92)

(setq ecc--sessions (make-hash-table :test #'equal)
      ecc--session-order nil)

(defconst shot-root "/Users/you/src/greet")

(defvar shot-session
  (ecc-model-create-session :name "greet" :project-root shot-root))

(advice-add 'ecc-proc-send-json :override (lambda (&rest _) nil))
(advice-add 'ecc-diff-file-content :override (lambda (&rest _) nil))

(defun shot-dispatch (name prompt)
  "Replay fixture NAME under PROMPT, with the sandbox paths shortened."
  (ecc-model-begin-turn shot-session prompt)
  (dolist (line (ecc-test-fixture-lines name))
    (let ((clean (replace-regexp-in-string
                  "\\\\?/private/tmp/claude-[0-9]+/[^\"\\\\ ]*?/sandbox"
                  shot-root line t t)))
      (ecc-dispatch shot-session (ecc-protocol-parse-line clean))
      ;; The recordings carry the CLI's permission requests but not the
      ;; answers.  Answer each one as it arrives, the way a person at the
      ;; keyboard would; left alone it is abandoned when the turn ends and
      ;; the transcript draws a denial that never happened.
      (dolist (request (copy-sequence (ecc-session-pending shot-session)))
        (ecc-perm-allow-request request))))
  (ecc-render-flush shot-session))

(ecc-session-ensure-buffer shot-session)
(shot-dispatch "tasks" "テストを書いて、ドキュメントも直して")
(shot-dispatch "edit-tool" "greet が Hi を返すようにして")

(switch-to-buffer (ecc-session-buffer shot-session))
(delete-other-windows)
(goto-char (point-max))


(defun shot-setup-frame ()
  "Size and dress the frame, then write its geometry out for capture.
On macOS the GUI frame is only created at the very end of startup, so
none of this can run while the file loads."

  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (set-fringe-mode 8)
  (blink-cursor-mode -1)
  (setq-default cursor-type 'box)
  (set-frame-font "Menlo 13" nil t)
  (set-frame-size (selected-frame) 100 42)
  (set-frame-position (selected-frame) 220 140)
  (raise-frame)
  (x-focus-frame nil)
  (switch-to-buffer (ecc-session-buffer shot-session))
  (delete-other-windows)
  ;; The margin that holds the text to `ecc-chat-text-width' was computed
  ;; against the startup frame; recompute it now that the frame is sized.
  (ecc-chat--set-margins (selected-window))
  (goto-char (point-max))
  (recenter -1)
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
