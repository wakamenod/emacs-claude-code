;;; ecc-chat.el --- The one buffer a session is read and written in  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Assisted-by: Claude Code:claude-opus-5-5
;; Assisted-by: Claude Code:claude-fable-5-1
;; Assisted-by: Claude Code:claude-haiku-4-5
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

;; `ecc-chat-mode' is the major mode of a session buffer: the transcript
;; `ecc-render' draws, and under it, after a separator, the prompt
;; region the user types in.  Under the region come another rule and the
;; permission mode the session runs, which S-TAB walks through; that
;; footer is read-only text, and the region ends where it begins rather
;; than at the end of the buffer.  The placeholder of an empty region is
;; ghost text.
;;
;; The two parts answer to different keys.  The transcript is read-only
;; text carrying `ecc-chat-transcript-map' as its `keymap' property, so
;; that one letter commands (n, p, a, d, TAB...) work there and nowhere
;; else; the prompt region has no such property, so the keymap of the
;; major mode applies, and that one only binds RET, TAB and C-c keys.
;;
;; The keymaps are defined here, and each module above this one keeps
;; its commands in a keymap of its own and makes it a parent of them
;; (`ecc-chat-add-keymap-parent'): `ecc-prompt' the sending, the
;; history, the slash and what RET does in the region, `ecc-session'
;; what opens, refreshes or resumes from the transcript, `ecc-perm'
;; the answers to a request waiting for one, `ecc-review' the comment
;; and the edit on such a request, `ecc-history' what the button above
;; the first turn reads, and the queue, the hint, the terminal and the
;; menu a key or two each.  They all build on this file, so the dependency runs one way: `ecc-chat-mode'
;; loads nothing.  What makes a session buffer is at the end of this
;; file, `ecc-session-ensure-buffer', and it loads the whole package
;; before it makes one (`ecc--require-package'), so that every buffer
;; has the keys of every module whichever way it was reached.  A key
;; bound in the maps here, by a user after this file is loaded, wins over
;; theirs whatever loads next.  The mode line is put together the same way:
;; `ecc-hint' adds its part from `ecc-chat-mode-hook'.
;;
;; A request waiting for an answer is answered from the prompt region
;; too, without walking to it: `ecc-perm' puts the allow and the deny
;; on C-c C-a and C-c C-d, and they fall back to the oldest request
;; waiting when the point is not on one.
;;
;; Folding and movement work on the headings the renderer marked (the
;; `ecc-heading', `ecc-node' and `ecc-depth' text properties) and on the
;; node table it keeps; the commands here are the keys of magit-section
;; the transcript used to have, written for that structure.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-image)
(require 'ecc-mermaid)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-window)
(require 'ecc-btw)

(defvar show-paren-predicate)

;;;; Options

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

(defvar ecc-chat-placeholder "Ask Claude… (C-c ? for the menu)"
  "What an empty prompt region says, in a dim face.")

(defvar-local ecc-chat--placeholder-overlay nil
  "The overlay whose `after-string' is the ghost text of this buffer.")

(defvar-local ecc-chat--prompt-end nil
  "Marker where the prompt region ends and the footer begins.
It advances with what is typed at it, so that the draft grows in front
of the footer rather than into it.")

(defvar ecc-chat-placeholder-functions nil
  "Functions offering a placeholder for an empty prompt region.
Each is called with the session and returns a string or nil; the first
string wins over `ecc-chat-placeholder'.  The prompt suggestion arrives
this way.")

(defvar ecc-chat-show-footer t
  "Non-nil says which permission mode the session runs under the prompt.
A rule and one dim line, the way the terminal client puts them under
its own prompt.")

(defvar ecc-chat-permission-mode-cycle
  '("default" "acceptEdits" "plan" "auto")
  "Permission modes `ecc-chat-cycle-permission-mode\=' walks through.
What shift+tab walks through in the terminal client, less
\"bypassPermissions\", which it enters between \"plan\" and \"auto\"
where the environment allows it: that mode answers every request on
its own, which is not something a key pressed by mistake should turn
on.  `ecc-set-permission-mode\=' still reaches it.

\"auto\" is a mode of its own, not another name for \"acceptEdits\":
it answers the prompts itself, `Bash\=' among them, while
\"acceptEdits\" only takes the edits (`claude\=' 2.1.263).")

(defvar ecc-chat-permission-mode-labels
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
the dim face.")

;;;; Keymaps

(defun ecc-chat--keymap-inherits-p (map parent)
  "Return non-nil when PARENT is MAP, one of its parents, or in one of them.
A composed keymap is searched through the keymaps it is made of."
  (let ((found nil))
    (while (and map (not found))
      (if (eq map parent)
          (setq found t)
        ;; The keymaps a composed keymap is made of come before its
        ;; parent, which is the tail that starts with `keymap' again.
        (let ((tail (cdr map)))
          (while (and (consp tail) (not (eq (car tail) 'keymap)) (not found))
            (when (eq (car tail) parent)
              (setq found t))
            (setq tail (cdr tail))))
        (setq map (keymap-parent map))))
    found))

(defun ecc-chat-add-keymap-parent (map parent)
  "Give MAP the keys of PARENT, below its own and above its other parents.
This is how a module above this one gives the keymaps here its
commands: it keeps them in PARENT and hangs that under MAP, rather than
binding them in MAP, where they would overwrite whatever a user bound
there once this file was loaded.  MAP keeps the parents it has, and
PARENT is added once however often the module is loaded."
  (let ((old (keymap-parent map)))
    (unless (ecc-chat--keymap-inherits-p old parent)
      (set-keymap-parent map (make-composed-keymap (list parent) old)))))

(defvar ecc-chat-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Said here rather than left to `define-derived-mode', which puts
    ;; `text-mode-map' under a map that has no parent when the mode is
    ;; first turned on: by then `ecc-prompt' has given it one, and
    ;; `text-mode-map' would be left out.
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "S-<return>") #'ecc-chat-newline)
    (define-key map (kbd "C-j") #'ecc-chat-newline)
    (define-key map (kbd "TAB") #'ecc-chat-tab)
    (define-key map (kbd "C-k") #'ecc-chat-kill-line)
    ;; The line of this buffer is the one on the screen, and these three
    ;; are bound by name rather than left to the remaps of
    ;; `visual-line-mode', because a remap is a lookup on the command the
    ;; key already resolves to.  A user who has put their own command on
    ;; \`C-a' -- mwim, crux, a hand-written bounce -- never resolves to
    ;; `move-beginning-of-line', so the remap does not fire and the key
    ;; keeps walking the logical line (confirmed 2026-09-11).
    (define-key map (kbd "C-a") #'beginning-of-visual-line)
    (define-key map (kbd "C-e") #'end-of-visual-line)
    (define-key map (kbd "<backtab>") #'ecc-chat-cycle-permission-mode)
    (define-key map (kbd "S-<tab>") #'ecc-chat-cycle-permission-mode)
    ;; The interrupt is on C-c C-z, comint's key for stopping the
    ;; process, and C-c C-g is left unbound on purpose: pressing C-c and
    ;; then C-g to take the prefix back is the reflex of every other
    ;; mode, where it is harmless, and here it stopped the turn
    ;; (confirmed 2026-09-17).  Unbound, the sequence falls through to
    ;; `keyboard-quit', which is what the finger meant.
    (define-key map (kbd "C-c C-n") #'ecc-chat-next-turn)
    (define-key map (kbd "C-c C-p") #'ecc-chat-previous-turn)
    (define-key map (kbd "C-c C-b") #'ecc-btw-show)
    (define-key map (kbd "C-c C-t") #'ecc-switch-session)
    map)
  "Keymap of `ecc-chat-mode', in force in the prompt region.
Everything here is RET, TAB, a movement key or a key under the mode
prefix, so that a letter is a letter.  The one exception is `/', which
inserts itself and then offers the slash commands.

Under the prefix the key is always \\`C-c C-<letter>', never
\\`C-c <letter>': the Emacs Lisp manual reserves \\`C-c <letter>' for
users, and it is the only space reserved for them, so a mode that takes
one blocks the only keys its user is entitled to.  A command that finds
no \\`C-c C-<letter>' free goes to the menu on \\`C-c ?' rather than
taking one.")

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
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    (define-key map (kbd "i") #'ecc-chat-goto-prompt)
    (define-key map (kbd "q") #'quit-window)
    ;; No C-c C-k here: it falls through to the mode map, where it
    ;; empties the draft, so that the key discards the draft wherever
    ;; point is, as C-c C-c sends it from wherever point is.  Bound to the interrupt in the transcript,
    ;; the same key did two different destructive things in one buffer.
    ;; Movement and extraction
    (define-key map (kbd "]") #'ecc-chat-next-block)
    (define-key map (kbd "[") #'ecc-chat-previous-block)
    (define-key map (kbd "+") #'ecc-chat-expand-all)
    (define-key map (kbd "-") #'ecc-chat-collapse-all)
    ;; `v' goes to the prompt as `C-c c v' does from anywhere; `i' is
    ;; the same command for the finger that starts writing with it.
    ;; `F', `P', `T' and `L' are the capitals of the menu, and `I' is
    ;; the picture at point as the menu's `I' is the pictures.
    (define-key map (kbd "v") #'ecc-chat-goto-prompt)
    (define-key map (kbd "I") #'ecc-chat-toggle-picture)
    (define-key map (kbd "F") #'ecc-chat-goto-files)
    (define-key map (kbd "P") #'ecc-chat-goto-plans)
    map)
  "Keymap of the transcript, put on its text as the `keymap' property.
A key not here falls through to `ecc-chat-mode-map'.")

(defvar ecc-request-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-transcript-map)
    map)
  "Keymap of a node that is waiting for an answer.
The keys of `ecc-chat-transcript-map\=' keep their meaning here, so that
one letter is one thing wherever point is: the allow that widens to a
whole turn is `u\=' (until the turn ends) rather than `t\=', which opens
the terminal everywhere else and answered permissions here without
asking; the pattern is `r\=' (rule) rather than `p\=', which moves to the
previous heading everywhere else.  `a\=' and `d\=' are the exception
worth having: `d\=' in the transcript already denies the request it is
on, so both spellings agree.")

(defvar ecc-file-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-transcript-map)
    map)
  "Keymap of a file row in the Files section.
`SPC\=' is not taken back for folding here: it scrolls the transcript
everywhere else, and a key held down to read with should not stop at a
row.  TAB folds, on this row as on every other.")

(defvar ecc-chat-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-transcript-map)
    (define-key map (kbd "RET") #'push-button)
    (define-key map [mouse-2] #'push-button)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap of a button in the transcript, such as the history button.")

(defvar ecc-history-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ecc-chat-button-map)
    map)
  "Keymap of the button that reads the page before the first turn.
`ecc-history' gives it the command, as a parent above the button's keys.")

;;;; The mode

(define-derived-mode ecc-chat-mode text-mode "Claude"
  "Major mode of a Claude Code session: its transcript and its prompt.

\\{ecc-chat-mode-map}"
  :interactive nil
  ;; The modules above this one give the keymaps above their keys, and
  ;; the prompt region and the mode line their parts from
  ;; `ecc-chat-mode-hook'.  This mode loads none of them; what makes a
  ;; session buffer loads them first (`ecc-session-ensure-buffer').
  ;; Faces are applied when text is inserted, so no font lock is
  ;; wanted; `text-mode' turns none on.
  ;; The buffer is wrapped prose, so a line on the screen is the line a
  ;; reader means.  `visual-line-mode' is what makes C-n, C-p, C-a and
  ;; C-e agree with that: it turns on `word-wrap', clears
  ;; `truncate-lines', and -- the part that matters most here -- binds
  ;; `line-move-visual' to t buffer-locally, so C-n in the middle of a
  ;; wrapped paragraph steps to the next row rather than over the whole
  ;; paragraph to the next one.  The default of `line-move-visual' is t,
  ;; but a user who has turned it off globally means that for files, not
  ;; for a transcript that has no lines of its own (confirmed 2026-09-11).
  (visual-line-mode 1)
  ;; No paren matching: the buffer is prose, and prose is full of parens
  ;; that do not pair -- `1)' list items, `(笑', a full-width `（' closed
  ;; by a half-width `)'.  With `show-paren-style' `mixed' or
  ;; `expression', point near one of them painted the whole stretch to
  ;; its supposed partner in `show-paren-mismatch' (confirmed
  ;; 2026-10-12).  A nil `show-paren-predicate', buffer-local, rather
  ;; than `(show-paren-local-mode -1)': that leaves no local value when
  ;; the global mode is off as the buffer is made, so turning it on later
  ;; would bring it back, whereas the predicate is asked every time.  A
  ;; user who wants it here still has `show-paren-local-mode', which
  ;; `show-paren--enabled-p' heeds before the predicate.
  (setq-local show-paren-predicate nil)
  ;; A folded body shows as an ellipsis after its heading.
  (add-to-invisibility-spec '(ecc-fold . t))
  ;; Markdown markup symbols are hidden by the ecc-markup spec.
  (add-to-invisibility-spec '(ecc-markup . nil))
  ;; A request waiting for an answer is what the mode line is for.  What
  ;; the session costs and how much room is left in its context are on
  ;; the right of the header line instead, where they do not crowd the
  ;; mode name; `ecc-mode-line-format\=' puts them back for whoever
  ;; wants them there.  A list of constructs, so that a module can add
  ;; its own after this one from `ecc-chat-mode-hook'.
  (setq-local mode-line-process
              ;; Escaped where it is put in the mode line rather than in
              ;; the function: what that returns is text for a person.
              '((:eval (ecc--mode-line-escape (ecc-render-mode-line-process)))))
  (setq-local line-spacing ecc-chat-line-spacing)
  ;; A wrapped line lines up under the line that began it now, which
  ;; says it continues one plainly enough; the curly arrows the fringes
  ;; would put on either end of it say the same thing again, in the
  ;; corner of the eye, on every long paragraph.  This comes after
  ;; `visual-line-mode', which sets the same entry from
  ;; `visual-line-fringe-indicators' and would otherwise put back the
  ;; arrows of whoever has customized that.
  (setq-local fringe-indicator-alist
              (cons '(continuation nil nil)
                    (default-value 'fringe-indicator-alist)))
  ;; The margin is set per window rather than per buffer, so it is
  ;; redone whenever a window showing the buffer changes size.
  (add-hook 'window-size-change-functions #'ecc-chat--set-margins nil t)
  (ecc-chat--set-margins (selected-frame))
  (add-hook 'post-command-hook #'ecc-chat--post-command nil t)
  (add-hook 'after-change-functions #'ecc-chat--after-change nil t)
  (ecc-chat--watch-working-text))

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
      ;; `window-margins' returns the cons (LEFT . RIGHT), not a list:
      ;; once a right margin is set it is a dotted pair, and `nth' would
      ;; take the car of a number (confirmed 2026-09-10).
      (let* ((margin (cdr (window-margins window)))
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

(defun ecc-chat-toggle-picture ()
  "Toggle the picture at point.
A diagram is shown as its source, or its source as the diagram
\(`ecc-mermaid-toggle'); a GIF is stopped or set moving
\(`ecc-image-toggle-animation')."
  (interactive)
  (if (ecc-mermaid-block-at)
      (ecc-mermaid-toggle)
    (ecc-image-toggle-animation)))

(defun ecc-chat-newline ()
  "Insert a newline in the prompt region."
  (interactive)
  (unless (ecc-chat-in-prompt-p)
    (user-error "The transcript is read-only; i moves to the prompt"))
  (newline))

(defun ecc-chat-kill-line (&optional arg)
  "Kill to the end of the visual line, staying inside the prompt region.
The footer under the region is read-only text of its own, and the
newline that ends the last line of the draft is the first character of
it, so a plain kill at the end of the draft is refused rather than
killing the line.  Narrowing to the region keeps ARG,
`kill-whole-line\=' and everything else as they are anywhere else, and
ends the draft where the region ends.

The line killed is the visual one, because `ecc-chat-mode\=' turns on
`visual-line-mode\=', and \\`C-a' and \\`C-e' are bound to the ends of
the visual line beside it.  None of the three can be left to the
remaps of that mode: a remap is a lookup on the command the key
resolves to, and these keys resolve to commands of their own."
  (interactive "P")
  (if-let* ((start (and (ecc-chat-in-prompt-p) (ecc-chat-prompt-start))))
      (save-restriction
        (narrow-to-region start (ecc-chat-prompt-end))
        (ecc-chat--kill-line arg))
    (ecc-chat--kill-line arg)))

(defun ecc-chat--kill-line (arg)
  "Kill a line forward, by visual line where the buffer wraps.
ARG is passed on as `kill-line\=' takes it."
  (if visual-line-mode (kill-visual-line arg) (kill-line arg)))

(defun ecc-chat-tab ()
  "Complete in the prompt region, or fold in the transcript."
  (interactive)
  (if (ecc-chat-in-prompt-p)
      (completion-at-point)
    (ecc-chat-toggle)))

;;;; The placeholder

;; The placeholder is ghost text: the `after-string' of an empty overlay
;; at the start of the prompt region, dim, and shown while nothing has
;; been typed.  It is not buffer text, so the cursor cannot walk into
;; it, nothing has to be read-only, and neither the undo history nor
;; `ecc-chat-draft' ever sees it.  Its first character carries the
;; `cursor' property, which is what draws the cursor on it rather than
;; behind the whole string when point is at the end of the buffer.
;; Anything typed in the region takes it away.

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

(defun ecc-chat--composing-p ()
  "Return non-nil while an input method's working text sits in the prompt."
  (let ((ov (bound-and-true-p ns-working-overlay)))
    (and (overlayp ov)
         (eq (overlay-buffer ov) (current-buffer))
         (ecc-chat-in-prompt-p (overlay-start ov)))))

(defun ecc-chat-update-placeholder (&optional buffer)
  "Show the placeholder in BUFFER while its prompt region is empty.
An input method composing there counts as something written.
BUFFER defaults to the current one.  Returns the text shown, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (let ((start (ecc-chat-prompt-start))
          (text (ecc-chat-placeholder-string)))
      (cond
       ((and start text (string-empty-p (ecc-chat-draft))
             (not (ecc-chat--composing-p)))
        ;; Put in every time: a redraw leaves the overlay behind where
        ;; the prompt region used to start.
        (ecc-chat--insert-placeholder text)
        text)
       (t (ecc-chat--remove-placeholder) nil)))))

(defun ecc-chat--after-working-text (&rest _)
  "Show or hide the placeholder as an input method's working text changes."
  (when (derived-mode-p 'ecc-chat-mode)
    (ecc-chat-update-placeholder)))

;; The NS port's input method draws what it is composing as the
;; `after-string' of an empty overlay at point, `ns-working-overlay',
;; rather than as buffer text (Emacs 32.0.50, NS port, confirmed
;; 2026-09-26).  Sharing the prompt start with the placeholder, it is
;; drawn behind the whole ghost text while the cursor and the candidate
;; window stay in front of it.  Nothing else can notice it: the working
;; text changes no buffer text, so `after-change-functions' do not run,
;; and it arrives as a special event, which runs no command hooks.  So
;; the functions that put it in and take it out are advised; commit
;; inserts real text and is handled by `ecc-chat--after-change'.  The
;; emacs-plus build puts it in through `ns-insert-marked-text' as well,
;; a `before-string' of the same kind that never goes near
;; `ns-insert-working-text' (both bound in `special-event-map', same
;; date).
;;
;; The advice goes on with the first chat buffer, not when the file is
;; loaded: before there is a prompt region there is nothing for it to
;; do, and an Emacs that never opens one keeps its input-method
;; functions as they came.  Nothing takes it off when the last chat
;; buffer goes, as with the hooks the Spaces and the restore put on;
;; outside a chat buffer it returns at once.  The hooks emacs-plus
;; runs around them, `mac-ime-before-put-text-hook' and
;; `mac-ime-after-put-text-hook', are its own and both run before the
;; overlay changes, not after (Emacs 32.0.50, emacs-plus, confirmed
;; 2026-10-14).  A buffer-local `pre-redisplay-functions' would see the
;; overlay before it is drawn, at the price of running on every redisplay
;; of the buffer, and only a real frame could show it does the same.
(defun ecc-chat--watch-working-text ()
  "Advise the NS port's working-text functions to keep the placeholder right.
Called as a chat buffer is set up; once each function is advised, again
changes nothing.  An Emacs without the NS port has none of them."
  (dolist (function '(ns-insert-working-text
                      ns-insert-marked-text
                      ns-delete-working-text))
    (when (and (fboundp function)
               (not (advice-member-p #'ecc-chat--after-working-text function)))
      (advice-add function :after #'ecc-chat--after-working-text))))

;;;; The footer: which permission mode the session runs

;; Under the prompt region come a rule and one dim line naming the
;; permission mode, as the terminal client has them under its own
;; prompt.
;;
;; They are read-only buffer text, and the region above them ends at the
;; `ecc-chat--prompt-end' marker rather than at the end of the buffer.
;; Ghost text was tried first -- the `after-string' of an overlay, the
;; way the placeholder is drawn -- and the cursor could not be kept out
;; of it: a string shown after point takes the cursor with it, and the
;; `cursor' property that is supposed to bring it back did not once the
;; placeholder had a string at the same place (decided 2026-09-08).
;; Text has no such question: the end of the draft is a position in the
;; buffer like any other.
;;
;; What the renderer does is unaffected, because it draws only up to the
;; start of the prompt region and never deletes past it. The footer is
;; written with `with-silent-modifications', so it stays out of the undo
;; history of the draft as the placeholder does.

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
doing.

Until the CLI has named one -- the seconds before system/init, and a
session opened but not started -- the model it would be started with
stands in (`ecc-proc-startup-model\\='): the moment to change the model
is before the first prompt, and a footer that says nothing until the
first answer is of no use then."
  (when-let* ((model (or (ecc-render--model-name session)
                         (ecc--short-model-name
                          (ecc-proc-startup-model session)))))
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
  "Switch the session of this buffer to the next permission mode.
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

;;;; Folding

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
  "Unfold every block in the transcript."
  (interactive)
  (mapc #'ecc-render-show-node (ecc-render-block-ids)))

(defun ecc-chat-collapse-all ()
  "Fold every block in the transcript, keeping the turns open."
  (interactive)
  (mapc #'ecc-render-hide-node (ecc-render-block-ids)))

;;;; Movement (b)

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
  "Move to the next turn."
  (interactive)
  (ecc-chat--goto-neighbour (ecc-render-turn-ids) t))

(defun ecc-chat-previous-turn ()
  "Move to the previous turn."
  (interactive)
  (ecc-chat--goto-neighbour (ecc-render-turn-ids) nil))

(defun ecc-chat-next-block ()
  "Move to the next tool, diff or thinking block."
  (interactive)
  (ecc-chat--goto-neighbour (ecc-render-block-ids) t))

(defun ecc-chat-previous-block ()
  "Move to the previous tool, diff or thinking block."
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

;;;; The buffer of a session

(defun ecc--require-package ()
  "Load the whole of ecc, as a session or its buffer is about to be made.
The features that register themselves when they are loaded -- the MCP
tools, among them, which a CLI lists once when it starts -- are only
there for a session that was opened with them loaded.  A session buffer
gets its keys, its completion and its part of the mode line from the
modules above this file, which `ecc-chat-mode' does not load: they
require it.  `ecc' is what requires every one of them, and it requires
this file in turn, so it is loaded here at run time rather than at the
top, and this is the one place in the package that does.  The buffer is
made here (`ecc-session-ensure-buffer'), and every command that loads
the package on its way in -- a session started, a menu, a restore, a
worktree handed over -- calls this, so that the `require' of `ecc' is
written once."
  (require 'ecc))

(defun ecc-session--forget-on-kill ()
  "Stop and forget the session when its buffer is killed.
Killing the buffer is taken as killing the session: the CLI is
stopped, the session leaves the list, and its line buffer goes with
it, so that nothing lingers in the dashboard as an exited session with
no buffer.  An agent transcript shares the session but is
not its buffer, so killing it does nothing."
  (when-let* ((session ecc-render--session))
    (when (and (eq (current-buffer) (ecc-session-buffer session))
               ;; `ecc-kill' has forgotten the session already; the
               ;; buffers are all that is left to it.
               (eq (ecc-model-session (ecc-session-id session)) session))
      (ecc-proc-stop session)
      (ecc-model-remove-session session)
      (ecc-image-cleanup-session session)
      (let ((buffer (ecc-session-stream-buffer session)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun ecc-session-directory (session)
  "Return the directory SESSION works in.
The root it was started in, which is what `ecc-window-session-project\='
asks as well: the buffer, the sidebar and the Spaces must not disagree
about where a session is.  The cwd the CLI reports comes second and
only for a session that has no root of its own -- one read back from a
recording.  It is not asked first because CLI 2.1.272 reports as the
session cwd whatever directory the last Bash tool call left it in
\(confirmed 2026-09-16), so it says where a tool ran and not where the
session lives."
  (when-let* ((directory (or (ecc-session-project-root session)
                             (ecc-session-cwd session))))
    (file-name-as-directory (expand-file-name directory))))

(defun ecc-session-buffer-name (name)
  "Return the name of the buffer of the session called NAME."
  (format "*ecc: %s*" name))

(defun ecc-session-ensure-buffer (session)
  "Return the buffer of SESSION, creating and drawing it if needed."
  (let ((buffer (ecc-session-buffer session)))
    (unless (buffer-live-p buffer)
      ;; The modules above this file give the buffer its keys, its
      ;; completion and its part of the mode line, and not every way here
      ;; has loaded them: a recording opened from a cold Emacs comes
      ;; through `ecc-history' alone.
      (ecc--require-package)
      (setq buffer (get-buffer-create
                    (ecc-session-buffer-name (ecc-session-name session))))
      (setf (ecc-session-buffer session) buffer)
      (with-current-buffer buffer
        ;; The buffer lives in the project, so that project commands and
        ;; `ecc-next-attention-in-project' see the right root.
        (setq default-directory (or (ecc-session-directory session)
                                    default-directory))
        (ecc-chat-mode)
        (add-hook 'kill-buffer-hook #'ecc-session--forget-on-kill nil t)
        (ecc-render-setup session buffer)))
    buffer))

(provide 'ecc-chat)

;;; ecc-chat.el ends here
