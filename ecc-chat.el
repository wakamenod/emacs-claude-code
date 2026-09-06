;;; ecc-chat.el --- The one buffer a session is read and written in  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; `ecc-chat-mode' is the major mode of a session buffer: the transcript
;; `ecc-render' draws, and under it, after a separator, the prompt region
;; the user types in (docs/phase9-ui-redesign.md, section 4).
;;
;; The two parts answer to different keys.  The transcript is read-only
;; text carrying `ecc-chat-transcript-map' as its `keymap' property, so
;; that one letter commands (n, p, a, d, TAB...) work there and nowhere
;; else; the prompt region has no such property, so the keymap of the
;; major mode applies, and that one only binds RET, TAB and C-c keys.
;; Sending is C-c C-c, or RET when `ecc-chat-return-sends' is on.
;;
;; Folding and movement work on the headings the renderer marked (the
;; `ecc-heading', `ecc-node' and `ecc-depth' text properties) and on the
;; node table it keeps; the commands here are the keys of magit-section
;; the transcript used to have, written for that structure (FR-OUT-3,
;; FR-OUT-14).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)

;; The commands bound below live in the modules above this one.
(declare-function ecc-prompt-send "ecc-prompt" ())
(declare-function ecc-prompt-clear "ecc-prompt" ())
(declare-function ecc-prompt-show-queue "ecc-prompt" ())
(declare-function ecc-prompt-resend-last "ecc-prompt" (&optional session))
(declare-function ecc-prompt-toggle-context "ecc-prompt" ())
(declare-function ecc-prompt-insert-image "ecc-prompt" (file))
(declare-function ecc-prompt-history-previous "ecc-prompt" ())
(declare-function ecc-prompt-history-next "ecc-prompt" ())
(declare-function ecc-prompt-capf "ecc-prompt" ())
(declare-function ecc-prompt-at-capf "ecc-prompt" ())
(declare-function ecc-prompt-yank-image "ecc-prompt" (mime data))
(declare-function ecc-prompt-dnd-insert "ecc-prompt" (url &optional action))
(declare-function ecc-session-visit "ecc-session" ())
(declare-function ecc-session-refresh "ecc-session" ())
(declare-function ecc-session-show-log "ecc-session" ())
(declare-function ecc-session-resume "ecc-session" ())
(declare-function ecc-session-interrupt "ecc-session" ())
(declare-function ecc-session-review "ecc-session" ())
(declare-function ecc-session-review-file "ecc-session" ())
(declare-function ecc-session-review-or-deny "ecc-session" ())
(declare-function ecc-session-allow-all-remember "ecc-session" ())
(declare-function ecc-session-timeline "ecc-session" ())
(declare-function ecc-session-copy-at-point "ecc-session" ())
(declare-function ecc-session-export-markdown "ecc-session" (file))
(declare-function ecc-perm-allow "ecc-perm" ())
(declare-function ecc-perm-deny "ecc-perm" (&optional reason))
(declare-function ecc-perm-allow-always "ecc-perm" ())
(declare-function ecc-perm-approve-turn "ecc-perm" ())
(declare-function ecc-perm-add-pattern "ecc-perm" ())
(declare-function ecc-perm-allow-all "ecc-perm" (&optional remember))
(declare-function ecc-review-comment-request "ecc-review" (text))
(declare-function ecc-review-edit-proposal "ecc-review" (&optional request))
(declare-function ecc-inbox "ecc-inbox" ())
(declare-function ecc-next-attention "ecc-inbox" ())
(declare-function ecc-dashboard "ecc-dashboard" ())
(declare-function ecc-menu "ecc-transient" ())
(declare-function ecc-tui-open "ecc-tui" (&optional session))
(declare-function ecc-hint-accept-suggestion "ecc-hint" ())
(declare-function ecc-hint-mode-line-string "ecc-hint" (&optional session))

;;;; Options

(defcustom ecc-chat-return-sends nil
  "Non-nil makes RET send the prompt, the way the terminal client does.
Off, RET inserts a newline and \\<ecc-chat-mode-map>\\[ecc-prompt-send] sends; on,
\\[ecc-chat-newline] inserts the newline (FR-INP-1)."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-chat-placeholder "Ask Claude… (C-c ? for the menu)"
  "What an empty prompt region says, in a dim face."
  :type 'string
  :group 'ecc)

(defvar ecc-chat-placeholder-functions nil
  "Functions offering a placeholder for an empty prompt region.
Each is called with the session and returns a string or nil; the
first string wins over `ecc-chat-placeholder'.  The suggestion of
FR-HINT-4 arrives this way.")

