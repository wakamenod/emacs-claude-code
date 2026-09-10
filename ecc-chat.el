;;; ecc-chat.el --- The one buffer a session is read and written in  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; `ecc-chat-mode' is the major mode of a session buffer: the transcript
;; `ecc-render' draws, and under it, after a separator, the prompt region
;; the user types in (docs/phase9-ui-redesign.md, section 4).  Under the
;; region come another rule and the permission mode the session runs,
;; which S-TAB walks through (FR-SES-6); that footer is read-only text,
;; and the region ends where it begins rather than at the end of the
;; buffer.  The placeholder of an empty region is ghost text.
;;
;; The two parts answer to different keys.  The transcript is read-only
;; text carrying `ecc-chat-transcript-map' as its `keymap' property, so
;; that one letter commands (n, p, a, d, TAB...) work there and nowhere
;; else; the prompt region has no such property, so the keymap of the
;; major mode applies, and that one only binds RET, TAB and C-c keys.
;; Sending is C-c C-c, or RET when `ecc-chat-return-sends' is on.
;;
;; A request waiting for an answer is answered from the prompt region
;; too, without walking to it: C-c C-a allows one and C-c C-d denies
;; one, both through `ecc-perm-current-request', which falls back to the
;; oldest request waiting when the point is not on one (FR-PERM-6).
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
(declare-function ecc-prompt-read-command "ecc-prompt" (session))
(defvar ecc-prompt-slash-reads-command)
(declare-function ecc-prompt-yank-image "ecc-prompt" (mime data))
(declare-function ecc-prompt-dnd-insert "ecc-prompt" (url &optional action))
(declare-function ecc-switch-session "ecc-window" (session))
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
(declare-function ecc-btw-show "ecc-btw" (&optional session))
(declare-function ecc-next-attention "ecc-answer" ())
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

