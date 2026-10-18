;;; ecc-session.el --- Session buffer and its commands for the ecc client  -*- lexical-binding: t; -*-

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

;; The commands that act on the buffer a conversation is read and
;; written in: visiting what is at point, reviewing, and taking things
;; out of the transcript.  The major mode, the keymaps, the movement and
;; the making of the buffer live in `ecc-chat'; the keys of the commands
;; here are in keymaps of their own at the end of this file, made parents
;; of those.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-image)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-display)
(require 'ecc-markdown)
(require 'ecc-diff)
(require 'ecc-window)
(require 'ecc-visit)
(require 'ecc-perm)
(require 'ecc-plan)
(require 'ecc-queue)
(require 'ecc-review)
(require 'ecc-lifecycle)

(defun ecc-session-set-root (session directory)
  "Move SESSION to DIRECTORY and take its buffer with it.
The root is where a session lives: the Space it opens in, the project
its tab line groups it under, and the `default-directory\=' of the
transcript, which is what Magit, `project-find-file\=' and everything
else run from the buffer acts in.  Only the user moves it, by typing a
`/cd\=' into the prompt region; nothing the model does moves a session.

DIRECTORY that is not there is refused and nil comes back: a
`default-directory\=' pointing at nothing breaks every command in the
buffer."
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (when (file-directory-p directory)
      (setf (ecc-session-project-root session) directory)
      (when-let* ((buffer (ecc-session-buffer session))
                  ((buffer-live-p buffer)))
        (with-current-buffer buffer
          (setq default-directory directory)))
      (force-mode-line-update t)
      directory)))

(defun ecc-session--rename-buffer (session)
  "Give the buffer of SESSION the name SESSION has now.
On `ecc-session-renamed-hook\=', ahead of the rest of it: what runs after
reads the buffer by its new name.  A session has no buffer until
`ecc-session-ensure-buffer' makes one, and that loads this file first,
so nothing is lost while it is not loaded."
  (when (buffer-live-p (ecc-session-buffer session))
    (with-current-buffer (ecc-session-buffer session)
      (rename-buffer (ecc-session-buffer-name (ecc-session-name session)) t)))
  (force-mode-line-update t))

(add-hook 'ecc-session-renamed-hook #'ecc-session--rename-buffer -90)

(define-obsolete-function-alias 'ecc-session-set-name #'ecc-model-set-name
  "0.4.4")

(defun ecc-session-rename (session name)
  "Rename SESSION to NAME here and in the CLI, and return the name used.
The rename here is made at once (`ecc-model-set-name\=').  The CLI is
told with a `/rename\=' that is not drawn (`ecc-proc-rename\='): at once
when it runs with no turn open, otherwise once it does.  The name it is
told is the one the session ended up with, NAME<2> included, so that
the history and a later resume call the session what it is called here.

A session read back from a recording is told when it is resumed, and
not otherwise: nothing runs it in the meantime, and the recording is
the CLI\='s to write."
  (let ((name (ecc-model-set-name session name)))
    (ecc-proc-rename session)
    name))

