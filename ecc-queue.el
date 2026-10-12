;;; ecc-queue.el --- The prompts waiting for the turn to end  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Maintainer: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; URL: https://github.com/wakamenod/emacs-claude-code
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A prompt sent while a turn runs waits in the queue of its session
;; (`ecc-model-queue-input') and goes out when the turn ends, one per
;; turn.  The queue lives in Emacs, so until then a prompt in it can
;; still be written again or dropped.  This module shows the queue in
;; two places:
;;
;; - at the end of the transcript, just above the separator, one dim
;;   line per prompt, through `ecc-render-tail-functions'.  RET or a
;;   click on one of them opens the list below;
;; - in a buffer of its own per session, `ecc-queue-show', where a
;;   prompt is taken back into the prompt region, dropped, or moved.
;;
;; Both follow the queue as it changes (`ecc-input-queue-changed-hook'),
;; and the list knows a prompt by its identity: a prompt that was sent
;; while the list was open is said to be gone, and nothing else is
;; acted on in its place.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-window)

;;;; What an entry says

(defun ecc-queue-draft (entry)
  "Return what taking ENTRY back puts in the prompt region, or nil.
What the user typed when there is that; otherwise the text that would
be sent, when it is a string.  Content blocks have no text to write
again."
  (or (ecc-queued-draft entry)
      (and (stringp (ecc-queued-text entry)) (ecc-queued-text entry))))

(defun ecc-queue-label (entry)
  "Return the one line ENTRY is listed by."
  (ecc--flatten (or (ecc-queue-draft entry) "(content blocks)")))

;;;; At the end of the transcript

