;;; ecc-window.el --- Where the session buffers are shown  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.13 of IMPLEMENTATION_PLAN.md.  Phase 1 only needs to put a
;; transcript in a side window with its prompt buffer underneath; the
;; rest of FR-WIN comes in phase 6.

;;; Code:

(require 'ecc-core)
(require 'ecc-model)

(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-prompt-ensure-buffer "ecc-prompt" (session))

(defcustom ecc-window-use-side-window t
  "Non-nil shows a transcript in a side window rather than an ordinary one."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-window-side 'right
  "Side of the frame the transcript window is put on."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'ecc)

(defcustom ecc-window-width 0.4
  "Width of the transcript side window, as a fraction or a column count."
  :type 'number
  :group 'ecc)

(defcustom ecc-prompt-window-height 6
  "Height in lines of the prompt window under a transcript."
  :type 'integer
  :group 'ecc)

(defun ecc-display-session (session)
  "Show the transcript of SESSION and return its window."
  (require 'ecc-session)
  (let ((buffer (ecc-session-ensure-buffer session)))
    (if ecc-window-use-side-window
        (display-buffer-in-side-window
         buffer `((side . ,ecc-window-side)
                  (window-width . ,ecc-window-width)
                  (slot . 0)))
      (display-buffer buffer))))

(defun ecc-display-prompt (session)
  "Show the prompt buffer of SESSION next to its transcript and select it.
Side windows cannot be split, so the prompt takes the next slot on the
same side of the frame."
  (require 'ecc-prompt)
  (ecc-display-session session)
  (let* ((buffer (ecc-prompt-ensure-buffer session))
         (window (if ecc-window-use-side-window
                     (display-buffer-in-side-window
                      buffer `((side . ,ecc-window-side)
                               (slot . 1)
                               (window-width . ,ecc-window-width)
                               (window-height . ,ecc-prompt-window-height)))
                   (display-buffer buffer))))
    (when (window-live-p window)
      (select-window window))
    window))

(provide 'ecc-window)

;;; ecc-window.el ends here