;;;###autoload
(defun ecc-rename-session (session name)
  "Rename SESSION to NAME and rename its buffers with it.
The CLI is told the name too, so that the history and a later resume
call the session NAME (`ecc-session-rename\=')."
  (interactive
   (let ((session (ecc-window-resolve-session current-prefix-arg)))
     (list session (read-string "New name: " (ecc-session-name session)))))
  (ecc-session-rename session name))

(defun ecc-session-at-point ()
  "Return the session of the current buffer, or signal an error."
  (or ecc-render--session
      (user-error "This buffer does not belong to a Claude session")))

;;;; Commands

(defun ecc-session-refresh ()
  "Redraw the whole transcript."
  (interactive)
  (ecc-render-refresh (ecc-session-at-point)))

(defun ecc-session-interrupt ()
  "Interrupt the running turn."
  (interactive)
  (let ((session (ecc-session-at-point)))
    (ecc-proc-interrupt session)
    (message "Interrupt requested")))

(defun ecc-session-resume ()
  "Bring the CLI of this session back.
A session that has stopped is resumed; an idle one that is still
running is restarted once the user agrees (`ecc-restart\=').  One key
for both, since what is wanted either way is a CLI that answers again."
  (interactive)
  (ecc-restart (ecc-session-at-point) t))

(defun ecc-session-show-log ()
  "Show the raw protocol log of this session."
  (interactive)
  (let ((session (ecc-session-at-point)))
    (ecc-window-display-beside-session
     (ecc--log-buffer (ecc-session-name session)) session)))

(defun ecc-session-visit ()
  "Open the thing at point: a URL, a file, an agent transcript or a buffer.
A question or a plan that is still waiting opens the buffer it is
answered in.

A line of a diff and the heading of a call that names a file open that
file, at the line when there is one (`ecc-visit-target-at-point\='); the
node laid open is \[ecc-session-show-detail].  A path the model wrote
opens the file it names wherever it is found -- a bare name or a path
written against another directory is looked for among the files of the
session and of the project, then among the files Emacs visits outside
it, and on the machine after asking (`ecc-visit-find-written\=').  The
file picked among several opens at once the next time; with a prefix
argument the search is made again.  A video or a sound among them
plays in the machine's own player instead (`ecc-visit-open\=').

A picture drawn in the transcript opens as itself.  A URL comes
first, and before the node the point is in: the point is
only on one where a link was drawn, which is narrow enough to say what
RET does there without a rule of its own.  It is the same key that
follows a link everywhere else in Emacs, and the same one the transcript
already opens things with.

The prompts waiting in the queue, drawn above the separator, open the
list of the queue (`ecc-queue-show\='), on the prompt at point.  They
come before anything else, a URL included: the text of a prompt is
what the user wrote, and a path or a URL in it is not a link."
  (interactive)
  (let* ((session (ecc-session-at-point))
         (queued (get-text-property (point) 'ecc-queue))
         (node (ecc-chat-node-at-point))
         (url (ecc-markdown-url-at-point))
         (path (or (ecc-chat-file-at-point) (ecc-chat-plan-file-at-point)))
         (picture (ecc-image-at-point))
         (written (and (not url) (not picture) (ecc-markdown-file-at-point)))
         (target (and (not url) (not picture) (not written)
                      (ecc-visit-target-at-point)))
         (request (and node (ecc-model-node-get node 'request)))
         (pending (and request (memq request (ecc-session-pending session)))))
    (cond
     (queued (ecc-queue-show session (get-text-property (point) 'ecc-queued)))
     (url (browse-url url))
     ;; A still opens in `image-mode\=', which zooms and scrolls; a video
     ;; is something Emacs cannot play, so the machine plays it.
     (picture (if (ecc-image-plays-outside-p picture)
                  (ecc-image-open-externally picture)
                (find-file-other-window picture)))
     (written (ecc-visit-open-written session written current-prefix-arg))
     (target (ecc-visit-open (car target) (cdr target) session))
     (path (ecc-visit-open path nil session))
     ((null node) (user-error "Nothing to show here"))
     ((eq (ecc-node-type node) 'agent) (ecc-session-show-agent session node))
     ((and pending (eq (ecc-node-type node) 'question))
      (ecc-window-display-beside-session (ecc-question-open request) session))
     ((and pending (eq (ecc-node-type node) 'plan))
      (ecc-window-display-beside-session (ecc-plan-open request) session))
     ((eq (ecc-node-type node) 'plan)
      ;; A plan that was answered already: show the file the CLI wrote it
      ;; to, when it named one and it is still there.
      (let ((path (and request (ecc-plan-file-path request))))
        (if (and path (file-exists-p path))
            (ecc-visit-open path nil session)
          (ecc-session--show-node session node))))
     (t (ecc-session--show-node session node)))))

(defun ecc-session-show-detail ()
  "Show every detail of the node at point in a buffer of its own.
The input of a call in full, its diff and its whole result, which the
transcript cuts."
  (interactive)
  (let ((session (ecc-session-at-point))
        (node (ecc-chat-node-at-point)))
    (unless node
      (user-error "Nothing to show here"))
    (ecc-session--show-node session node)))

(defun ecc-session-review ()
  "Open every change of this session as one diff to review."
  (interactive)
  (ecc-review (ecc-session-at-point)))

(defun ecc-session-review-file ()
  "Open the diff of the file at point in the Files section."
  (interactive)
  (ecc-review (ecc-session-at-point)
              (list (or (ecc-chat-file-at-point)
                        (user-error "Not on a file")))))

(defun ecc-session-review-or-deny ()
  "Deny the request at point, or open the review when not on one.
The d key of the transcript does both."
  (interactive)
  (if (ecc-perm-request-at-point)
      (call-interactively #'ecc-perm-deny)
    (ecc-session-review)))

(defun ecc-session--show-node (session node)
  "Show every detail of NODE of SESSION in a buffer."
  (let ((buffer (get-buffer-create
                 (format "*ecc-detail: %s*" (ecc-session-name session)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s  (%s)\n\n" (ecc-node-type node) (ecc-node-id node)))
        (pcase (ecc-node-type node)
          ((or 'tool 'agent)
           (insert (format "%s\n\n" (ecc-model-node-get node 'name)))
           (ecc-session--insert-call (ecc-model-node-get node 'name)
                                     (ecc-model-node-get node 'input)
                                     (ecc-model-node-get node 'before))
           (insert "\n")
           (insert (ecc-render--result-text (ecc-model-node-get node 'result)))
           (when (ecc-model-node-get node 'bash-edit)
             (insert "\n\n")
             (ecc-render--insert-bash-edit node "" t)))
          ((or 'permission 'question 'plan)
           (let ((request (ecc-model-node-get node 'request)))
             (insert (format "%s  %s\n\n"
                             (if request (ecc-request-tool-name request) "?")
                             (ecc-node-status node)))
             (when request
               (ecc-session--insert-call (ecc-request-tool-name request)
                                         (ecc-request-input request)
                                         (ecc-model-node-get node 'before)))))
          (_ (insert (or (ecc-model-node-get node 'text)
                         (format "%S" (ecc-node-data node))))))
        (goto-char (point-min)))
      (special-mode))
    (ecc-window-display-beside-session buffer session)))

(defun ecc-session--insert-call (name input before)
  "Insert the whole INPUT of a call to NAME, as a diff when it has one.
BEFORE is the file as it was before the call, when known."
  (let ((diff (ecc-diff-for-tool name input before)))
    (if diff
        (progn
          (when-let* ((path (alist-get 'file_path input)))
            (insert (abbreviate-file-name path) "\n"))
          (insert diff))
      (ecc-render--insert-input input ""))))

(defun ecc-session-show-agent (session node)
  "Show the transcript of the agent NODE of SESSION in its own buffer."
  (let* ((input (ecc-model-node-get node 'input))
         (title (format "%s: %s"
                        (or (ecc-model-node-get node 'agent-type)
                            (alist-get 'subagent_type input)
                            "Agent")
                        (ecc--truncate (or (alist-get 'description input)
                                           (ecc-model-node-get node 'agent-description)
                                           (ecc-node-id node))
                                       60)))
         (buffer (get-buffer-create (format "*ecc-agent: %s: %s*"
                                            (ecc-session-name session) title))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-chat-mode)
        (ecc-chat-mode))
      (ecc-render-draw-nodes session buffer
                             (concat (ecc-render--agent-heading node 0) "\n"
                                     (if-let* ((prompt (alist-get 'prompt input)))
                                         (concat "\n" prompt "\n")
                                       ""))
                             (ecc-node-children node)))
    (ecc-window-display-beside-session buffer session)))

;;;; Timeline

(defun ecc-session-timeline ()
  "Pick a turn by its prompt and move there."
  (interactive)
  (let* ((session (ecc-session-at-point))
         (turns (ecc-session-turns session))
         (n 0)
         (candidates (mapcar (lambda (turn)
                               (cons (format "%2d  %s" (cl-incf n)
                                             (ecc--truncate (or (ecc-turn-prompt turn)
                                                                (ecc-turn-label turn)
                                                                "(resumed)")
                                                            70))
                                     turn))
                             turns)))
    (unless candidates
      (user-error "No turn yet"))
    (let* ((choice (completing-read "Turn: " (mapcar #'car candidates) nil t))
           (turn (cdr (assoc choice candidates))))
      (unless (and turn (ecc-render-node-bounds (ecc-turn-id turn)))
        (user-error "That turn is not drawn"))
      (ecc-render-goto-id (ecc-turn-id turn)))))

;;;; Extraction (f)

(defun ecc-session--code-block-around-point (id)
  "Return the fenced code block of the node ID that contains point, or nil.
The buffer text is used, so the indentation the renderer added is
stripped from every line."
  (let* ((bounds (ecc-render-node-bounds id))
         (start (car bounds))
         (end (cdr bounds))
         (fence (concat "^\\([ \t]*\\)" (substring ecc-markdown-fence-regexp 1))))
    (save-excursion
      (let ((here (line-beginning-position)))
        (goto-char here)
        (end-of-line)
        (when (re-search-backward fence start t)
          (let ((indent (match-string 1)))
            (forward-line 1)
            (let ((body-start (point)))
              (when (and (re-search-forward fence end t)
                         (>= (line-beginning-position) here))
                (let ((body (buffer-substring-no-properties
                             body-start (line-beginning-position))))
                  (replace-regexp-in-string
                   (concat "^" (regexp-quote indent)) "" body))))))))))

(defun ecc-session-copy-at-point ()
  "Copy the code block at point, or else the whole assistant reply."
  (interactive)
  (let* ((node (ecc-chat-node-at-point))
         (text (cond
                ((null node) nil)
                ((eq (ecc-node-type node) 'text)
                 (or (ecc-session--code-block-around-point (ecc-node-id node))
                     (ecc-model-node-get node 'text)))
                ((memq (ecc-node-type node) '(tool agent))
                 (ecc-render--result-text (ecc-model-node-get node 'result)))
                (t (ecc-model-node-get node 'text)))))
    (unless (and text (not (string-empty-p text)))
      (user-error "Nothing to copy here"))
    (kill-new text)
    (message "Copied %d characters" (length text))))

(defun ecc-session--markdown-node (node depth)
  "Return NODE as Markdown, indented by DEPTH list levels."
  (let ((pad (make-string (* 2 depth) ?\s)))
    (pcase (ecc-node-type node)
      ('text (concat (ecc-model-node-get node 'text) "\n\n"))
      ('thinking (let ((text (string-trim (or (ecc-model-node-get node 'text) ""))))
                   (if (string-empty-p text) ""
                     (concat "<details><summary>Thinking</summary>\n\n" text
                             "\n\n</details>\n\n"))))
      ('step (concat (mapconcat (lambda (child)
                                  (ecc-session--markdown-node child depth))
                                (ecc-node-children node) "")
                     "\n"))
      ('tool (format "%s- `%s` %s\n" pad
                     (ecc-model-node-get node 'name)
                     (ecc-render-tool-summary (ecc-model-node-get node 'name)
                                              (ecc-model-node-get node 'input))))
      ('agent (concat (format "%s- Agent `%s`\n" pad
                              (or (ecc-model-node-get node 'agent-type) "Agent"))
                      (mapconcat (lambda (child)
                                   (ecc-session--markdown-node child (1+ depth)))
                                 (ecc-node-children node) "")))
      ((or 'permission 'question 'plan)
       (let ((request (ecc-model-node-get node 'request)))
         (format "%s- %s: %s — %s\n\n" pad (ecc-node-type node)
                 (if request (ecc-request-tool-name request) "?")
                 (ecc-node-status node))))
      ('system (if (eq (ecc-model-node-get node 'kind) 'prompt)
                   (format "%s> %s\n\n" pad
                           (string-replace "\n" (concat "\n" pad "> ")
                                           (or (ecc-model-node-get node 'text) "")))
                 ""))
      (_ ""))))

(defun ecc-session--markdown-turn-end (turn)
  "Return the line that closes TURN in Markdown: how it ended, what it cost.
It is the turn's own cost (`ecc-model-result-cost'), not the
`total_cost_usd' of its result, which is the running total of the CLI;
a cost that is not known is left out.  Nothing for a turn without a
result."
  (when-let* ((result (ecc-turn-result turn)))
    (concat "_" (or (alist-get 'stop_reason result) "?")
            (when-let* ((cost (ecc-turn-cost turn)))
              (format " · $%.4f" cost))
            "_\n\n")))

(defun ecc-session-export-markdown-string (session)
  "Return the transcript of SESSION as Markdown."
  (concat
   (format "# %s\n\n" (ecc-session-name session))
   (mapconcat
    (lambda (turn)
      (concat (format "## %s\n\n" (or (ecc-turn-prompt turn)
                                           (ecc-turn-label turn)
                                           "(resumed)"))
              (mapconcat (lambda (node) (ecc-session--markdown-node node 0))
                         (ecc-turn-children turn) "")
              (ecc-session--markdown-turn-end turn)))
    (ecc-session-turns session) "")))

(defun ecc-session-export-markdown (file)
  "Save the transcript as Markdown in FILE."
  (interactive
   (list (read-file-name "Export to: " nil nil nil
                         (format "%s.md" (ecc-session-name (ecc-session-at-point))))))
  (let ((session (ecc-session-at-point)))
    (with-temp-file file
      (insert (ecc-session-export-markdown-string session)))
    (message "Saved to %s" (abbreviate-file-name file))))

;;;; Keys

(defun ecc-chat-follow-link (event)
  "Open the link clicked on in the transcript.
The point goes where EVENT was.  On a link, text drawn with a
`mouse-face\=', `ecc-session-visit\=' opens it as RET would; anywhere
else -- a line of a diff, the heading of a call -- nothing more is done,
and RET is the way to open it."
  (interactive "e")
  (mouse-set-point event)
  (when (get-char-property (point) 'mouse-face)
    (ecc-session-visit)))

(defvar ecc-session-chat-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'ecc-session-interrupt)
    (define-key map (kbd "C-c C-e") #'ecc-session-export-markdown)
    map)
  "The keys of the session in a chat buffer, wherever point is.
A parent of `ecc-chat-mode-map', so that a key bound there wins.")

(defvar ecc-session-transcript-map
  (let ((map (make-sparse-keymap)))
    ;; RET on a call that names a file opens the file; the node laid
    ;; open, which RET was on every heading before, is `o'.
    (define-key map (kbd "RET") #'ecc-session-visit)
    (define-key map (kbd "o") #'ecc-session-show-detail)
    ;; A click follows what is drawn as a link, with a `mouse-face': a
    ;; URL, a path in a reply, a picture.  A line of a diff and the
    ;; heading of a call carry none and open on RET alone, so that a
    ;; click that only meant to put the point there does not take the
    ;; source window with it.  No link carries a keymap of its own:
    ;; these two are the whole of the mouse side.
    (define-key map [mouse-2] #'ecc-chat-follow-link)
    (define-key map [follow-link] 'mouse-face)
    (define-key map (kbd "g") #'ecc-session-refresh)
    (define-key map (kbd "L") #'ecc-session-show-log)
    (define-key map (kbd "R") #'ecc-session-resume)
    (define-key map (kbd "d") #'ecc-session-review-or-deny)
    (define-key map (kbd "T") #'ecc-session-timeline)
    (define-key map (kbd "w") #'ecc-session-copy-at-point)
    map)
  "The keys of the session in the transcript.
A parent of `ecc-chat-transcript-map', so that a key bound there wins.")

(defvar ecc-session-request-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-session-visit)
    map)
  "The keys of the session on a node that is waiting for an answer.
A parent of `ecc-request-section-map', above the transcript's keys.")

(defvar ecc-session-file-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-session-visit)
    (define-key map (kbd "d") #'ecc-session-review-file)
    map)
  "The keys of the session on a file row in the Files section.
A parent of `ecc-file-section-map', above the transcript's keys.")

(ecc-chat-add-keymap-parent ecc-chat-mode-map ecc-session-chat-map)
(ecc-chat-add-keymap-parent ecc-chat-transcript-map ecc-session-transcript-map)
(ecc-chat-add-keymap-parent ecc-request-section-map ecc-session-request-section-map)
(ecc-chat-add-keymap-parent ecc-file-section-map ecc-session-file-section-map)

(provide 'ecc-session)

;;; ecc-session.el ends here
