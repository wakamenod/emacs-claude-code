;;; ecc-inline.el --- Ask and rewrite without leaving the code  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.16 of IMPLEMENTATION_PLAN.md, the two things one wants from
;; the source buffer rather than from a transcript.
;;
;; `ecc-inline-prompt' (FR-INLINE-1) asks a question with the region, or
;; the file, attached, and lets the answer arrive in an overlay above
;; point: Markdown formatted, cut to `ecc-inline-max-lines' with the rest
;; a keystroke away.  Behind it is a session of its own -- a fork of the
;; session of the project, or a fresh light one -- and which of the two a
;; buffer uses is asked once and remembered.
;;
;; `ecc-rewrite' (FR-INLINE-2) is the other half: a region and an
;; instruction go to one `claude -p' with a JSON schema, and what comes
;; back is the rewritten code and nothing else.  No Edit tool is
;; involved, so nothing is written behind Emacs's back: the overlay
;; shows the proposal and Emacs is what replaces the text, once the user
;; says so.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-markdown)
(require 'ecc-diff)
(require 'ecc-context)

(declare-function ecc-session-ensure-buffer "ecc-session" (session))

;;;; Settings

(defcustom ecc-inline-max-lines 12
  "Lines of an inline answer shown at once (FR-INLINE-1).
The rest is scrolled to inside the overlay."
  :type 'integer
  :group 'ecc)

(defcustom ecc-inline-binding 'ask
  "Which session an inline question of a buffer goes to (FR-INLINE-1).
`fork' branches the session of the project with --fork-session, so the
answer knows the conversation so far; `light' starts a session with no
tools, which is cheaper and knows nothing; `ask' asks the first time
and remembers the answer for that buffer."
  :type '(choice (const :tag "Ask the first time" ask)
                 (const :tag "Fork the session of the project" fork)
                 (const :tag "A light session of its own" light))
  :group 'ecc)

(defcustom ecc-inline-light-args '("--tools" "")
  "Arguments added to a light inline session.
The point of a light session is that it answers questions and touches
nothing, which is what an empty tool list says."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-rewrite-finished-action 'show-actions
  "What `ecc-rewrite' does once the rewritten code arrives (FR-INLINE-2).
`show-actions' shows it in an overlay and waits; `accept' puts it in
the buffer at once; `diff' opens the diff; `merge' leaves a conflict
for `smerge-mode' to resolve."
  :type '(choice (const show-actions) (const accept) (const diff) (const merge))
  :group 'ecc)

(defcustom ecc-rewrite-model nil
  "Model `ecc-rewrite' asks, or nil for the default of the CLI."
  :type '(choice (const :tag "The usual model" nil) string)
  :group 'ecc)

(defface ecc-inline-face
  '((t :inherit shadow :extend t))
  "Face of the text of an inline answer."
  :group 'ecc)

(defface ecc-inline-header-face
  '((t :inherit ecc-heading-face))
  "Face of the first line of an inline overlay, which says what to press."
  :group 'ecc)

;;;; The overlay both halves show their answer in

(defvar-local ecc-inline--overlay nil
  "The overlay showing an inline answer in this buffer, or nil.")

(defvar-local ecc-inline--text ""
  "The answer shown in `ecc-inline--overlay', in full.")

(defvar-local ecc-inline--offset 0
  "First line of `ecc-inline--text' the overlay shows.")

(defvar ecc-inline-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'ecc-inline-quit)
    (define-key map (kbd "r") #'ecc-inline-prompt)
    (define-key map (kbd "n") #'ecc-inline-scroll-down)
    (define-key map (kbd "p") #'ecc-inline-scroll-up)
    map)
  "Keymap in force over the line an inline answer hangs from.")

(defun ecc-inline-window (text offset)
  "Return the lines of TEXT starting at OFFSET that the overlay shows.
The answer comes back with the number of lines that were left below,
so the overlay can say there is more."
  (let* ((lines (split-string (or text "") "\n"))
         (start (max 0 (min offset (max 0 (1- (length lines))))))
         (shown (seq-take (nthcdr start lines) ecc-inline-max-lines)))
    (cons (string-join shown "\n")
          (max 0 (- (length lines) start (length shown))))))

(defun ecc-inline--string (text offset header)
  "Return what the overlay puts in front of the line, from TEXT at OFFSET.
HEADER is the first line, which says whose answer this is."
  (pcase-let* ((`(,body . ,below) (ecc-inline-window text offset))
               (hint (if (or (> below 0) (> offset 0))
                         (format "  (n/p scroll, %d more below)" below)
                       "")))
    (concat (propertize (concat header hint "\n") 'face 'ecc-inline-header-face)
            (propertize (concat (ecc-markdown-fontify body) "\n")
                        'face 'ecc-inline-face))))

(defun ecc-inline-show (text &optional header keymap)
  "Show TEXT in the inline overlay of the current buffer under HEADER.
KEYMAP, when given, is what the line the overlay hangs from answers to."
  (setq ecc-inline--text (or text ""))
  (unless (overlayp ecc-inline--overlay)
    (setq ecc-inline--overlay
          (make-overlay (line-beginning-position) (line-beginning-position)))
    (overlay-put ecc-inline--overlay 'ecc-inline t)
    (overlay-put ecc-inline--overlay 'evaporate nil))
  (overlay-put ecc-inline--overlay 'keymap (or keymap ecc-inline-map))
  (overlay-put ecc-inline--overlay 'ecc-inline-header (or header "Claude"))
  (overlay-put ecc-inline--overlay 'before-string
               (ecc-inline--string ecc-inline--text ecc-inline--offset
                                   (or header "Claude")))
  ecc-inline--overlay)

(defun ecc-inline-quit ()
  "Take the inline answer off the screen (FR-INLINE-1)."
  (interactive)
  (when (overlayp ecc-inline--overlay)
    (delete-overlay ecc-inline--overlay))
  (setq ecc-inline--overlay nil
        ecc-inline--text ""
        ecc-inline--offset 0))

(defun ecc-inline--rescroll (offset)
  "Show the answer from line OFFSET on."
  (setq ecc-inline--offset (max 0 offset))
  (when (overlayp ecc-inline--overlay)
    (overlay-put ecc-inline--overlay 'before-string
                 (ecc-inline--string
                  ecc-inline--text ecc-inline--offset
                  (or (overlay-get ecc-inline--overlay 'ecc-inline-header)
                      "Claude")))))

(defun ecc-inline-scroll-down ()
  "Show the next lines of the inline answer."
  (interactive)
  (ecc-inline--rescroll (+ ecc-inline--offset ecc-inline-max-lines)))

(defun ecc-inline-scroll-up ()
  "Show the previous lines of the inline answer."
  (interactive)
  (ecc-inline--rescroll (- ecc-inline--offset ecc-inline-max-lines)))

;;;; The session an inline question goes to (FR-INLINE-1)

(defvar-local ecc-inline--session nil
  "The session the inline questions of this buffer go to.
The session itself is kept rather than its id: the CLI hands a fork an
id of its own in system/init, and the binding must survive that.")

(defvar ecc-inline--targets (make-hash-table :test #'eq)
  "Hash of an inline session to the buffer waiting for its answer.")

(defun ecc-inline--read-binding ()
  "Ask which kind of session this buffer should use, and return it."
  (if (eq ecc-inline-binding 'ask)
      (if (y-or-n-p "Fork the session of this project (n starts a light one)? ")
          'fork
        'light)
    ecc-inline-binding))

(defun ecc-inline--parent (buffer)
  "Return the session of the project of BUFFER, or nil."
  (let ((root (with-current-buffer buffer (ecc-window-project-root))))
    (seq-find (lambda (session)
                (and (eq (ecc-session-kind session) 'own)
                     (equal (ecc-session-project-root session)
                            (file-name-as-directory (expand-file-name root)))))
              (ecc-model-sessions))))

(defun ecc-inline-session (&optional buffer)
  "Return the session the inline questions of BUFFER go to, starting it once.
The first question asks which kind of session to use and the answer is
kept for the buffer, which is what FR-INLINE-1 asks for."
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (or (and ecc-inline--session
               (ecc-model-session (ecc-session-id ecc-inline--session))
               ecc-inline--session)
          (let* ((binding (ecc-inline--read-binding))
                 (parent (and (eq binding 'fork) (ecc-inline--parent buffer)))
                 (session (ecc-inline--start (or parent buffer) binding)))
            (setq ecc-inline--session session)
            (puthash session buffer ecc-inline--targets)
            session)))))

(defun ecc-inline--start (parent binding)
  "Start the inline session of PARENT, a session or a buffer, as BINDING.
A fork gets an id of its own and branches off PARENT with
`:resume-from', so that the session it branched from stays where it
was; the CLI hands the fork its real id in system/init."
  (let* ((forkp (and (eq binding 'fork) (ecc-session-p parent)))
         (root (if (ecc-session-p parent)
                   (ecc-session-project-root parent)
                 (with-current-buffer parent (ecc-window-project-root))))
         (session (ecc-model-create-session
                   :name (format "inline: %s"
                                 (file-name-nondirectory
                                  (directory-file-name root)))
                   :project-root root
                   ;; An inline session is machinery, not a
                   ;; conversation somebody would look for on a phone,
                   ;; so it stays off the Remote Control bridge.
                   :options (append
                             (if forkp
                                 (list :resume-from (ecc-session-id parent))
                               (list :extra-args ecc-inline-light-args))
                             (list :remote-control nil)))))
    (ecc-proc-start session forkp forkp)
    session))

;;;; Asking (FR-INLINE-1)

(defun ecc-inline-question (question &optional buffer region)
  "Return QUESTION with the context of BUFFER attached (FR-CTX-1).
REGION, a cons of two positions, is the code to quote; without one the
active region, or the position of point, is what goes."
  (let ((context (ecc-context-capture :buffer (or buffer (current-buffer))
                                      :region region)))
    (concat question
            "\n\nAnswer briefly, for a reader who is looking at this code."
            (or (ecc-context-format context) ""))))

;;;###autoload
(defun ecc-inline-prompt (question)
  "Ask QUESTION about the region, or this file, and answer here (FR-INLINE-1).
The answer arrives in an overlay above point: `n' and `p' scroll it,
`r' asks something else and `q' takes it away."
  (interactive "sAsk Claude: ")
  (let ((session (ecc-inline-session)))
    (setq ecc-inline--offset 0)
    (puthash session (current-buffer) ecc-inline--targets)
    (ecc-inline-show "…" (format "Claude (%s)" (ecc-session-name session)))
    (ecc-proc-send-prompt
     session (ecc-inline-question question (current-buffer)
                                  (and (use-region-p)
                                       (cons (region-beginning) (region-end)))))
    session))

(defun ecc-inline--answer-text (session)
  "Return everything the current turn of SESSION has said."
  (let ((turn (or (ecc-session-current-turn session)
                  (car (last (ecc-session-turns session))))))
    (string-join
     (delq nil (mapcar (lambda (node)
                         (when (eq (ecc-node-type node) 'text)
                           (or (ecc-node-streaming-text node)
                               (ecc-model-node-get node 'text))))
                       (and turn (ecc-turn-children turn))))
     "")))

(defun ecc-inline--update (session &rest _)
  "Show what SESSION has said so far in the buffer that asked."
  (when-let* ((buffer (gethash session ecc-inline--targets)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (overlayp ecc-inline--overlay)
          (ecc-inline-show (ecc-inline--answer-text session)
                           (format "Claude (%s)" (ecc-session-name session))))))))

(add-hook 'ecc-stream-delta-hook #'ecc-inline--update)
(add-hook 'ecc-node-added-hook #'ecc-inline--update)
(add-hook 'ecc-node-updated-hook #'ecc-inline--update)
(add-hook 'ecc-turn-finished-hook #'ecc-inline--update)

;;;; Rewrite (FR-INLINE-2)

(defconst ecc-rewrite-schema
  "{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\"}},\
\"required\":[\"code\"]}"
  "The JSON schema the rewrite asks the CLI to answer in.")

(defun ecc-rewrite-command (&optional model)
  "Return the command line of one rewrite, asking MODEL (FR-INLINE-2).
One shot, no tools, structured output: the CLI is asked for the code
and for nothing else, and Emacs is what touches the file."
  (append (list ecc-executable "-p"
                "--output-format" "json"
                "--json-schema" ecc-rewrite-schema
                "--tools" "")
          (when-let* ((model (or model ecc-rewrite-model)))
            (list "--model" model))
          (when-let* ((settings (ecc-protocol-settings-json ecc-disabled-plugins)))
            (list "--settings" settings))))

(defun ecc-rewrite-prompt (code instruction &optional language)
  "Return what is sent to rewrite CODE as INSTRUCTION says.
LANGUAGE is the fence language of the code block."
  (concat "Rewrite the code below as the instruction says.  Answer with "
          "the whole rewritten code in the `code` field and with nothing "
          "else: no explanation, no fences, no commentary.\n\n"
          "Instruction: " instruction "\n\n"
          (format "```%s\n%s\n```\n" (or language "") code)))

(defun ecc-rewrite-extract (output)
  "Return the rewritten code in OUTPUT, the whole answer of `claude -p'.
The CLI wraps the answer in an object with a `result' field, which
with a schema holds the object the schema describes -- as an object or
as the text of one, depending on the version.  A failure signals."
  (let* ((answer (ecc--json-read output))
         (result (alist-get 'result answer)))
    (when (eq (alist-get 'is_error answer) t)
      (error "The CLI answered with an error: %s"
             (or (and (stringp result) result) "no reason given")))
    (unless result
      (error "The CLI answered without a result"))
    (let ((object (if (stringp result)
                      (condition-case nil (ecc--json-read result) (error nil))
                    result)))
      (or (and (listp object) (alist-get 'code object))
          ;; A model that ignored the schema still answered something
          ;; usable; the code is what it said.
          (and (stringp result) result)
          (error "The answer held no code")))))

(defvar-local ecc-rewrite--region nil
  "The (BEG . END) the pending rewrite is about.")

(defvar-local ecc-rewrite--code nil
  "The rewritten code that is being offered.")

(defvar ecc-rewrite-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-rewrite-accept)
    (define-key map (kbd "y") #'ecc-rewrite-accept)
    (define-key map (kbd "d") #'ecc-rewrite-diff)
    (define-key map (kbd "m") #'ecc-rewrite-merge)
    (define-key map (kbd "q") #'ecc-rewrite-cancel)
    (define-key map (kbd "n") #'ecc-inline-scroll-down)
    (define-key map (kbd "p") #'ecc-inline-scroll-up)
    map)
  "Keymap in force while a rewrite is waiting to be accepted.")

;;;###autoload
(defun ecc-rewrite (beg end instruction)
  "Rewrite the region between BEG and END as INSTRUCTION says (FR-INLINE-2).
The answer is shown; nothing is written until it is accepted."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end)
                         (read-string "Rewrite this how? "))
                 (user-error "Select the code to rewrite first")))
  (let* ((code (buffer-substring-no-properties beg end))
         (language (ecc-context-language))
         (buffer (current-buffer))
         (command (ecc-rewrite-command))
         (output "")
         (process nil))
    (setq ecc-rewrite--region (cons (copy-marker beg) (copy-marker end t)))
    (setq ecc-inline--offset 0)
    (save-excursion
      (goto-char beg)
      (ecc-inline-show "…" "Rewriting" ecc-rewrite-map))
    (ecc-log "rewrite" "%s" (mapconcat #'shell-quote-argument command " "))
    (setq process (make-process
                   :name "ecc-rewrite"
                   :command command
                   :connection-type 'pipe
                   :coding 'utf-8-unix
                   :noquery t
                   :filter (lambda (_process chunk)
                             (setq output (concat output chunk)))
                   :sentinel
                   (lambda (process _event)
                     (unless (process-live-p process)
                       (ecc-rewrite--finish buffer output)))))
    (process-send-string process (ecc-rewrite-prompt code instruction language))
    (process-send-eof process)
    process))

(defun ecc-rewrite--finish (buffer output)
  "Show what OUTPUT holds as the rewrite offered in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (condition-case error
          (let ((code (ecc-rewrite-extract output)))
            (setq ecc-rewrite--code code)
            (pcase ecc-rewrite-finished-action
              ('accept (ecc-rewrite-accept))
              ('diff (ecc-rewrite-diff))
              ('merge (ecc-rewrite-merge))
              (_ (ecc-rewrite--offer code))))
        (error
         (ecc-inline-show (error-message-string error) "Rewrite failed"
                          ecc-rewrite-map))))))

(defun ecc-rewrite--offer (code)
  "Show CODE as the rewrite that is waiting for an answer."
  (save-excursion
    (goto-char (car ecc-rewrite--region))
    (ecc-inline-show code "Rewrite: RET accepts, d diffs, m merges, q cancels"
                     ecc-rewrite-map)))

(defun ecc-rewrite--old ()
  "Return the text the pending rewrite would replace."
  (buffer-substring-no-properties (car ecc-rewrite--region)
                                  (cdr ecc-rewrite--region)))

(defun ecc-rewrite-accept ()
  "Put the rewritten code in the buffer (FR-INLINE-2)."
  (interactive)
  (unless ecc-rewrite--code (user-error "No rewrite is waiting"))
  (let ((beg (car ecc-rewrite--region))
        (end (cdr ecc-rewrite--region))
        (code ecc-rewrite--code))
    (save-excursion
      (delete-region beg end)
      (goto-char beg)
      (insert code))
    (ecc-rewrite-cancel)
    (message "Rewritten; undo puts it back")))

(defun ecc-rewrite-diff ()
  "Show what the rewrite would change, as a diff (FR-INLINE-2)."
  (interactive)
  (unless ecc-rewrite--code (user-error "No rewrite is waiting"))
  (let ((diff (ecc-diff-render (ecc-rewrite--old) ecc-rewrite--code))
        (buffer (get-buffer-create "*ecc-rewrite-diff*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert diff)
        (goto-char (point-min)))
      (special-mode))
    (display-buffer buffer)
    buffer))

(defun ecc-rewrite-merge ()
  "Leave the rewrite as a conflict for `smerge-mode' to resolve."
  (interactive)
  (unless ecc-rewrite--code (user-error "No rewrite is waiting"))
  (let ((beg (car ecc-rewrite--region))
        (old (ecc-rewrite--old))
        (code ecc-rewrite--code))
    (delete-region beg (cdr ecc-rewrite--region))
    (save-excursion
      (goto-char beg)
      (insert "<<<<<<< current\n" (string-trim-right old "\n") "\n"
              "=======\n" (string-trim-right code "\n") "\n"
              ">>>>>>> claude\n"))
    (ecc-rewrite-cancel)
    (require 'smerge-mode)
    (smerge-mode 1)
    (message "Left as a conflict; smerge-mode takes it from here")))

(defun ecc-rewrite-cancel ()
  "Forget the pending rewrite and take the overlay away."
  (interactive)
  (setq ecc-rewrite--code nil
        ecc-rewrite--region nil)
  (ecc-inline-quit))

(provide 'ecc-inline)

;;; ecc-inline.el ends here
