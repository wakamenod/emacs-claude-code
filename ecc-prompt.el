;;; ecc-prompt.el --- The prompt buffer of a session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Where a prompt is written and sent from.  Section 6.2 of
;; IMPLEMENTATION_PLAN.md: multi-line input (FR-INP-1), slash commands
;; with their completion and the two kinds that need care (FR-INP-2, 3,
;; 4, 5), the queue that holds a prompt back while a turn runs
;; (FR-INP-6), the history shared by every session (FR-INP-7), the `@'
;; references Emacs expands before sending (FR-INP-8), pasted images
;; (FR-INP-9) and the editor context (FR-CTX-1).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'dnd)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-window)
(require 'ecc-context)

(declare-function project-files "project" (project &optional dirs))
(declare-function project-current "project" (&optional maybe-prompt directory))

;;;; Options

(defcustom ecc-prompt-history-size 200
  "Number of prompts kept in `ecc-prompt-history' (FR-INP-7)."
  :type 'integer
  :group 'ecc)

(defcustom ecc-image-dir (expand-file-name "ecc-images" temporary-file-directory)
  "Directory the images pasted into a prompt are written to (FR-INP-9).
Each session gets a subdirectory of its own."
  :type 'directory
  :group 'ecc)

(defcustom ecc-image-cleanup 'on-exit
  "What becomes of the images of a session when it ends (FR-INP-9).
`on-exit' deletes the directory of the session, `never' keeps it.  The
recording refers to the files by path, so keeping them is what makes an
old conversation readable again."
  :type '(choice (const :tag "Delete when the session ends" on-exit)
                 (const :tag "Keep" never))
  :group 'ecc)

(defcustom ecc-prompt-interactive-commands
  '(("/model" . ecc-prompt-model-candidates)
    ("/effort" . ("low" "medium" "high"))
    ("/permissions" . nil)
    ("/config" . nil))
  "Slash commands that open a menu in the terminal client (FR-INP-5).
Each entry is a command name and where the argument comes from: a list
of candidates, a function returning one, or nil to ask for a string.
Sending one of these without an argument is answered with a usage
message, so Emacs asks for the argument first."
  :type '(alist :key-type string :value-type sexp)
  :group 'ecc)

(defcustom ecc-model-candidates
  '("opus" "sonnet" "haiku" "opusplan" "default")
  "Model names offered for the /model command (FR-INP-5)."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-terminal-slash-commands '("doctor" "color" "reload-plugins")
  "Commands taken to be terminal-only until the CLI says otherwise.
The real list is `terminal_slash_commands' of system/init, but init does
not arrive until the first turn of a session has been sent
\(docs/verified.md), so a session that has not spoken yet would have no
annotation to show (FR-INP-4).  Whatever init reports replaces this for
the rest of the Emacs session, so the list here only has to be right
about a brand new session."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-prompt-warn-terminal-commands t
  "Non-nil says so when a command only the terminal client can run (FR-INP-4).
The command is sent anyway: the CLI answers with a message of its own
rather than doing anything harmful."
  :type 'boolean
  :group 'ecc)

;;;; The buffer

(defvar-local ecc-prompt--session nil
  "The session this prompt buffer belongs to.")

(defvar-local ecc-prompt--attach-context nil
  "Non-nil appends the editor context to what this buffer sends.")

(defvar ecc-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ecc-prompt-send)
    (define-key map (kbd "C-c C-k") #'ecc-prompt-clear)
    (define-key map (kbd "C-c C-q") #'ecc-prompt-show-queue)
    (define-key map (kbd "C-c C-r") #'ecc-prompt-resend-last)
    (define-key map (kbd "C-c C-x") #'ecc-prompt-toggle-context)
    (define-key map (kbd "C-c C-i") #'ecc-prompt-insert-image)
    (define-key map (kbd "M-p") #'ecc-prompt-history-previous)
    (define-key map (kbd "M-n") #'ecc-prompt-history-next)
    (define-key map (kbd "C-<up>") #'ecc-prompt-history-previous)
    (define-key map (kbd "C-<down>") #'ecc-prompt-history-next)
    ;; `?' stays self-inserting in a buffer one writes prose in, so the
    ;; menu is on C-c ? here rather than on ? (NFR-10).
    (define-key map (kbd "C-c ?") #'ecc-menu)
    map)
  "Keymap of `ecc-prompt-mode'.")

(declare-function ecc-menu "ecc-transient" ())

(define-derived-mode ecc-prompt-mode text-mode "Claude-Prompt"
  "Major mode of the buffer a prompt is written in.

\\{ecc-prompt-mode-map}"
  :interactive nil
  (setq-local completion-at-point-functions
              (list #'ecc-prompt-capf #'ecc-prompt-at-capf))
  (setq-local ecc-prompt--attach-context ecc-context-attach-by-default)
  ;; An image on the clipboard is worth a file reference (FR-INP-9).
  (when (fboundp 'yank-media-handler)
    (yank-media-handler "image/.*" #'ecc-prompt-yank-image))
  (setq-local dnd-protocol-alist
              (cons '("^file:" . ecc-prompt-dnd-insert) dnd-protocol-alist))
  (visual-line-mode 1))

(defun ecc-prompt-buffer-name (name)
  "Return the name of the prompt buffer of the session called NAME."
  (format "*ecc-prompt: %s*" name))

(defun ecc-prompt-ensure-buffer (session)
  "Return the prompt buffer of SESSION, creating it if needed."
  (let ((buffer (ecc-session-prompt-buffer session)))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (ecc-prompt-buffer-name (ecc-session-name session))))
      (setf (ecc-session-prompt-buffer session) buffer)
      (with-current-buffer buffer
        (setq default-directory (or (ecc-session-project-root session)
                                    default-directory))
        (ecc-prompt-mode)
        (setq ecc-prompt--session session)))
    buffer))

(defun ecc-prompt-pop-to-buffer (session)
  "Show the prompt buffer of SESSION and select it."
  (pop-to-buffer (ecc-prompt-ensure-buffer session)))

(defun ecc-prompt-session ()
  "Return the session of this prompt buffer, or signal an error."
  (or ecc-prompt--session
      (user-error "This buffer does not belong to a Claude session")))

;;;; History (FR-INP-7)

(defvar ecc-prompt-history nil
  "Prompts sent from a prompt buffer, most recent first.
Shared by every session and kept across restarts when `savehist-mode'
is on.")

(defvar-local ecc-prompt--history-index nil
  "How far back in `ecc-prompt-history' this buffer has walked.")

(defvar-local ecc-prompt--history-draft nil
  "What the buffer held before the history walk started.")

(with-eval-after-load 'savehist
  (when (boundp 'savehist-additional-variables)
    (add-to-list 'savehist-additional-variables 'ecc-prompt-history)))

(defun ecc-prompt-history-add (text)
  "Put TEXT at the front of `ecc-prompt-history' (FR-INP-7)."
  (let ((text (string-trim text)))
    (unless (string-empty-p text)
      (setq ecc-prompt-history (cons text (delete text ecc-prompt-history)))
      (when (and ecc-prompt-history-size
                 (> (length ecc-prompt-history) ecc-prompt-history-size))
        (setq ecc-prompt-history (seq-take ecc-prompt-history
                                           ecc-prompt-history-size))))
    ecc-prompt-history))

(defun ecc-prompt--history-show (index)
  "Replace the buffer with entry INDEX of the history, or the draft at nil."
  (erase-buffer)
  (insert (if index (nth index ecc-prompt-history) (or ecc-prompt--history-draft "")))
  (setq ecc-prompt--history-index index))

(defun ecc-prompt-history-previous ()
  "Replace the buffer with the previous prompt sent (FR-INP-7)."
  (interactive)
  (unless ecc-prompt-history
    (user-error "履歴がありません"))
  (unless ecc-prompt--history-index
    (setq ecc-prompt--history-draft (buffer-string)))
  (ecc-prompt--history-show
   (min (1- (length ecc-prompt-history))
        (if ecc-prompt--history-index (1+ ecc-prompt--history-index) 0))))

(defun ecc-prompt-history-next ()
  "Walk back towards what was being written before the history walk."
  (interactive)
  (unless ecc-prompt--history-index
    (user-error "履歴を遡っていません"))
  (ecc-prompt--history-show
   (and (> ecc-prompt--history-index 0) (1- ecc-prompt--history-index))))

(defun ecc-prompt-resend-last (&optional session)
  "Send the last prompt again to SESSION (FR-INP-7)."
  (interactive)
  (let ((text (or (car ecc-prompt-history) (user-error "履歴がありません")))
        (session (or session ecc-prompt--session
                     (ecc-window-resolve-session current-prefix-arg))))
    (when (y-or-n-p (format "もう一度送りますか: %s? " (ecc--truncate text 40)))
      (ecc-proc-send-prompt session text)
      text)))

;;;; Images (FR-INP-9)

(defun ecc-session-image-dir (session)
  "Return the directory the images of SESSION are written to, creating it."
  (let ((dir (or (ecc-session-tmp-dir session)
                 (setf (ecc-session-tmp-dir session)
                       (file-name-as-directory
                        (expand-file-name (ecc-session-id session)
                                          ecc-image-dir))))))
    (make-directory dir t)
    dir))

(defun ecc-image-cleanup-session (session)
  "Delete the image directory of SESSION when the setting says so."
  (let ((dir (ecc-session-tmp-dir session)))
    (when (and (eq ecc-image-cleanup 'on-exit) dir (file-directory-p dir))
      (delete-directory dir t)
      (setf (ecc-session-tmp-dir session) nil)
      dir)))

(defun ecc-prompt--image-extension (mime)
  "Return the file extension for MIME, such as png."
  (let ((name (format "%s" mime)))
    (cond ((string-match "image/\\([a-zA-Z0-9]+\\)" name)
           (let ((type (downcase (match-string 1 name))))
             (if (equal type "jpeg") "jpg" type)))
          (t "png"))))

(defun ecc-prompt-save-image (session data mime)
  "Write DATA, an image of type MIME, into the directory of SESSION.
Returns the file it was written to (FR-INP-9)."
  (let ((file (expand-file-name
               (format "%s.%s"
                       (format-time-string "%Y%m%d-%H%M%S-%3N")
                       (ecc-prompt--image-extension mime))
               (ecc-session-image-dir session))))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert data))
    file))

(defun ecc-prompt-insert-reference (path)
  "Insert PATH as an @ reference at point, with a space after it."
  (unless (or (bolp) (memq (char-before) '(?\s ?\t)))
    (insert " "))
  (insert "@" path " ")
  path)

(defun ecc-prompt-yank-image (mime data)
  "Save the pasted image DATA of type MIME and refer to it (FR-INP-9).
The file is passed by path rather than inline: base64 in the prompt
would be written into the recording of the conversation."
  (let ((file (ecc-prompt-save-image (ecc-prompt-session) data mime)))
    (ecc-prompt-insert-reference file)
    (message "画像を %s に保存しました" (abbreviate-file-name file))
    file))

(defun ecc-prompt-dnd-insert (url &optional _action)
  "Insert the dropped file URL as an @ reference (FR-INP-9)."
  (let ((file (if (fboundp 'dnd-get-local-file-name)
                  (or (dnd-get-local-file-name url t) url)
                url)))
    (ecc-prompt-insert-reference (expand-file-name file))))

(defun ecc-prompt-insert-image (file)
  "Insert an @ reference to the image FILE (FR-INP-9)."
  (interactive "fImage: ")
  (ecc-prompt-insert-reference (expand-file-name file)))

;;;; Slash commands (FR-INP-2, 3, 4, 5)

(defun ecc-prompt-commands (session)
  "Return the slash commands of SESSION as an alist of name and description.
The initialize response is the better source because it carries a
description; the command list of system/init fills in the rest."
  (let ((commands nil))
    (seq-doseq (command (or (ecc-session-commands session) []))
      (let ((name (alist-get 'name command)))
        (when name
          (push (cons (concat "/" name)
                      (string-trim
                       (format "%s %s"
                               (or (alist-get 'argumentHint command) "")
                               (ecc--truncate (or (alist-get 'description command) "")
                                              70))))
                commands))))
    (seq-doseq (name (or (alist-get 'slash_commands (ecc-session-init session)) []))
      (when (and (stringp name) (not (assoc (concat "/" name) commands)))
        (push (cons (concat "/" name) "") commands)))
    (nreverse commands)))

(defvar ecc-prompt--terminal-commands nil
  "The terminal_slash_commands the CLI reported most recently.
The list belongs to the CLI rather than to one conversation, so the
newest answer stands in for a session that has not heard one yet.")

(defun ecc-prompt-note-terminal-commands (session)
  "Remember the terminal_slash_commands SESSION was just told about."
  (let ((reported (alist-get 'terminal_slash_commands
                             (ecc-session-init session))))
    (when (and reported (> (length reported) 0))
      (setq ecc-prompt--terminal-commands
            (seq-filter #'stringp (append reported nil))))))

(add-hook 'ecc-session-init-hook #'ecc-prompt-note-terminal-commands)

(defun ecc-prompt-terminal-commands (session)
  "Return the commands of SESSION that only the terminal client runs.
The CLI names them in system/init as terminal_slash_commands (FR-INP-4);
until that arrives, the last list any session heard is used, and failing
that `ecc-terminal-slash-commands'."
  (let* ((reported (alist-get 'terminal_slash_commands
                              (ecc-session-init session)))
         (names (if (and reported (> (length reported) 0))
                    (append reported nil)
                  (or ecc-prompt--terminal-commands
                      ecc-terminal-slash-commands))))
    (mapcar (lambda (name) (concat "/" name))
            (seq-filter #'stringp names))))

(defun ecc-prompt-command-name (text)
  "Return the slash command TEXT starts with, or nil."
  (when (string-match "\\`[ \t]*\\(/[^ \t\n]+\\)" text)
    (match-string 1 text)))

(defun ecc-prompt-command-argument (text)
  "Return what follows the slash command in TEXT, trimmed."
  (when (string-match "\\`[ \t]*/[^ \t\n]+\\(\\(?:.\\|\n\\)*\\)\\'" text)
    (string-trim (match-string 1 text))))

(defun ecc-prompt-model-candidates ()
  "Return the models offered for /model (FR-INP-5)."
  ecc-model-candidates)

(defun ecc-prompt-read-argument (command)
  "Ask for the argument of COMMAND, an interactive slash command (FR-INP-5).
Nil is returned when the user leaves it empty, which sends the command
as it was typed."
  (let* ((source (cdr (assoc command ecc-prompt-interactive-commands)))
         (candidates (cond ((functionp source) (funcall source))
                           ((listp source) source)))
         (answer (if candidates
                     (completing-read (format "%s: " command) candidates nil nil)
                   (read-string (format "%s の引数（空で送信）: " command)))))
    (unless (string-empty-p (string-trim answer))
      (string-trim answer))))

(defun ecc-prompt-prepare-command (session text)
  "Return TEXT ready to send to SESSION, having dealt with its slash command.
A command only the terminal client of SESSION can run is reported
\(FR-INP-4), and one that opens a menu there is asked for its argument
\(FR-INP-5)."
  (let ((command (ecc-prompt-command-name text)))
    (cond
     ((null command) text)
     (t
      (when (and ecc-prompt-warn-terminal-commands
                 (member command (ecc-prompt-terminal-commands session)))
        (message "%s は端末専用のコマンドです。CLI の返答をそのまま表示します" command))
      (if (and (assoc command ecc-prompt-interactive-commands)
               (string-empty-p (or (ecc-prompt-command-argument text) "")))
          (if-let* ((argument (ecc-prompt-read-argument command)))
              (concat (string-trim text) " " argument)
            text)
        text)))))

;;;; The @ references (FR-INP-8)

(defconst ecc-prompt-reference-regexp
  "@\\([^][ \t\n\r\"\'`,;()]+\\)"
  "Regexp matching an @ reference in a prompt.
The line range of `@file:10-40' is part of the match; it is taken
apart by `ecc-prompt-split-reference' rather than by the regexp,
because the end of a path cannot be found with a syntax table that
depends on the major mode of the prompt buffer.")

(defun ecc-prompt-split-reference (token)
  "Return (PATH START END) for the @ reference TOKEN.
START and END are nil unless TOKEN ends in a line range.  Punctuation
that ends a sentence rather than a path is dropped."
  (let ((body (substring token 1)))
    (while (and (> (length body) 1)
                (memq (aref body (1- (length body))) '(?. ?, ?: ?\; ?! ??)))
      (setq body (substring body 0 (1- (length body)))))
    (if (string-match "\\`\\(.+\\):\\([0-9]+\\)-\\([0-9]+\\)\\'" body)
        (list (match-string 1 body)
              (string-to-number (match-string 2 body))
              (string-to-number (match-string 3 body)))
      (list body nil nil))))

(defun ecc-prompt--block (context)
  "Return (LABEL . BLOCK) for CONTEXT, a plist of `ecc-context-capture'."
  (cons (ecc-context-location context)
        (format "```%s\n%s\n```" (plist-get context :language)
                (plist-get context :text))))

(defun ecc-prompt--expansion (token source)
  "Return (LABEL . BLOCK) for the reference TOKEN, or nil to leave it alone.
SOURCE is the buffer @region and @diagnostics read from.  A plain
@path is left alone: the CLI resolves that one itself."
  (pcase-let ((`(,path ,start ,end) (ecc-prompt-split-reference token)))
    (cond
     ((equal path "region")
      (when-let* ((context (ecc-context-capture :buffer source)))
        (when (plist-get context :text)
          (ecc-prompt--block context))))
     ((equal path "diagnostics")
      (when (buffer-live-p source)
        (when-let* ((block (ecc-context-diagnostics-block source)))
          (cons (format "診断: `%s`" (ecc-context-path source)) block))))
     (start
      (when-let* ((context (ecc-context-file-range path start end)))
        (ecc-prompt--block context))))))

(defun ecc-prompt-expand-references (text &optional source)
  "Return TEXT with its @ references expanded (FR-INP-8).
A line range, @region and @diagnostics are replaced by a short label
and their content is appended as a quote block; a plain @path is left
for the CLI to resolve.  SOURCE is the buffer to read the region and
the diagnostics from."
  (let ((source (or source (ecc-window-last-source-buffer)))
        (blocks nil)
        (result text)
        (start 0))
    (while (string-match ecc-prompt-reference-regexp result start)
      (let* ((token (match-string 0 result))
             (beg (match-beginning 0))
             (finish (match-end 0))
             (expansion (ecc-prompt--expansion token source)))
        (if (null expansion)
            (setq start finish)
          (setq result (concat (substring result 0 beg)
                               (car expansion)
                               (substring result finish))
                start (+ beg (length (car expansion))))
          (push expansion blocks))))
    (if (null blocks)
        result
      (concat result "\n\n"
              (mapconcat (lambda (block)
                           (format "---\n%s\n%s" (car block) (cdr block)))
                         (nreverse blocks) "\n\n")))))

;;;; Completion (FR-INP-3, FR-INP-8)

(defun ecc-prompt-capf ()
  "Complete a slash command at point (FR-INP-3, FR-INP-4).
Only the first word of a line that starts with a slash is completed,
which is where the CLI looks for a command."
  (when-let* ((session ecc-prompt--session))
    (let ((start (line-beginning-position))
          (end (point)))
      (when (and (eq (char-after start) ?/)
                 (not (string-match-p "[ \t\n]" (buffer-substring-no-properties
                                                 start end))))
        (let ((commands (ecc-prompt-commands session))
              (terminal (ecc-prompt-terminal-commands session)))
          (list start end (mapcar #'car commands)
                :exclusive 'no
                :annotation-function
                (lambda (candidate)
                  (let ((description (cdr (assoc candidate commands))))
                    (concat (when (member candidate terminal) "  端末専用")
                            (unless (or (null description)
                                        (string-empty-p description))
                              (concat "  " description)))))))))))

(defconst ecc-prompt-at-specials
  '(("@region" . "選択範囲を引用して送る")
    ("@diagnostics" . "このファイルの診断を送る"))
  "The @ references that are not files (FR-INP-8).")

(defun ecc-prompt-project-files (session)
  "Return the files of the project of SESSION, relative to its root."
  (let* ((root (ecc-session-project-root session))
         (project (and root (project-current nil root))))
    (when project
      (let ((root (expand-file-name root)))
        (mapcar (lambda (file) (file-relative-name file root))
                (project-files project))))))

(defun ecc-prompt-at-capf ()
  "Complete an @ reference at point (FR-INP-8)."
  (when-let* ((session ecc-prompt--session))
    (save-excursion
      (let ((end (point)))
        (when (re-search-backward "@[^ \t\n]*\\=" (line-beginning-position) t)
          (let ((start (point)))
            (list start end
                  (completion-table-dynamic
                   (lambda (_string)
                     (append (mapcar #'car ecc-prompt-at-specials)
                             (mapcar (lambda (file) (concat "@" file))
                                     (ecc-prompt-project-files session)))))
                  :exclusive 'no
                  :annotation-function
                  (lambda (candidate)
                    (when-let* ((doc (cdr (assoc candidate ecc-prompt-at-specials))))
                      (concat "  " doc))))))))))

;;;; Sending

(defun ecc-prompt-toggle-context ()
  "Turn the editor context of this prompt buffer on or off (FR-CTX-1)."
  (interactive)
  (setq ecc-prompt--attach-context (not ecc-prompt--attach-context))
  (message "コンテキストの添付を%sにしました"
           (if ecc-prompt--attach-context "オン" "オフ")))

(defun ecc-prompt-prepare-text (session text &optional source attach)
  "Return TEXT as it should be sent for SESSION.
The slash command is dealt with first (FR-INP-4, 5), then the @
references are expanded (FR-INP-8), then the editor context of SOURCE
is appended when ATTACH is non-nil (FR-CTX-1)."
  (let ((text (ecc-prompt-expand-references
               (ecc-prompt-prepare-command session text) source)))
    (if attach
        (concat text (or (ecc-context-block source) ""))
      text)))

(defun ecc-prompt-send ()
  "Send the buffer as a prompt, or queue it while a turn runs (FR-INP-1, 6)."
  (interactive)
  (let* ((session (ecc-prompt-session))
         (raw (string-trim (buffer-string))))
    (when (string-empty-p raw)
      (user-error "プロンプトが空です"))
    (let* ((source (ecc-window-last-source-buffer))
           (text (ecc-prompt-prepare-text session raw source
                                          ecc-prompt--attach-context))
           (outcome (ecc-proc-send-prompt session text)))
      (ecc-prompt-history-add raw)
      (setq ecc-prompt--history-index nil
            ecc-prompt--history-draft nil)
      (erase-buffer)
      (if (eq outcome 'sent)
          (message "送信しました")
        (message "実行中のターンがあります。キューの %d 件目に入れました" outcome))
      outcome)))

(defun ecc-prompt-clear ()
  "Empty the prompt buffer."
  (interactive)
  (erase-buffer))

(defun ecc-prompt-show-queue ()
  "Show the prompts waiting to be sent (FR-INP-6)."
  (interactive)
  (let ((queue (ecc-session-input-queue (ecc-prompt-session))))
    (if (null queue)
        (message "キューは空です")
      (message "キュー: %s"
               (mapconcat (lambda (text) (ecc--truncate text 30)) queue " | ")))))

(provide 'ecc-prompt)

;;; ecc-prompt.el ends here