;;;; Keymaps

(defvar ecc-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-chat-return)
    (define-key map (kbd "S-<return>") #'ecc-chat-newline)
    (define-key map (kbd "C-j") #'ecc-chat-newline)
    (define-key map (kbd "TAB") #'ecc-chat-tab)
    (define-key map (kbd "C-c C-c") #'ecc-prompt-send)
    (define-key map (kbd "C-c C-k") #'ecc-prompt-clear)
    (define-key map (kbd "C-c C-g") #'ecc-session-interrupt)
    (define-key map (kbd "C-c C-q") #'ecc-prompt-show-queue)
    (define-key map (kbd "C-c C-r") #'ecc-prompt-resend-last)
    (define-key map (kbd "C-c C-x") #'ecc-prompt-toggle-context)
    (define-key map (kbd "C-c C-i") #'ecc-prompt-insert-image)
    (define-key map (kbd "C-c C-s") #'ecc-hint-accept-suggestion)
    (define-key map (kbd "M-p") #'ecc-prompt-history-previous)
    (define-key map (kbd "M-n") #'ecc-prompt-history-next)
    (define-key map (kbd "C-<up>") #'ecc-prompt-history-previous)
    (define-key map (kbd "C-<down>") #'ecc-prompt-history-next)
    (define-key map (kbd "C-c i") #'ecc-chat-goto-prompt)
    (define-key map (kbd "C-c C-n") #'ecc-chat-next-turn)
    (define-key map (kbd "C-c C-p") #'ecc-chat-previous-turn)
    (define-key map (kbd "C-c d") #'ecc-session-review)
    (define-key map (kbd "C-c a") #'ecc-perm-allow-all)
    (define-key map (kbd "C-c A") #'ecc-session-allow-all-remember)
    (define-key map (kbd "C-c I") #'ecc-inbox)
    (define-key map (kbd "C-c D") #'ecc-dashboard)
    (define-key map (kbd "C-c n") #'ecc-next-attention)
    (define-key map (kbd "C-c C-e") #'ecc-session-export-markdown)
    ;; `?' stays self-inserting in a region one writes prose in, so the
    ;; menu is on C-c ? here and on ? in the transcript (NFR-10).
    (define-key map (kbd "C-c ?") #'ecc-menu)
    map)
  "Keymap of `ecc-chat-mode', in force in the prompt region.
Everything here is RET, TAB or a key under the mode prefix, so that a
letter is a letter.")

(defvar ecc-chat-transcript-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'ecc-chat-toggle)
    (define-key map (kbd "n") #'ecc-chat-next-heading)
    (define-key map (kbd "p") #'ecc-chat-previous-heading)
    (define-key map (kbd "M-n") #'ecc-chat-next-sibling)
    (define-key map (kbd "M-p") #'ecc-chat-previous-sibling)
    (define-key map (kbd "^") #'ecc-chat-up-heading)
    (define-key map (kbd "1") #'ecc-chat-show-level-1)
    (define-key map (kbd "2") #'ecc-chat-show-level-2)
    (define-key map (kbd "3") #'ecc-chat-show-level-3)
    (define-key map (kbd "4") #'ecc-chat-show-level-4)
    (define-key map (kbd "RET") #'ecc-session-visit)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    (define-key map (kbd "i") #'ecc-chat-goto-prompt)
    (define-key map (kbd "g") #'ecc-session-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "L") #'ecc-session-show-log)
    (define-key map (kbd "t") #'ecc-tui-open)
    (define-key map (kbd "R") #'ecc-session-resume)
    (define-key map (kbd "a") #'ecc-perm-allow)
    (define-key map (kbd "d") #'ecc-session-review-or-deny)
    (define-key map (kbd "C-c C-k") #'ecc-session-interrupt)
    ;; Movement and extraction (FR-OUT-14)
    (define-key map (kbd "]") #'ecc-chat-next-block)
    (define-key map (kbd "[") #'ecc-chat-previous-block)
    (define-key map (kbd "+") #'ecc-chat-expand-all)
    (define-key map (kbd "-") #'ecc-chat-collapse-all)
    (define-key map (kbd "T") #'ecc-session-timeline)
    (define-key map (kbd "w") #'ecc-session-copy-at-point)
    (define-key map (kbd "f") #'ecc-chat-goto-files)
    (define-key map (kbd "?") #'ecc-menu)
    map)
  "Keymap of the transcript, put on its text as the `keymap' property.
A key not here falls through to `ecc-chat-mode-map'.")

(defvar ecc-request-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-transcript-map)
    (define-key map (kbd "RET") #'ecc-session-visit)
    (define-key map (kbd "a") #'ecc-perm-allow)
    (define-key map (kbd "d") #'ecc-perm-deny)
    (define-key map (kbd "A") #'ecc-perm-allow-always)
    (define-key map (kbd "t") #'ecc-perm-approve-turn)
    (define-key map (kbd "p") #'ecc-perm-add-pattern)
    (define-key map (kbd "c") #'ecc-review-comment-request)
    (define-key map (kbd "e") #'ecc-review-edit-proposal)
    map)
  "Keymap of a node that is waiting for an answer (plan section 6.3).")

(defvar ecc-file-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-transcript-map)
    (define-key map (kbd "RET") #'ecc-session-visit)
    (define-key map (kbd "SPC") #'ecc-chat-toggle)
    (define-key map (kbd "d") #'ecc-session-review-file)
    map)
  "Keymap of a file row in the Files section.")

(defvar ecc-chat-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-transcript-map)
    (define-key map (kbd "RET") #'push-button)
    (define-key map [mouse-2] #'push-button)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap of a button in the transcript, such as the history button.")

;;;; The mode

(define-derived-mode ecc-chat-mode text-mode "Claude"
  "Major mode of a Claude Code session: its transcript and its prompt.

\\{ecc-chat-mode-map}"
  :interactive nil
  ;; Faces are applied when text is inserted, so no font lock is wanted
  ;; (plan section 9, item 7); `text-mode' turns none on.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; A folded body shows as an ellipsis after its heading (FR-OUT-3).
  (add-to-invisibility-spec '(ecc-fold . t))
  (setq-local completion-at-point-functions
              (list #'ecc-prompt-capf #'ecc-prompt-at-capf))
  ;; The state, and above all a request waiting for an answer, is shown
  ;; next to the mode name (FR-PERM-4), and after it what the session
  ;; costs and how much room is left in its context (FR-HINT-3).
  (setq-local mode-line-process
              ;; Escaped where it is put together rather than in each
              ;; piece: what the pieces return is text for a person.
              '(:eval (ecc--mode-line-escape
                       (concat (ecc-render-mode-line-process)
                               (if (fboundp 'ecc-hint-mode-line-string)
                                   (ecc-hint-mode-line-string)
                                 "")))))
  ;; An image on the clipboard is worth a file reference (FR-INP-9).
  (when (fboundp 'yank-media-handler)
    (yank-media-handler "image/.*" #'ecc-prompt-yank-image))
  (setq-local dnd-protocol-alist
              (cons '("^file:" . ecc-prompt-dnd-insert) dnd-protocol-alist))
  (add-hook 'pre-command-hook #'ecc-chat--pre-command nil t)
  (add-hook 'post-command-hook #'ecc-chat--post-command nil t)
  (add-hook 'after-change-functions #'ecc-chat--after-change nil t))

;;;; The prompt region

(defun ecc-chat-prompt-start ()
  "Return where the prompt region of this buffer starts, or nil."
  (ecc-render-prompt-start))

(defun ecc-chat-in-prompt-p (&optional position)
  "Return non-nil when POSITION, or point, is in the prompt region."
  (when-let* ((start (ecc-chat-prompt-start)))
    (>= (or position (point)) start)))

(defun ecc-chat-draft ()
  "Return what is written in the prompt region, without properties.
The placeholder is not part of it."
  (if-let* ((start (ecc-chat-prompt-start)))
      (let ((runs (ecc-chat--placeholder-runs))
            (pos start)
            (parts nil))
        (dolist (run runs)
          (push (buffer-substring-no-properties pos (car run)) parts)
          (setq pos (cdr run)))
        (push (buffer-substring-no-properties pos (point-max)) parts)
        (apply #'concat (nreverse parts)))
    ""))

(defun ecc-chat-clear-draft ()
  "Empty the prompt region."
  (when-let* ((start (ecc-chat-prompt-start)))
    (ecc-chat--remove-placeholder)
    (delete-region start (point-max))))

(defun ecc-chat-set-draft (text)
  "Replace the prompt region with TEXT and leave point at its end."
  (let ((start (or (ecc-chat-prompt-start)
                   (user-error "This buffer has no prompt region"))))
    (ecc-chat--remove-placeholder)
    (delete-region start (point-max))
    (goto-char start)
    (insert text)))

(defun ecc-chat-goto-prompt ()
  "Move point to the end of the prompt region.
With nothing written there yet, that is its start, in front of the
placeholder."
  (interactive)
  (unless (ecc-chat-prompt-start)
    (user-error "This buffer has no prompt region"))
  (goto-char (if (string-empty-p (ecc-chat-draft))
                 (ecc-chat-prompt-start)
               (point-max))))

(defun ecc-chat-return ()
  "Insert a newline, or send the prompt when `ecc-chat-return-sends' is on."
  (interactive)
  (if (and ecc-chat-return-sends (ecc-chat-in-prompt-p))
      (progn (require 'ecc-prompt) (ecc-prompt-send))
    (ecc-chat-newline)))

(defun ecc-chat-newline ()
  "Insert a newline in the prompt region."
  (interactive)
  (unless (ecc-chat-in-prompt-p)
    (user-error "The transcript is read-only; i moves to the prompt"))
  (newline))

(defun ecc-chat-tab ()
  "Complete in the prompt region, or fold in the transcript."
  (interactive)
  (if (ecc-chat-in-prompt-p)
      (progn (require 'ecc-prompt) (completion-at-point))
    (ecc-chat-toggle)))

;;;; The placeholder

;; The placeholder is real text in the prompt region, so that the cursor
;; can walk over it; it is dim, read-only, marked `ecc-placeholder', and
;; goes as soon as anything else is put in the region.  It is put in and
;; taken out silently, outside the undo history, and the positions the
;; history remembers are moved along (the way the renderer moves them
;; for the transcript above).

(defun ecc-chat-placeholder-string ()
  "Return the placeholder of this buffer, or nil when it has none."
  (let ((session ecc-render--session))
    (or (and session
             (seq-some (lambda (function) (funcall function session))
                       ecc-chat-placeholder-functions))
        ecc-chat-placeholder)))

(defun ecc-chat--placeholder-runs ()
  "Return the (START . END) runs of placeholder text in the prompt region."
  (when-let* ((start (ecc-chat-prompt-start)))
    (let ((pos start) runs)
      (while (< pos (point-max))
        (let ((next (or (next-single-property-change pos 'ecc-placeholder)
                        (point-max))))
          (when (get-text-property pos 'ecc-placeholder)
            (push (cons pos next) runs))
          (setq pos next)))
      (nreverse runs))))

(defun ecc-chat-placeholder-shown ()
  "Return the placeholder text shown in the prompt region, or nil."
  (when-let* ((runs (ecc-chat--placeholder-runs)))
    (mapconcat (lambda (run) (buffer-substring-no-properties (car run) (cdr run)))
               runs "")))

(defun ecc-chat--remove-placeholder ()
  "Take the placeholder text out of the prompt region, silently.
Returns non-nil when there was one."
  (let ((runs (ecc-chat--placeholder-runs)))
    (when runs
      ;; From the end, so that the earlier runs keep their positions.
      ;; The history is moved outside the silent block, which binds it.
      (dolist (run (reverse runs))
        (with-silent-modifications
          (delete-region (car run) (cdr run)))
        (ecc-render--shift-undo (- (car run) (cdr run)) (cdr run)))
      t)))

(defun ecc-chat--insert-placeholder (text)
  "Put TEXT at the start of the prompt region as the placeholder, silently.
Point is left where it was, in front of the text when it was there."
  (let ((start (ecc-chat-prompt-start)))
    (with-silent-modifications
      (save-excursion
        (goto-char start)
        (insert (propertize text
                            'face 'ecc-dim-face
                            'ecc-placeholder t
                            'read-only t
                            'rear-nonsticky t))))
    (ecc-render--shift-undo (length text) start)))

(defun ecc-chat-update-placeholder (&optional buffer)
  "Show the placeholder in BUFFER while its prompt region is empty.
BUFFER defaults to the current one.  Returns the text shown, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (let ((start (ecc-chat-prompt-start))
          (text (ecc-chat-placeholder-string)))
      (cond
       ((and start text (string-empty-p (ecc-chat-draft)))
        (unless (equal (ecc-chat-placeholder-shown) text)
          (ecc-chat--remove-placeholder)
          (ecc-chat--insert-placeholder text))
        text)
       (t (ecc-chat--remove-placeholder) nil)))))

(defun ecc-chat--after-change (beg _end _length)
  "Take the placeholder out as soon as the prompt region is written to.
BEG is where the change began.  The change itself is left alone: what
was typed stays, wherever in the placeholder the cursor was."
  (when (and (ecc-chat-in-prompt-p beg)
             (ecc-chat--placeholder-runs))
    (ecc-chat--remove-placeholder)))

(defun ecc-chat--pre-command ()
  "Take the placeholder out before an undo replays changes over it.
An undo group can hold several changes; once the first of them has
been replayed and the placeholder is gone, the positions of the rest
would be off by its length.  Nothing else replays old positions, so
nothing else needs this."
  (when (and (derived-mode-p 'ecc-chat-mode)
             (symbolp this-command)
             (string-match-p "undo\\|redo" (symbol-name this-command)))
    (ecc-chat--remove-placeholder)))

(defun ecc-chat--post-command ()
  "Keep the placeholder right after a command in this buffer."
  (when (derived-mode-p 'ecc-chat-mode)
    (ecc-chat-update-placeholder)))

(defun ecc-chat--after-draw ()
  "Check the placeholder after the buffer was drawn."
  (when (derived-mode-p 'ecc-chat-mode)
    (ecc-chat-update-placeholder)))

(add-hook 'ecc-render-after-draw-hook #'ecc-chat--after-draw)

;;;; What is at point

(defun ecc-chat-node-id-at-point (&optional position)
  "Return the id of the node drawn at POSITION, or point, or nil."
  (get-text-property (or position (point)) 'ecc-node))

(defun ecc-chat-node-at-point ()
  "Return the node of the model the point is on, or nil.
The Files and Tasks rows are drawn without a node and give nil."
  (when-let* ((session ecc-render--session)
              (id (ecc-chat-node-id-at-point)))
    (ecc-model-node session id)))

(defun ecc-chat-file-at-point ()
  "Return the path of the Files row the point is on, or nil."
  (when-let* ((id (ecc-chat-node-id-at-point)))
    (and (string-prefix-p "file:" id) (substring id 5))))

(defun ecc-chat-heading-at-point ()
  "Return the id of the heading whose line the point is on, or nil."
  (get-text-property (line-beginning-position) 'ecc-heading))

;;;; Folding (FR-OUT-3)

(defun ecc-chat-toggle ()
  "Fold or unfold the node at point.
On a heading the body under it is toggled; on a line of the body the
point moves to the heading and the body is folded away."
  (interactive)
  (let ((id (ecc-chat-node-id-at-point)))
    (unless (and id (ecc-render-node-foldable-p id))
      (user-error "Nothing to fold here"))
    (if (equal (ecc-chat-heading-at-point) id)
        (ecc-render-toggle-node id)
      (goto-char (car (ecc-render-node-bounds id)))
      (ecc-render-hide-node id))))

(defun ecc-chat-show-level (level)
  "Unfold the transcript down to LEVEL and fold everything deeper.
LEVEL 1 shows only the top headings, 2 what is directly under them,
and so on, the way the number keys of magit-section did."
  (dolist (id (ecc-render-node-ids (lambda (_id entry) (nth 3 entry))))
    (if (>= (ecc-render-node-depth id) (1- level))
        (ecc-render-hide-node id)
      (ecc-render-show-node id))))

(defun ecc-chat-show-level-1 ()
  "Fold everything but the top headings."
  (interactive)
  (ecc-chat-show-level 1))

(defun ecc-chat-show-level-2 ()
  "Show two levels of headings."
  (interactive)
  (ecc-chat-show-level 2))

(defun ecc-chat-show-level-3 ()
  "Show three levels of headings."
  (interactive)
  (ecc-chat-show-level 3))

(defun ecc-chat-show-level-4 ()
  "Show four levels of headings."
  (interactive)
  (ecc-chat-show-level 4))

(defun ecc-chat-expand-all ()
  "Unfold every block in the transcript (FR-OUT-14 c)."
  (interactive)
  (mapc #'ecc-render-show-node (ecc-render-block-ids)))

(defun ecc-chat-collapse-all ()
  "Fold every block in the transcript, keeping the turns open (FR-OUT-14 c)."
  (interactive)
  (mapc #'ecc-render-hide-node (ecc-render-block-ids)))

;;;; Movement (FR-OUT-14 a, b)

(defun ecc-chat--next-heading (position)
  "Return the start of the first heading line after POSITION, or nil."
  (let ((pos position) found)
    (while (and (null found) pos)
      (setq pos (next-single-property-change pos 'ecc-heading))
      (when (and pos (get-text-property pos 'ecc-heading))
        (setq found pos)))
    found))

(defun ecc-chat--visible-p (position)
  "Return non-nil when the text at POSITION is not folded away."
  (not (invisible-p position)))

(defun ecc-chat-next-heading ()
  "Move to the next heading that is not folded away."
  (interactive)
  (let ((pos (ecc-chat--next-heading (point))))
    (while (and pos (not (ecc-chat--visible-p pos)))
      (setq pos (ecc-chat--next-heading pos)))
    (unless pos
      (user-error "No further heading"))
    (goto-char pos)))

(defun ecc-chat-previous-heading ()
  "Move to the start of this heading, or to the previous one when there."
  (interactive)
  (let ((pos (ecc-render--previous-heading (point))))
    (while (and pos (not (ecc-chat--visible-p pos)))
      (setq pos (ecc-render--previous-heading pos)))
    (unless pos
      (user-error "No earlier heading"))
    (goto-char pos)))

(defun ecc-chat--current-depth ()
  "Return the depth of the heading at or before point, or nil."
  (let ((pos (if (ecc-chat-heading-at-point)
                 (line-beginning-position)
               (ecc-render--previous-heading (point)))))
    (and pos (get-text-property pos 'ecc-depth))))

(defun ecc-chat-next-sibling ()
  "Move to the next heading at the same depth, staying under the same parent."
  (interactive)
  (let* ((depth (or (ecc-chat--current-depth) (user-error "Not on a heading")))
         (pos (ecc-chat--next-heading (point)))
         (found nil))
    (while (and pos (not found))
      (let ((there (get-text-property pos 'ecc-depth)))
        (cond ((or (null there) (< there depth)) (setq pos nil))
              ((= there depth) (setq found pos))
              (t (setq pos (ecc-chat--next-heading pos))))))
    (unless found
      (user-error "No further heading at this depth"))
    (goto-char found)))

(defun ecc-chat-previous-sibling ()
  "Move to the previous heading at the same depth, under the same parent."
  (interactive)
  (let* ((depth (or (ecc-chat--current-depth) (user-error "Not on a heading")))
         (pos (ecc-render--previous-heading
               (if (ecc-chat-heading-at-point) (line-beginning-position) (point))))
         (found nil))
    (while (and pos (not found))
      (let ((there (get-text-property pos 'ecc-depth)))
        (cond ((or (null there) (< there depth)) (setq pos nil))
              ((= there depth) (setq found pos))
              (t (setq pos (ecc-render--previous-heading pos))))))
    (unless found
      (user-error "No earlier heading at this depth"))
    (goto-char found)))

(defun ecc-chat-up-heading ()
  "Move to the heading this one is under."
  (interactive)
  (let* ((depth (or (ecc-chat--current-depth) (user-error "Not on a heading")))
         (pos (ecc-render--previous-heading
               (if (ecc-chat-heading-at-point) (line-beginning-position) (point))))
         (found nil))
    (while (and pos (not found))
      (let ((there (get-text-property pos 'ecc-depth)))
        (if (and there (< there depth))
            (setq found pos)
          (setq pos (ecc-render--previous-heading pos)))))
    (unless found
      (user-error "Already at the top"))
    (goto-char found)))

(defun ecc-chat--goto-neighbour (ids forward)
  "Move to the node of IDS after point, or before when not FORWARD."
  (let* ((pos (point))
         (positions (mapcar (lambda (id) (car (ecc-render-node-bounds id))) ids))
         (target (if forward
                     (seq-find (lambda (p) (> p pos)) positions)
                   (car (last (seq-filter (lambda (p) (< p pos)) positions))))))
    (if target
        (goto-char target)
      (user-error (if forward "No further section" "No earlier section")))))

(defun ecc-chat-next-turn ()
  "Move to the next turn (FR-OUT-14 a)."
  (interactive)
  (ecc-chat--goto-neighbour (ecc-render-turn-ids) t))

(defun ecc-chat-previous-turn ()
  "Move to the previous turn (FR-OUT-14 a)."
  (interactive)
  (ecc-chat--goto-neighbour (ecc-render-turn-ids) nil))

(defun ecc-chat-next-block ()
  "Move to the next tool, diff or thinking block (FR-OUT-14 b)."
  (interactive)
  (ecc-chat--goto-neighbour (ecc-render-block-ids) t))

(defun ecc-chat-previous-block ()
  "Move to the previous tool, diff or thinking block (FR-OUT-14 b)."
  (interactive)
  (ecc-chat--goto-neighbour (ecc-render-block-ids) nil))

(defun ecc-chat-goto-files ()
  "Move to the Files section, unfolding it."
  (interactive)
  (unless (ecc-render-node-bounds "files")
    (user-error "No file has been touched yet"))
  (ecc-render-goto-id "files"))

(provide 'ecc-chat)

;;; ecc-chat.el ends here