(defcustom ecc-chat-line-spacing 0.15
  "Extra room under every line of a session buffer, or nil for none.
Read as `line-spacing\=' reads it: a float is a fraction of the height
of the line.  A conversation is prose, and prose set solid is harder
to read than the same prose given a little air."
  :type '(choice (const :tag "None" nil) number)
  :group 'ecc)

(defcustom ecc-chat-text-width 100
  "Most columns the text of a session buffer is drawn across, or nil.
A line too long is one the eye loses its way back along, and a session
buffer is often given a whole wide frame.  The extra width is put in
the right margin of the window rather than taken off it, so that
whatever else the window holds is unaffected."
  :type '(choice (const :tag "The whole window" nil) integer)
  :group 'ecc)

(defcustom ecc-chat-placeholder "Ask Claude… (C-c ? for the menu)"
  "What an empty prompt region says, in a dim face."
  :type 'string
  :group 'ecc)

(defvar-local ecc-chat--placeholder-overlay nil
  "The overlay whose `after-string' is the ghost text of this buffer.")

(defvar-local ecc-chat--prompt-end nil
  "Marker where the prompt region ends and the footer begins.
It advances with what is typed at it, so that the draft grows in front
of the footer rather than into it.")

(defvar ecc-chat-placeholder-functions nil
  "Functions offering a placeholder for an empty prompt region.
Each is called with the session and returns a string or nil; the
first string wins over `ecc-chat-placeholder'.  The suggestion of
FR-HINT-4 arrives this way.")

(defcustom ecc-chat-show-footer t
  "Non-nil says which permission mode the session runs under the prompt.
A rule and one dim line, the way the terminal client puts them under
its own prompt."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-chat-permission-mode-cycle
  '("default" "acceptEdits" "plan" "auto")
  "Permission modes `ecc-chat-cycle-permission-mode\=' walks through.
What shift+tab walks through in the terminal client, less
\"bypassPermissions\", which it enters between \"plan\" and \"auto\"
where the environment allows it: that mode answers every request on
its own, which is not something a key pressed by mistake should turn
on.  `ecc-set-permission-mode\=' still reaches it.

\"auto\" is a mode of its own, not another name for \"acceptEdits\":
it answers the prompts itself, `Bash\=' among them, while
\"acceptEdits\" only takes the edits (`claude\=' 2.1.263)."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-chat-permission-mode-labels
  '(("default" "⏵ manual mode" ecc-dim-face)
    ("acceptEdits" "⏵⏵ accept edits on" ecc-accept-edits-face)
    ("plan" "⏸ plan mode on" ecc-plan-mode-face)
    ("auto" "⏵⏵ auto mode on" ecc-auto-mode-face)
    ("bypassPermissions" "⏵⏵ bypass permissions on" ecc-error-face))
  "What the footer calls each permission mode, and in which face.
The words, the marks and the colours of the terminal client (`claude\='
2.1.263): purple for the edits it takes on its own, teal for plan,
amber for auto, which answers the requests itself.  Red for
bypassPermissions, which the client does not put here at all.

The client says nothing in the default mode; the footer names it
anyway, because otherwise nothing tells the reader that S-TAB
switches.  A mode that is not listed is shown under its own name, in
the dim face."
  :type '(alist :key-type (string :tag "Mode")
                :value-type (list (string :tag "Label") (face :tag "Face")))
  :group 'ecc)

;;;; Keymaps

(defvar ecc-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-chat-return)
    (define-key map (kbd "S-<return>") #'ecc-chat-newline)
    (define-key map (kbd "C-j") #'ecc-chat-newline)
    (define-key map (kbd "TAB") #'ecc-chat-tab)
    (define-key map (kbd "/") #'ecc-chat-slash)
    (define-key map (kbd "C-k") #'ecc-chat-kill-line)
    (define-key map (kbd "<backtab>") #'ecc-chat-cycle-permission-mode)
    (define-key map (kbd "S-<tab>") #'ecc-chat-cycle-permission-mode)
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
    (define-key map (kbd "C-c C-a") #'ecc-perm-allow)
    (define-key map (kbd "C-c C-d") #'ecc-perm-deny)
    (define-key map (kbd "C-c a") #'ecc-perm-allow-all)
    (define-key map (kbd "C-c A") #'ecc-session-allow-all-remember)
    (define-key map (kbd "C-c D") #'ecc-dashboard)
    (define-key map (kbd "C-c n") #'ecc-next-attention)
    (define-key map (kbd "C-c b") #'ecc-btw-show)
    (define-key map (kbd "C-c t") #'ecc-switch-session)
    (define-key map (kbd "C-c C-e") #'ecc-session-export-markdown)
    ;; `?' stays self-inserting in a region one writes prose in, so the
    ;; menu is on C-c ? here and on ? in the transcript (NFR-10).
    (define-key map (kbd "C-c ?") #'ecc-menu)
    map)
  "Keymap of `ecc-chat-mode', in force in the prompt region.
Everything here is RET, TAB or a key under the mode prefix, so that a
letter is a letter.  The one exception is `/', which inserts itself
and then offers the slash commands (`ecc-chat-slash').")

(defvar ecc-chat-transcript-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'ecc-chat-toggle)
    (define-key map (kbd "<backtab>") #'ecc-chat-cycle-permission-mode)
    (define-key map (kbd "S-<tab>") #'ecc-chat-cycle-permission-mode)
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
    (define-key map (kbd "P") #'ecc-chat-goto-plans)
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
  ;; Markdown markup symbols are hidden by the ecc-markup invisible spec (§3.3).
  (add-to-invisibility-spec '(ecc-markup . nil))
  (setq-local completion-at-point-functions
              (list #'ecc-prompt-capf #'ecc-prompt-at-capf))
  ;; A request waiting for an answer is what the mode line is for
  ;; (FR-PERM-4).  What the session costs and how much room is left in
  ;; its context are on the right of the header line instead, where
  ;; they do not crowd the mode name; `ecc-mode-line-format\=' puts them
  ;; back for whoever wants them there (FR-HINT-3).
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
  (setq-local line-spacing ecc-chat-line-spacing)
  ;; The margin is set per window rather than per buffer, so it is
  ;; redone whenever a window showing the buffer changes size.
  (add-hook 'window-size-change-functions #'ecc-chat--set-margins nil t)
  (ecc-chat--set-margins (selected-frame))
  (add-hook 'post-command-hook #'ecc-chat--post-command nil t)
  (add-hook 'after-change-functions #'ecc-chat--after-change nil t))

(defun ecc-chat--set-margins (frame-or-window)
  "Hold the text of a session window to `ecc-chat-text-width\=' columns.
FRAME-OR-WINDOW is what `window-size-change-functions\=' was called
with.  Whatever the window has over that width goes in its right
margin; a window narrower than that, and a nil width, leave it alone."
  (dolist (window (cond ((windowp frame-or-window) (list frame-or-window))
                        ((framep frame-or-window)
                         (window-list frame-or-window 'no-minibuffer))
                        (t nil)))
    (when (and (window-live-p window)
               (derived-mode-p 'ecc-chat-mode)
               (eq (window-buffer window) (current-buffer)))
      (let* ((margin (nth 1 (window-margins window)))
             (width (+ (window-body-width window) (or margin 0)))
             (want (if ecc-chat-text-width
                       (max 0 (- width ecc-chat-text-width))
                     0)))
        (unless (eql want (or margin 0))
          (set-window-margins window (car (window-margins window))
                              (and (> want 0) want)))))))

;;;; The prompt region

(defun ecc-chat-prompt-start ()
  "Return where the prompt region of this buffer starts, or nil."
  (ecc-render-prompt-start))

(defun ecc-chat-prompt-end ()
  "Return where the prompt region of this buffer ends.
That is where the footer under it begins, and the end of the buffer
while there is no footer."
  (if (and ecc-chat--prompt-end (marker-buffer ecc-chat--prompt-end))
      (marker-position ecc-chat--prompt-end)
    (point-max)))

(defun ecc-chat-in-prompt-p (&optional position)
  "Return non-nil when POSITION, or point, is in the prompt region."
  (when-let* ((start (ecc-chat-prompt-start))
              (position (or position (point))))
    (and (>= position start) (<= position (ecc-chat-prompt-end)))))

(defun ecc-chat-draft ()
  "Return what is written in the prompt region, without properties.
The placeholder is ghost text rather than buffer text and the footer
lies past the end of the region, so neither is part of it."
  (if-let* ((start (ecc-chat-prompt-start)))
      (buffer-substring-no-properties start (ecc-chat-prompt-end))
    ""))

(defun ecc-chat-clear-draft ()
  "Empty the prompt region."
  (when-let* ((start (ecc-chat-prompt-start)))
    (delete-region start (ecc-chat-prompt-end))))

(defun ecc-chat-set-draft (text)
  "Replace the prompt region with TEXT and leave point at its end."
  (let ((start (or (ecc-chat-prompt-start)
                   (user-error "This buffer has no prompt region"))))
    (ecc-chat--remove-placeholder)
    (delete-region start (ecc-chat-prompt-end))
    (goto-char start)
    (insert text)))

(defun ecc-chat-goto-prompt ()
  "Move point to the end of the prompt region.
With nothing written there yet, that is its start, where the cursor
sits on the first character of the ghost text."
  (interactive)
  (unless (ecc-chat-prompt-start)
    (user-error "This buffer has no prompt region"))
  (goto-char (ecc-chat-prompt-end)))

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

(defun ecc-chat-kill-line (&optional arg)
  "Kill to the end of the line, staying inside the prompt region.
The footer under the region is read-only text of its own, and the
newline that ends the last line of the draft is the first character of
it, so a plain `kill-line\=' at the end of the draft is refused rather
than killing the line.  Narrowing to the region keeps ARG,
`kill-whole-line\=' and everything else about `kill-line\=' as they are
anywhere else, and ends the draft where the region ends."
  (interactive "P")
  (if-let* ((start (and (ecc-chat-in-prompt-p) (ecc-chat-prompt-start))))
      (save-restriction
        (narrow-to-region start (ecc-chat-prompt-end))
        (kill-line arg))
    (kill-line arg)))

(defun ecc-chat-tab ()
  "Complete in the prompt region, or fold in the transcript."
  (interactive)
  (if (ecc-chat-in-prompt-p)
      (progn (require 'ecc-prompt) (completion-at-point))
    (ecc-chat-toggle)))

(defun ecc-chat--slash-opens-commands-p ()
  "Return non-nil when the slash just typed should ask for a command.
Only a slash that opens the prompt does: the CLI reads a command from
the start of what it is sent and nowhere else, so a slash further in
would be offered commands that are not going to run
\(`ecc-prompt-command-name\=').  A slash written into prose is left
alone, and so is one a keyboard macro types, where there is nobody to
answer the minibuffer.  What starts a word is still completed on TAB
wherever it stands (`ecc-prompt-command-bounds\=')."
  (and (bound-and-true-p ecc-prompt-slash-reads-command)
       ecc-render--session
       (not executing-kbd-macro)
       (not (minibufferp))
       (ecc-chat-in-prompt-p)
       (when-let* ((start (ecc-chat-prompt-start))
                   ((> (point) start)))
         ;; Only blanks may stand before it, and no newline: that is
         ;; what `ecc-prompt-command-name' reads as a command.
         (string-match-p "\\`[ \t]*\\'"
                         (buffer-substring-no-properties start (1- (point)))))))

(defun ecc-chat-slash (n)
  "Insert a slash, and offer the slash commands when it starts one.
N is the prefix argument, as for `self-insert-command\='.  The slash is
inserted first, so that leaving the question with `C-g\=' keeps it
\(FR-INP-3)."
  (interactive "p")
  (self-insert-command n ?/)
  (when (and (= n 1) (progn (require 'ecc-prompt) t)
             (ecc-chat--slash-opens-commands-p))
    (when-let* ((command (ecc-prompt-read-command ecc-render--session)))
      (insert (string-remove-prefix "/" command)))))

;;;; The placeholder

;; The placeholder is ghost text: the `after-string' of an empty overlay
;; at the start of the prompt region, dim, and shown while nothing has
;; been typed (docs/phase9-ui-redesign.md, section 4).  It is not buffer
;; text, so the cursor cannot walk into it, nothing has to be read-only,
;; and neither the undo history nor `ecc-chat-draft' ever sees it.  Its
;; first character carries the `cursor' property, which is what draws the
;; cursor on it rather than behind the whole string when point is at the
;; end of the buffer.  Anything typed in the region takes it away.

(defun ecc-chat-placeholder-string ()
  "Return the placeholder of this buffer, or nil when it has none."
  (let ((session ecc-render--session))
    (or (and session
             (seq-some (lambda (function) (funcall function session))
                       ecc-chat-placeholder-functions))
        ecc-chat-placeholder)))

(defun ecc-chat-placeholder-shown ()
  "Return the placeholder text shown in the prompt region, or nil."
  (when (and ecc-chat--placeholder-overlay
             (overlay-buffer ecc-chat--placeholder-overlay))
    (overlay-get ecc-chat--placeholder-overlay 'ecc-placeholder)))

(defun ecc-chat--remove-placeholder ()
  "Take the placeholder out of the prompt region.
Returns non-nil when there was one."
  (when (and ecc-chat--placeholder-overlay
             (overlay-buffer ecc-chat--placeholder-overlay))
    (delete-overlay ecc-chat--placeholder-overlay)
    t))

(defun ecc-chat--insert-placeholder (text)
  "Show TEXT as the ghost text of the prompt region.
The overlay is empty and sits at the start of the region; TEXT hangs
off it as its `after-string', so it is shown and nothing more."
  (let ((start (ecc-chat-prompt-start))
        (ghost (propertize text 'face 'ecc-dim-face)))
    ;; The cursor belongs on the first character of the ghost text, not
    ;; behind all of it, which is where point at the end of the buffer
    ;; would otherwise put it.
    (when (> (length ghost) 0)
      (put-text-property 0 1 'cursor t ghost))
    (if (and ecc-chat--placeholder-overlay
             (overlay-buffer ecc-chat--placeholder-overlay))
        (move-overlay ecc-chat--placeholder-overlay start start)
      ;; No `evaporate': an empty overlay carrying it is deleted at once.
      (setq ecc-chat--placeholder-overlay (make-overlay start start)))
    (overlay-put ecc-chat--placeholder-overlay 'after-string ghost)
    (overlay-put ecc-chat--placeholder-overlay 'ecc-placeholder text)))

(defun ecc-chat-update-placeholder (&optional buffer)
  "Show the placeholder in BUFFER while its prompt region is empty.
BUFFER defaults to the current one.  Returns the text shown, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (let ((start (ecc-chat-prompt-start))
          (text (ecc-chat-placeholder-string)))
      (cond
       ((and start text (string-empty-p (ecc-chat-draft)))
        ;; Put in every time: a redraw leaves the overlay behind where
        ;; the prompt region used to start.
        (ecc-chat--insert-placeholder text)
        text)
       (t (ecc-chat--remove-placeholder) nil)))))

;;;; The footer: which permission mode the session runs (FR-SES-6)

;; Under the prompt region come a rule and one dim line naming the
;; permission mode, as the terminal client has them under its own
;; prompt.
;;
;; They are read-only buffer text, and the region above them ends at
;; the `ecc-chat--prompt-end' marker rather than at the end of the
;; buffer.  Ghost text was tried first -- the `after-string' of an
;; overlay, the way the placeholder is drawn -- and the cursor could
;; not be kept out of it: a string shown after point takes the cursor
;; with it, and the `cursor' property that is supposed to bring it back
;; did not once the placeholder had a string at the same place
;; (2026-09-08, `docs/decisions.md').  Text has no such question: the
;; end of the draft is a position in the buffer like any other.
;;
;; What the renderer does is unaffected, because it draws only up to
;; the start of the prompt region and never deletes past it (FR-UI-2).
;; The footer is written with `with-silent-modifications', so it stays
;; out of the undo history of the draft as the placeholder does.

(defun ecc-chat--permission-mode-label (session)
  "Return what the footer calls the permission mode SESSION runs.
The label and the face come from `ecc-chat-permission-mode-labels\='."
  (let* ((mode (or (ecc-session-permission-mode session) "default"))
         (entry (cdr (assoc mode ecc-chat-permission-mode-labels))))
    (concat (propertize (or (car entry) mode)
                        'face (or (cadr entry) 'ecc-dim-face))
            (propertize " (S-TAB to cycle)" 'face 'ecc-dim-face))))

(defun ecc-chat--footer-model (session)
  "Return the model SESSION runs, for the right of the footer, or nil.
The header line used to name it; it belongs next to the permission
mode, since both say what the session is rather than what it is
doing."
  (when-let* ((model (ecc-render--model-name session)))
    (propertize model 'face 'ecc-dim-face)))

(defun ecc-chat-footer-string ()
  "Return the footer of this buffer, or nil when it has none.
The rule is one stretched space, as the separator above the prompt
region is, so that it spans whatever width the window has.  The
permission mode stands on the left of the line under it and the model
on the right, held there by a stretched space of its own."
  (when-let* ((session (and ecc-chat-show-footer ecc-render--session)))
    (let ((model (ecc-chat--footer-model session)))
      (concat "\n"
              (propertize " " 'display '(space :align-to right)
                          'face 'ecc-separator-face)
              "\n"
              (ecc-chat--permission-mode-label session)
              (when model
                (concat (propertize
                         " " 'display (list 'space :align-to
                                            (list '- 'right
                                                  (1+ (string-width model)))))
                        model))))))

(defun ecc-chat-footer-shown ()
  "Return the footer under the prompt region, without properties, or nil."
  (when (and ecc-chat--prompt-end (marker-buffer ecc-chat--prompt-end)
             (< (ecc-chat-prompt-end) (point-max)))
    (buffer-substring-no-properties (ecc-chat-prompt-end) (point-max))))

(defun ecc-chat--remove-footer ()
  "Take the footer out from under the prompt region.
Returns non-nil when there was one."
  (when (ecc-chat-footer-shown)
    (let ((start (ecc-chat-prompt-end)))
      (with-silent-modifications
        (delete-region start (point-max))
        (set-marker ecc-chat--prompt-end nil)
        (setq ecc-chat--prompt-end nil)))
    t))

(defun ecc-chat--footer-text (text)
  "Return TEXT ready to be put under the prompt region.
It is read-only, and answers to the keys of the transcript -- all but
its first character, the newline that ends the draft line.  The draft
is written at that very position, and `key-lookup\=' takes the keymap
of the character after point: a keymap there would make a letter typed
into an empty prompt region move about the transcript instead."
  (let ((text (propertize text 'read-only t 'ecc-footer t)))
    (when (> (length text) 1)
      (put-text-property 1 (length text) 'keymap ecc-chat-transcript-map text))
    text))

(defun ecc-chat--insert-footer (text)
  "Put TEXT under the prompt region as read-only text.
The marker that ends the region is left in front of it, and takes what
is typed at the end of the draft with it."
  (let ((start (ecc-chat-prompt-end)))
    (with-silent-modifications
      (save-excursion
        (delete-region start (point-max))
        (goto-char start)
        (insert (ecc-chat--footer-text text))
        ;; The marker advances with an insertion at it, which is what
        ;; keeps the draft in front of the footer, so it has to be put
        ;; back in front of the text just written.
        (if (and ecc-chat--prompt-end (marker-buffer ecc-chat--prompt-end))
            (set-marker ecc-chat--prompt-end start)
          (setq ecc-chat--prompt-end (copy-marker start t)))))))

(defun ecc-chat-update-footer (&optional buffer)
  "Show the footer under the prompt region of BUFFER.
BUFFER defaults to the current one.  A buffer with no prompt region --
the transcript of an agent -- has no footer.  Returns the text shown,
or nil."
  (with-current-buffer (or buffer (current-buffer))
    (let ((text (and (ecc-chat-prompt-start) (ecc-chat-footer-string))))
      (cond
       ((null text) (ecc-chat--remove-footer) nil)
       ;; Written again only when it has something else to say: every
       ;; command passes through here, and the draft is not to be
       ;; disturbed for nothing.
       ((equal (substring-no-properties text) (ecc-chat-footer-shown)) text)
       (t (ecc-chat--insert-footer text) text)))))

(defvar-local ecc-chat--refused-modes nil
  "Permission modes the CLI of this session has refused.
The cycle steps over them from then on, so that S-TAB is not stuck
asking again for a mode this session cannot have.")

(defun ecc-chat--next-permission-mode (current)
  "Return the mode to switch to after CURRENT, or nil when there is none.
The next one in `ecc-chat-permission-mode-cycle\=', around from the end,
and past whatever the CLI has already refused.  A CURRENT outside the
cycle -- \"bypassPermissions\", or the mode a plan review left behind --
goes to the first of it."
  (let ((cycle (seq-remove (lambda (mode) (member mode ecc-chat--refused-modes))
                           ecc-chat-permission-mode-cycle)))
    (when cycle
      (or (cadr (member current cycle)) (car cycle)))))

(defun ecc-chat-cycle-permission-mode ()
  "Switch the session of this buffer to the next permission mode (FR-SES-6).
The modes of `ecc-chat-permission-mode-cycle\=' in order, as shift+tab
walks through them in the terminal client.

The CLI can refuse one -- \"auto\" is only for a model that supports it
\(claude 2.1.263) -- and it answers the request rather than the key, so
the refusal arrives later: it is said in the echo area, the mode is
struck off the cycle of this session, and the one after it is asked for
instead."
  (interactive)
  (let* ((session (or ecc-render--session
                      (user-error "This buffer talks to no session")))
         (current (or (ecc-session-permission-mode session) "default"))
         (next (or (ecc-chat--next-permission-mode current)
                   (user-error "No permission mode left for this session")))
         (buffer (current-buffer)))
    (ecc-proc-set-permission-mode
     session next
     (lambda (session reason)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (cl-pushnew next ecc-chat--refused-modes :test #'equal)
           (message "%s: %s" (ecc-session-name session) reason)
           (when (ecc-chat--next-permission-mode current)
             (ecc-chat-cycle-permission-mode))))))
    (message "%s: switching to %s" (ecc-session-name session) next)
    next))

(defun ecc-chat--on-permission-mode (session _mode)
  "Say in the buffer of SESSION which mode it runs now."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ecc-chat-update-footer)
        (force-mode-line-update)))))

(add-hook 'ecc-permission-mode-functions #'ecc-chat--on-permission-mode)

(defun ecc-chat--after-change (beg _end _length)
  "Take the placeholder out as soon as the prompt region is written to.
BEG is where the change began."
  (when (and (ecc-chat-in-prompt-p beg)
             (ecc-chat-placeholder-shown))
    (ecc-chat--remove-placeholder)))

(defun ecc-chat--update-ghosts ()
  "Put the placeholder and the footer of this buffer where they belong.
The placeholder comes first: whether it is shown decides where the
cursor of an empty prompt region is drawn."
  (ecc-chat-update-placeholder)
  (ecc-chat-update-footer))

(defun ecc-chat--post-command ()
  "Keep the ghost text right after a command in this buffer."
  (when (derived-mode-p 'ecc-chat-mode)
    (ecc-chat--update-ghosts)))

(defun ecc-chat--after-draw ()
  "Check the ghost text after the buffer was drawn."
  (when (derived-mode-p 'ecc-chat-mode)
    (ecc-chat--update-ghosts)))

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

(defun ecc-chat-plan-file-at-point ()
  "Return the path of the Plan row the point is on, or nil."
  (when-let* ((id (ecc-chat-node-id-at-point)))
    (and (string-prefix-p "plan:" id) (substring id 5))))

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

(defun ecc-chat-goto-plans ()
  "Move to the Plan section, unfolding it."
  (interactive)
  (unless (ecc-render-node-bounds "plans")
    (user-error "No plan of this session came with a file"))
  (ecc-render-goto-id "plans"))

(provide 'ecc-chat)

;;; ecc-chat.el ends here