(defvar ecc-queue-tail-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-transcript-map)
    (define-key map (kbd "RET") #'ecc-queue-show-at-point)
    (define-key map [mouse-2] #'ecc-queue-show-at-click)
    map)
  "Keymap of the queued prompts drawn at the end of a transcript.
A click reaches \\=`mouse-2' through the `follow-link' of the transcript,
which follows anything drawn with a `mouse-face'.")

(defun ecc-queue--tail-width (session)
  "Return the columns a line at the end of the transcript of SESSION may take."
  (if-let* ((window (get-buffer-window (ecc-session-buffer session) t)))
      (max 20 (1- (window-body-width window)))
    79))

(defun ecc-queue--tail-line (prefix text entry width)
  "Return PREFIX and TEXT cut to WIDTH as a line that opens the queue on ENTRY."
  (propertize (concat prefix (ecc--fit text (max 1 (- width (string-width prefix)))))
              'face 'ecc-dim-face
              'mouse-face 'highlight
              'help-echo "RET, mouse-1: list the queue to take a prompt back or drop it"
              'keymap ecc-queue-tail-map
              'ecc-queued entry))

(defun ecc-queue-tail (session)
  "Return the lines the queue of SESSION adds above the separator, or nil."
  (when-let* ((queue (ecc-session-input-queue session)))
    (let ((width (ecc-queue--tail-width session))
          (position 0))
      (mapconcat
       #'identity
       (cons (ecc-queue--tail-line "" (format "⏸ Queued (%d)" (length queue))
                                   nil width)
             (mapcar (lambda (entry)
                       (ecc-queue--tail-line (format "  %d. " (cl-incf position))
                                             (ecc-queue-label entry) entry width))
                     queue))
       "\n"))))

;; Last of the tail, so that the queue is what sits on the separator,
;; right above the prompt the next one will be written in.
(add-hook 'ecc-render-tail-functions #'ecc-queue-tail 90)

(defun ecc-queue-show-at-point ()
  "List the queue of this session, on the prompt at point."
  (interactive)
  (ecc-queue-show (ecc-window-buffer-session)
                  (get-text-property (point) 'ecc-queued)))

(defun ecc-queue-show-at-click (event)
  "List the queue of this session, on the prompt clicked on in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (ecc-queue-show-at-point))

;;;; The list

(defvar-local ecc-queue--session nil
  "The session whose queue this buffer lists.")

(defun ecc-queue-buffer-name (session)
  "Return the name of the buffer listing the queue of SESSION."
  (format "*ecc-queue: %s*" (ecc-session-name session)))

(defun ecc-queue--buffers (session)
  "Return the live buffers listing the queue of SESSION."
  (seq-filter (lambda (buffer)
                (eq (buffer-local-value 'ecc-queue--session buffer) session))
              (buffer-list)))

(defun ecc-queue-buffer (session)
  "Return the buffer listing the queue of SESSION, making it once."
  (or (car (ecc-queue--buffers session))
      (with-current-buffer (generate-new-buffer (ecc-queue-buffer-name session))
        (ecc-queue-mode)
        (setq ecc-queue--session session)
        (current-buffer))))

(defvar ecc-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-queue-take-back)
    (define-key map (kbd "d") #'ecc-queue-drop)
    (define-key map (kbd "k") #'ecc-queue-drop)
    (define-key map (kbd "M-<up>") #'ecc-queue-move-up)
    (define-key map (kbd "M-<down>") #'ecc-queue-move-down)
    (define-key map (kbd "g") #'ecc-queue-refresh)
    map)
  "Keymap of `ecc-queue-mode'.")

(define-derived-mode ecc-queue-mode special-mode "Claude-Queue"
  "Major mode listing the prompts a session has waiting.

\\{ecc-queue-mode-map}"
  :interactive nil
  (setq-local truncate-lines t))

(defun ecc-queue--draw ()
  "Draw the queue of this buffer's session."
  (let ((inhibit-read-only t)
        (session ecc-queue--session)
        (position 0))
    (erase-buffer)
    (insert (propertize (format "Queue of %s\n" (ecc-session-name session))
                        'face 'ecc-heading-face)
            (propertize
             (concat (mapconcat (lambda (pair) (format "%s %s" (car pair) (cdr pair)))
                                '(("RET" . "take back") ("d" . "drop")
                                  ("M-<up>/M-<down>" . "move")
                                  ("g" . "refresh") ("q" . "quit"))
                                "   ")
                     "\n")
             'face 'ecc-dim-face)
            "\n")
    (if (null (ecc-session-input-queue session))
        (insert (propertize "The queue is empty.\n" 'face 'ecc-dim-face))
      (dolist (entry (ecc-session-input-queue session))
        ;; The whole line carries the entry, its newline included: the
        ;; keys are answers to the line point is on.
        (insert (propertize
                 (concat (format "%2d. " (cl-incf position))
                         (ecc-queue-label entry)
                         (unless (ecc-queued-draft entry)
                           (propertize "  (queued by Emacs)" 'face 'ecc-dim-face))
                         "\n")
                 'ecc-queued entry))))))

(defun ecc-queue--entry-positions ()
  "Return the start of each line of this buffer that lists an entry, in order."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (get-text-property (point) 'ecc-queued)
          (push (point) positions))
        (forward-line 1)))
    (nreverse positions)))

(defun ecc-queue--place (position)
  "Return where POSITION is, as the entry there and its index, or nil."
  (when-let* ((entry (get-text-property position 'ecc-queued)))
    (cons entry (seq-position (ecc-queue--entry-positions)
                              (save-excursion (goto-char position)
                                              (line-beginning-position))))))

(defun ecc-queue--position (place)
  "Return the position PLACE stands for after a redraw.
The line of its entry when the entry is still there; otherwise the
line that took its index, or the last one; otherwise the first entry,
or the end of the heading."
  (let ((positions (ecc-queue--entry-positions)))
    (or (and (car place)
             (seq-find (lambda (position)
                         (eq (get-text-property position 'ecc-queued) (car place)))
                       positions))
        (and (cdr place) positions
             (nth (min (cdr place) (1- (length positions))) positions))
        (car positions)
        (save-excursion (goto-char (point-min)) (forward-line 3) (point)))))

(defun ecc-queue--redraw (buffer &optional entry)
  "Draw BUFFER again, keeping each window on the entry it was on.
With ENTRY, the point goes to that entry instead."
  (with-current-buffer buffer
    (let ((places (mapcar (lambda (window)
                            (cons window (ecc-queue--place (window-point window))))
                          (get-buffer-window-list buffer nil t)))
          (here (if entry (cons entry nil) (ecc-queue--place (point)))))
      (ecc-queue--draw)
      (goto-char (ecc-queue--position here))
      (dolist (place places)
        (set-window-point (car place)
                          (if entry (point) (ecc-queue--position (cdr place))))))))

(defun ecc-queue--on-change (session)
  "Draw again every list of the queue of SESSION."
  (dolist (buffer (ecc-queue--buffers session))
    (ecc-queue--redraw buffer)))

(add-hook 'ecc-input-queue-changed-hook #'ecc-queue--on-change)

;;;###autoload
(defun ecc-queue-show (&optional session entry)
  "List the prompts SESSION has waiting for the turn to end.
In the list a prompt can be taken back into the prompt region to be
written again, dropped, or moved; the list follows the queue as it
drains.  ENTRY, when given, is the prompt the point starts on.  With an
empty queue nothing is opened and a message says so, unless the list
is on the screen already."
  (interactive (list (ecc-window-resolve-session current-prefix-arg)))
  (let ((session (or session (ecc-window-resolve-session)
                     (user-error "No session here"))))
    (if (and (null (ecc-session-input-queue session))
             (not (seq-some #'get-buffer-window (ecc-queue--buffers session))))
        (progn (message "The queue of %s is empty" (ecc-session-name session))
               nil)
      (let ((buffer (ecc-queue-buffer session)))
        (ecc-queue--redraw buffer entry)
        ;; A window that showed the list before may bring back the point
        ;; it had then; the one just drawn is the one meant.
        (let ((window (ecc-window-display-beside-session buffer session)))
          (when (window-live-p window)
            (set-window-point window (with-current-buffer buffer (point)))))
        buffer))))

(define-obsolete-function-alias 'ecc-prompt-show-queue #'ecc-queue-show "0.4.2")

(defun ecc-queue-refresh ()
  "Draw the list of the queue again."
  (interactive)
  (ecc-queue--redraw (current-buffer)))

(defun ecc-queue--entry-at-point ()
  "Return the queued prompt on the line of point.
Signal when there is none, and when it has left the queue since the
list was drawn: the list is drawn again then, and nothing is done to
another prompt in its place."
  (let ((entry (or (get-text-property (line-beginning-position) 'ecc-queued)
                   (user-error "Not on a queued prompt"))))
    (unless (memq entry (ecc-session-input-queue ecc-queue--session))
      (ecc-queue--redraw (current-buffer))
      (user-error "That prompt has been sent already"))
    entry))

(defun ecc-queue-drop ()
  "Drop the prompt at point from the queue.
Nothing asks first: what was dropped can be typed again."
  (interactive)
  (let ((entry (ecc-queue--entry-at-point)))
    (ecc-model-take-input ecc-queue--session entry)
    (message "Dropped: %s" (ecc--truncate (ecc-queue-label entry) 40))))

(defun ecc-queue--put-in-prompt (buffer text)
  "Put TEXT at the head of the prompt region of BUFFER and return its end.
A draft already there stays, after a blank line: nothing written is lost."
  (with-current-buffer buffer
    (if (string-blank-p (ecc-chat-draft))
        (progn (ecc-chat-set-draft text) (point))
      (goto-char (ecc-chat-prompt-start))
      (insert text "\n\n")
      (- (point) 2))))

(defun ecc-queue-take-back ()
  "Take the prompt at point out of the queue and into the prompt region.
What comes back is the draft as it was typed, and it is prepared afresh
when it is sent again: its slash command, its @ references and the
editor context are worked out then, not as they were when it was
queued.  A pasted image is an @ reference to the file it was saved
to, so it comes back with the rest.  A draft already in the prompt
region stays, after the one taken back."
  (interactive)
  (let* ((session ecc-queue--session)
         (entry (ecc-queue--entry-at-point))
         (text (or (ecc-queue-draft entry)
                   (user-error "This prompt is content blocks Emacs put together, \
with no text to write again; d drops it")))
         (buffer (ecc-session-buffer session)))
    (unless (and (buffer-live-p buffer) (with-current-buffer buffer
                                          (ecc-chat-prompt-start)))
      (user-error "%s has no prompt region to take it back into"
                  (ecc-session-name session)))
    (ecc-model-take-input session entry)
    (let ((end (ecc-queue--put-in-prompt buffer text))
          (window (or (get-buffer-window buffer)
                      (ecc-window-display-beside-session buffer session))))
      (when (window-live-p window)
        (select-window window)
        (set-window-point window end))
      (with-current-buffer buffer (goto-char end)))
    (message "Taken back from the queue; it is prepared again when it is sent")))

(defun ecc-queue--move (offset)
  "Move the prompt at point OFFSET places towards the tail of the queue."
  (ecc-model-move-input ecc-queue--session (ecc-queue--entry-at-point) offset))

(defun ecc-queue-move-up ()
  "Move the prompt at point one place nearer to being sent."
  (interactive)
  (ecc-queue--move -1))

(defun ecc-queue-move-down ()
  "Move the prompt at point one place further from being sent."
  (interactive)
  (ecc-queue--move 1))

(provide 'ecc-queue)

;;; ecc-queue.el ends here
