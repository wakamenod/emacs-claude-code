;;; ecc-prompt.el --- The prompt region of a session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; What is done with the prompt region of a session buffer (the region
;; itself belongs to `ecc-chat'): multi-line input, slash commands with
;; their completion and the two kinds that need care, the queue that
;; holds a prompt back while a turn runs, the history shared by every
;; session, the `@' references Emacs expands before sending, pasted
;; images and the editor context.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'dnd)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-hint)
(require 'ecc-window)
(require 'ecc-context)

(declare-function project-files "project" (project &optional dirs))
(declare-function project-current "project" (&optional maybe-prompt directory))

;;;; Options

(defvar ecc-prompt-history-size 200
  "Number of prompts kept in `ecc-prompt-history'.")

(defvar ecc-image-dir (expand-file-name "ecc-images" temporary-file-directory)
  "Directory the images pasted into a prompt are written to.
Each session gets a subdirectory of its own.")

(defvar ecc-image-cleanup 'on-exit
  "What becomes of the images of a session when it ends.
`on-exit' deletes the directory of the session, `never' keeps it.  The
recording refers to the files by path, so keeping them is what makes an
old conversation readable again.")

(defvar ecc-prompt-interactive-commands
  '(("/model" . ecc-prompt-model-candidates)
    ("/effort" . ecc-prompt-effort-candidates)
    ("/permissions" . nil)
    ("/config" . nil)
    ("/btw" . nil))
  "Slash commands whose argument the CLI does not spell out.
Each entry is a command name and where the argument comes from: a list
of candidates, a function called with the session that returns one, or
nil to ask for a string.  Sending one of these without an argument is
answered with a usage message, so Emacs asks for the argument first.

Only the commands the argument hint of the initialize response cannot
describe belong here.  Every command whose hint names its alternatives
\(`[on|off]\=' for /fast) is offered them without being listed, by
`ecc-prompt-argument-candidates\='.")

(defvar ecc-prompt-slash-reads-command t
  "Whether typing `/' in the prompt asks which slash command is meant.
When this is on, a slash that opens the prompt -- the only place the CLI
runs a command from -- opens `completing-read' with the commands it
named, and what is chosen is written after it.  A slash anywhere else is
only a slash; `ecc-prompt-capf\=' still completes one that starts a
word, on TAB, so corfu and company keep working as they did.  Turning
this off leaves them the only way.")

(defvar ecc-model-candidates
  '("default" "sonnet" "opus" "haiku" "fable")
  "Models offered for /model until the CLI names its own.
The initialize response carries the real catalogue in its `models\='
array -- the value to send, a display name and a description -- and
`ecc-prompt-models\=' offers that as soon as it has arrived, so this
list only has to serve a session whose CLI has not answered yet.")

(defvar ecc-effort-candidates
  '("low" "medium" "high" "xhigh" "max" "auto")
  "Effort levels offered for /effort until the CLI names its own.
The argument hint of the initialize response spells them out
\(`<low|medium|high|xhigh|max|auto>\='), and
`ecc-prompt-effort-candidates\=' reads them from there as soon as it
has arrived, so this list only has to serve a session whose CLI has
not answered yet.")

(defvar ecc-terminal-slash-commands '("doctor" "color" "reload-plugins")
  "Commands taken to belong to the terminal client until the CLI says otherwise.
The real list is `terminal_slash_commands' of system/init, but init does
not arrive until the first turn of a session has been sent \(confirmed
against the CLI), so a session that has not spoken yet would have
nothing to go on.  Whatever init reports replaces this for the rest of
the Emacs session, so the list here only has to be right about a brand
new session.

These are the commands the CLI marks `terminalOriented' and hands to a
headless client, measured against 2.1.266.  The list is now hidden as
well as annotated, so a name that does not belong here costs a command.")

(defvar ecc-prompt-hide-terminal-commands t
  "Non-nil keeps the terminal-only commands out of the candidates.
The CLI names them in `terminal_slash_commands' of system/init and says
of that field: \"Subset of slash_commands whose UX is bound to the local
terminal (e.g. exit, statusline).  Phone/remote UIs should hide these
from command menus; desktop surfaces may keep them.\" Emacs is one of
the remote UIs, so it hides them.

Only the menus are affected -- completion, the question `/' asks and
the transient menu.  A command typed out by hand is still sent, and its
answer still drawn; `ecc-prompt-warn-terminal-commands' is
what says not to expect anything of it.  Nil offers them all again.")

(defvar ecc-prompt-kept-terminal-commands '("/reload-plugins" "/doctor")
  "Terminal-only commands offered all the same.
A command the CLI calls terminal-oriented can still be worth having
here.  `/reload-plugins' makes the CLI resend its command list
\(system/commands_changed), which is Emacs's own completion being
brought up to date, so hiding it would take away something that works
\(confirmed 2026-09-06).  `/doctor' health-checks the setup and answers
in plain text, which reads here as well as anywhere.  Names carry their
slash.")

(defvar ecc-prompt-warn-terminal-commands t
  "Non-nil says so when a command belongs to the terminal client.
What is terminal-only about these is their effect, not the sending: the
CLI accepts them from a headless client and answers, but the answer is
about something Emacs does not have, such as the colour of the prompt
bar of the terminal client.  So the command is sent as it was typed and
the reply is shown; only a note in the echo area says not to expect
anything to happen here.")

;;;; The session and its settings

(defvar-local ecc-prompt--attach-context 'unset
  "Whether this buffer appends the editor context to what it sends.
`unset' means `ecc-context-attach-by-default' decides.")

(defun ecc-prompt-attach-context-p ()
  "Return non-nil when this buffer appends the editor context."
  (if (eq ecc-prompt--attach-context 'unset)
      ecc-context-attach-by-default
    ecc-prompt--attach-context))

(defun ecc-prompt-session ()
  "Return the session of this buffer, or signal an error."
  (or ecc-render--session
      (user-error "This buffer does not belong to a Claude session")))

(defun ecc-prompt--ensure-region ()
  "Move point into the prompt region unless it is there already.
Returns where the region starts."
  (let ((start (or (ecc-chat-prompt-start)
                   (user-error "This buffer has no prompt region"))))
    (unless (ecc-chat-in-prompt-p)
      (ecc-chat-goto-prompt))
    start))

;;;; History

(defvar ecc-prompt-history nil
  "Prompts sent from a prompt region, most recent first.
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
  "Put TEXT at the front of `ecc-prompt-history'."
  (let ((text (string-trim text)))
    (unless (string-empty-p text)
      (setq ecc-prompt-history (cons text (delete text ecc-prompt-history)))
      (when (and ecc-prompt-history-size
                 (> (length ecc-prompt-history) ecc-prompt-history-size))
        (setq ecc-prompt-history (seq-take ecc-prompt-history
                                           ecc-prompt-history-size))))
    ecc-prompt-history))

(defun ecc-prompt--history-show (index)
  "Replace the prompt region with entry INDEX of the history.
INDEX nil brings the draft back."
  (ecc-chat-set-draft
   (if index (nth index ecc-prompt-history) (or ecc-prompt--history-draft "")))
  (setq ecc-prompt--history-index index))

(defun ecc-prompt-history-previous ()
  "Replace the prompt region with the previous prompt sent."
  (interactive)
  (unless ecc-prompt-history
    (user-error "No history"))
  (unless ecc-prompt--history-index
    (setq ecc-prompt--history-draft (ecc-chat-draft)))
  (ecc-prompt--history-show
   (min (1- (length ecc-prompt-history))
        (if ecc-prompt--history-index (1+ ecc-prompt--history-index) 0))))

(defun ecc-prompt-history-next ()
  "Walk back towards what was being written before the history walk."
  (interactive)
  (unless ecc-prompt--history-index
    (user-error "Not walking the history"))
  (ecc-prompt--history-show
   (and (> ecc-prompt--history-index 0) (1- ecc-prompt--history-index))))

(defun ecc-prompt-resend-last (&optional session)
  "Send the last prompt again to SESSION."
  (interactive)
  (let ((text (or (car ecc-prompt-history) (user-error "No history")))
        (session (or session ecc-render--session
                     (ecc-window-resolve-session current-prefix-arg))))
    (when (y-or-n-p (format "Send again: %s? " (ecc--truncate text 40)))
      (ecc-proc-send-prompt session text)
      text)))

;;;; Images

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
Returns the file it was written to."
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
  "Insert PATH as an @ reference at point, with a space after it.
Point is moved into the prompt region first when it is not there."
  (ecc-prompt--ensure-region)
  (unless (or (bolp) (memq (char-before) '(?\s ?\t)))
    (insert " "))
  (insert "@" path " ")
  path)

(defun ecc-prompt-yank-image (mime data)
  "Save the pasted image DATA of type MIME and refer to it.
The file is passed by path rather than inline: base64 in the prompt
would be written into the recording of the conversation."
  (let ((file (ecc-prompt-save-image (ecc-prompt-session) data mime)))
    (ecc-prompt-insert-reference file)
    (message "Image saved to %s" (abbreviate-file-name file))
    file))

(defun ecc-prompt-dnd-insert (url &optional _action)
  "Insert the dropped file URL as an @ reference."
  (let ((file (if (fboundp 'dnd-get-local-file-name)
                  (or (dnd-get-local-file-name url t) url)
                url)))
    (ecc-prompt-insert-reference (expand-file-name file))))

(defun ecc-prompt-insert-image (file)
  "Insert an @ reference to the image FILE."
  (interactive "fImage: ")
  (ecc-prompt-insert-reference (expand-file-name file)))

;;;; Slash commands

(defun ecc-prompt-current-argument (session command)
  "Return what COMMAND has SESSION set to at the moment, or nil.
Only the commands that set something have an answer.  The terminal
client shows it after their description; the CLI sends a description
that is fixed text and leaves it out."
  (when session
    (pcase command
      ("/model" (ecc-prompt-current-model session))
      ("/effort" (ecc-prompt-current-effort session))
      ;; system/init reports this one outright.
      ("/fast" (alist-get 'fast_mode_state (ecc-session-init session))))))

(defun ecc-prompt--describe-command (session name command)
  "Return what is shown beside the slash command NAME of SESSION.
COMMAND is its entry in the initialize response, which carries the
argument hint and a description.  What the command has set at the
moment is added to it (`ecc-prompt-current-argument\=')."
  (let ((description (string-trim
                      (format "%s %s"
                              (or (alist-get 'argumentHint command) "")
                              (ecc--truncate (or (alist-get 'description command) "")
                                             70))))
        (current (ecc-prompt-current-argument session (concat "/" name))))
    (if current
        (string-trim (format "%s (currently %s)" description current))
      description)))

(defvar ecc-prompt-local-commands
  '(("/btw" . "Ask a side question without interrupting the running turn")
    ("/login" . "Sign in to the CLI, in a terminal of its own")
    ("/logout" . "Sign the CLI out")
    ("/auth-status" . "Say who the CLI is signed in as"))
  "Commands Emacs offers that the CLI does not name.
They are added to the list `ecc-prompt-commands\' returns, after
everything the CLI reported.  `/btw\' is one: the terminal client
catches it in its input layer, so it is in no list the CLI sends, and
Emacs answers it itself.

The three of `ecc-auth\' are there for the same reason: `slash_commands\'
carries neither `login\' nor `logout\', and `terminal_slash_commands\'
does not either (confirmed against 2.1.268, 2026-09-12), so the terminal
client is catching those in its input layer too.  What the CLI offers a
program instead is `claude auth login|logout|status\', which is what
Emacs runs.  `/auth-status\' rather than the terminal client\\='s
`/status\': the CLI names a `/status\' of its own, and shadowing it
would cost a command.")

(defun ecc-prompt-commands (session)
  "Return the slash commands of SESSION as an alist of name and description.
The initialize response is the better source because it carries a
description; the command list of system/init fills in the rest, and
`ecc-prompt-local-commands\' adds what Emacs answers on its own."
  (let ((commands nil))
    (seq-doseq (command (or (ecc-session-commands session) []))
      (let ((name (alist-get 'name command)))
        (when name
          (push (cons (concat "/" name)
                      (ecc-prompt--describe-command session name command))
                commands))))
    (seq-doseq (name (or (alist-get 'slash_commands (ecc-session-init session)) []))
      (when (and (stringp name) (not (assoc (concat "/" name) commands)))
        (push (cons (concat "/" name) "") commands)))
    (dolist (command ecc-prompt-local-commands)
      (unless (assoc (car command) commands)
        (push command commands)))
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
  "Return the commands of SESSION that belong to the terminal client.
The CLI names them in system/init as terminal_slash_commands; until that
arrives, the last list any session heard is used, and failing that
`ecc-terminal-slash-commands'."
  (let* ((reported (alist-get 'terminal_slash_commands
                              (ecc-session-init session)))
         (names (if (and reported (> (length reported) 0))
                    (append reported nil)
                  (or ecc-prompt--terminal-commands
                      ecc-terminal-slash-commands))))
    (mapcar (lambda (name) (concat "/" name))
            (seq-filter #'stringp names))))

(defun ecc-prompt-hidden-commands (session)
  "Return the commands of SESSION kept out of the menus.
The terminal-only ones the CLI named, less those
`ecc-prompt-kept-terminal-commands' asks for anyway."
  (when ecc-prompt-hide-terminal-commands
    (seq-remove (lambda (name)
                  (member name ecc-prompt-kept-terminal-commands))
                (ecc-prompt-terminal-commands session))))

(defun ecc-prompt-offered-commands (session)
  "Return the slash commands of SESSION worth offering.
`ecc-prompt-commands' is everything the CLI knows about, which is what a
description is looked up in; this is what the menus show, and it leaves
out `ecc-prompt-hidden-commands'."
  (let ((hidden (ecc-prompt-hidden-commands session)))
    (if (null hidden)
        (ecc-prompt-commands session)
      (seq-remove (lambda (command) (member (car command) hidden))
                  (ecc-prompt-commands session)))))

(defun ecc-prompt-command-name (text)
  "Return the slash command TEXT starts with, or nil."
  (when (string-match "\\`[ \t]*\\(/[^ \t\n]+\\)" text)
    (match-string 1 text)))

(defun ecc-prompt-command-argument (text)
  "Return what follows the slash command in TEXT, trimmed."
  (when (string-match "\\`[ \t]*/[^ \t\n]+\\(\\(?:.\\|\n\\)*\\)\\'" text)
    (string-trim (match-string 1 text))))

(defun ecc-prompt-models (session)
  "Return the models of SESSION as an alist of value and description.
The `models\=' array of the initialize response is the source: `value\='
is what /model takes, and the display name and the description are
what the terminal client shows beside it.  Until that answer arrives
there is only `ecc-model-candidates\='."
  (let ((models nil))
    (seq-doseq (model (or (and session (ecc-session-models session)) []))
      (when-let* ((value (alist-get 'value model)))
        (push (cons value
                    (string-trim
                     (format "%s %s"
                             (or (alist-get 'displayName model) "")
                             (ecc--truncate (or (alist-get 'description model) "")
                                            70))))
              models)))
    (or (nreverse models)
        (mapcar (lambda (name) (cons name "")) ecc-model-candidates))))

(defun ecc-prompt-model-candidates (&optional session)
  "Return the models offered for /model in SESSION."
  (mapcar #'car (ecc-prompt-models session)))

(defun ecc-prompt-command-entry (session command)
  "Return what the initialize response of SESSION says about COMMAND.
COMMAND is written with its slash.  Nil is returned for a command the
answer has not arrived for, or one that only system/init names."
  (let ((name (string-remove-prefix "/" command)))
    (seq-find (lambda (entry) (equal name (alist-get 'name entry)))
              (or (and session (ecc-session-commands session)) []))))

(defconst ecc-prompt--alternative-regexp "\\`[a-zA-Z0-9][-a-zA-Z0-9_.]*\\'"
  "What one alternative of an argument hint looks like.
A bare word.  Anything else in the list -- a placeholder to fill in
\(`<tokens>\='), a flag (`--fix\='), the leftovers of a second argument
\(`disable [<server>\=') -- says the hint is not a set of alternatives
after all.")

(defun ecc-prompt-argument-candidates (session command)
  "Return the arguments the CLI says COMMAND of SESSION takes, or nil.
The argument hint of the initialize response names the alternatives
where a command has a fixed set of them: `<low|medium|high|xhigh|max|auto>\='
for /effort, `[on|off]\=' for /fast, `consent | revoke\=' for /design.
A hint that holds anything else -- one placeholder to fill in
\(`key=value\=', `[name]\='), a mix of the two (`[auto|<tokens>]\='), or
more than one argument (`[low|...|ultra] [--fix]\=') -- describes
nothing that can be offered, and nil is returned for it."
  (when-let* ((entry (ecc-prompt-command-entry session command))
              (hint (alist-get 'argumentHint entry))
              (body (string-trim hint))
              ((string-search "|" body)))
    ;; The brackets say whether the argument may be left out, which is
    ;; not what is being asked here; only what is inside them matters.
    (when (and (> (length body) 1)
               (memq (aref body 0) '(?< ?\[))
               (memq (aref body (1- (length body))) '(?> ?\])))
      (setq body (substring body 1 -1)))
    (let ((alternatives (mapcar #'string-trim (split-string body "|" t))))
      (when (and (> (length alternatives) 1)
                 (seq-every-p (lambda (alternative)
                                (string-match-p ecc-prompt--alternative-regexp
                                                alternative))
                              alternatives))
        alternatives))))

(defun ecc-prompt-command-candidates (session command)
  "Return what SESSION offers as the argument of COMMAND, or nil.
`ecc-prompt-interactive-commands\=' answers for the commands whose
argument the CLI does not spell out; for every other command the
argument hint of the initialize response is read."
  (let ((entry (assoc command ecc-prompt-interactive-commands)))
    (if entry
        (let ((source (cdr entry)))
          (cond ((functionp source) (funcall source session))
                ((listp source) source)))
      (ecc-prompt-argument-candidates session command))))

(defun ecc-prompt-interactive-command-p (session command)
  "Non-nil when COMMAND of SESSION is asked for its argument first.
Either `ecc-prompt-interactive-commands\=' names it, or the CLI says
in its argument hint which arguments it takes, which is as good a
reason to offer them."
  (or (assoc command ecc-prompt-interactive-commands)
      (and (ecc-prompt-argument-candidates session command) t)))

(defun ecc-prompt-effort-candidates (&optional session)
  "Return the effort levels offered for /effort in SESSION."
  (or (ecc-prompt-argument-candidates session "/effort")
      ecc-effort-candidates))

(defun ecc-prompt-current-effort (session)
  "Return the effort level SESSION is set to, or nil.
Nothing in the stream reports one -- neither system/init nor an
assistant message carries it (confirmed against the CLI) -- so it is
the last /effort Emacs sent, and failing that the --effort the session
was started with.  A recorded assistant line does carry one, so an
/effort typed in the terminal of a hand-off is picked up as soon as
the follow replays an answer that was given under it."
  (or (ecc-session-last-effort session)
      (ecc-model-option session :effort nil)))

(defun ecc-prompt-current-model (session)
  "Return the display name of the model SESSION talks to, or nil.
`ecc-hint-model\=' says which one it is, either as the argument of the
last /model or as the id the CLI reports on every assistant message,
and the `models\=' array of the initialize response turns that into the
name the terminal client shows.  The name stands in for itself when
the CLI has not sent the array yet."
  (when-let* ((model (ecc-hint-model session))
              (models (or (and session (ecc-session-models session)) [])))
    (or (seq-some (lambda (entry)
                    (and (equal model (alist-get 'value entry))
                         (alist-get 'displayName entry)))
                  models)
        ;; `default' resolves to the model it stands for, so it would
        ;; answer for that model as well as for itself; only an entry
        ;; that names a model is asked about a resolved id.
        (seq-some (lambda (entry)
                    (and (not (equal "default" (alist-get 'value entry)))
                         (equal model (alist-get 'resolvedModel entry))
                         (alist-get 'displayName entry)))
                  models)
        model)))

(defun ecc-prompt-read-argument (command &optional session)
  "Ask for the argument of COMMAND, an interactive slash command.
The candidates of SESSION are offered where the command has any.  Nil is
returned when the user leaves it empty, which sends the command as it
was typed."
  (let* ((candidates (ecc-prompt-command-candidates session command))
         (current (ecc-prompt-current-argument session command))
         (prompt (if current
                     (format "%s (currently %s): " command current)
                   (format "%s: " command)))
         (answer (if candidates
                     (completing-read prompt candidates nil nil)
                   (read-string (format "Argument for %s (empty sends it as is): " command)))))
    (unless (string-empty-p (string-trim answer))
      (string-trim answer))))

(defun ecc-prompt-prepare-command (session text)
  "Return TEXT ready to send to SESSION, having dealt with its slash command.
A command only the terminal client of SESSION can run is reported, and
one that opens a menu there is asked for its argument."
  (let ((command (ecc-prompt-command-name text)))
    (cond
     ((null command) text)
     (t
      (when (and ecc-prompt-warn-terminal-commands
                 (member command (ecc-prompt-terminal-commands session)))
        (message "%s is a terminal UI command; nothing of it shows in Emacs, but the answer does"
                 command))
      (if (and (ecc-prompt-interactive-command-p session command)
               (string-empty-p (or (ecc-prompt-command-argument text) "")))
          (if-let* ((argument (ecc-prompt-read-argument command session)))
              (concat (string-trim text) " " argument)
            text)
        text)))))

;;;; The @ references

(defconst ecc-prompt-reference-regexp
  "@\\([^][ \t\n\r\"\'`,;()]+\\)"
  "Regexp matching an @ reference in a prompt.
The line range of `@file:10-40' is part of the match; it is taken
apart by `ecc-prompt-split-reference' rather than by the regexp,
because the end of a path cannot be found with a syntax table that
depends on the major mode of the session buffer.  A reference that
names something Emacs knows rather than a path is cut short of the
match by `ecc-prompt--next-reference'.")

(defconst ecc-prompt-special-references '("region" "diagnostics" "cursor")
  "The @ references that name what Emacs is looking at, not a path.
`ecc-prompt--expansion' reads them from the source buffer.")

(defun ecc-prompt--next-reference (text start)
  "Return (BEG END TOKEN) for the first @ reference of TEXT from START.
A special reference ends at its own name when what follows it is not
ASCII, so that a particle written straight after it is not taken for the
rest of a path: in a Japanese sentence `@region' is followed by a letter
rather than a space, and the whole clause was being read as one filename.
An ASCII letter does go on with the path, which leaves `@regions/list.py'
the file it looks like."
  (when (string-match ecc-prompt-reference-regexp text start)
    (let* ((beg (match-beginning 0))
           (body (match-string 1 text))
           (special (seq-find
                     (lambda (name)
                       (and (string-prefix-p name body)
                            (or (= (length name) (length body))
                                (>= (aref body (length name)) 128))))
                     ecc-prompt-special-references)))
      (if special
          (list beg (+ beg 1 (length special)) (concat "@" special))
        (list beg (match-end 0) (match-string 0 text))))))

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

(defun ecc-prompt--expansion (token source &optional root)
  "Return (LABEL . BLOCK) for the reference TOKEN, or nil to leave it alone.
SOURCE is the buffer @region, @cursor and @diagnostics read from, and
ROOT is where the CLI that reads the label stands.  A plain @path is
left alone: the CLI resolves that one itself."
  (pcase-let ((`(,path ,start ,end) (ecc-prompt-split-reference token)))
    (cond
     ((equal path "region")
      ;; The region of SOURCE if it still has one, and otherwise
      ;; whatever region is left on the screen or was last seen: the
      ;; mark of the buffer the user came from does not always live as
      ;; far as the send.
      (when-let* ((region (or (ecc-window-buffer-region source)
                              (ecc-window-active-region)))
                  (context (ecc-context-capture
                            :buffer (nth 0 region)
                            :region (cons (nth 1 region) (nth 2 region))
                            :root root)))
        (when (plist-get context :text)
          (ecc-prompt--block context))))
     ((equal path "cursor")
      (when-let* ((buffer (or (and (buffer-live-p source) source)
                              (ecc-window-context-buffer)))
                  (context (ecc-context-cursor buffer root)))
        (when (not (string-empty-p (string-trim (or (plist-get context :text) ""))))
          (ecc-prompt--block context))))
     ((equal path "diagnostics")
      (when-let* ((buffer (or (and (buffer-live-p source) source)
                              (ecc-window-context-buffer)))
                  (block (ecc-context-diagnostics-block buffer)))
        (cons (format "Diagnostics: `%s`" (ecc-context-path buffer root))
              block)))
     (start
      (when-let* ((context (ecc-context-file-range path start end)))
        (ecc-prompt--block context))))))

(defvar ecc-prompt-last-attachments nil
  "Labels of the @ references the last expansion appended.")

(defvar ecc-prompt-last-skipped nil
  "Special @ references the last expansion had nothing to put in place of.
A `@region' with no active region is one: it is sent as it stands, and
`ecc-prompt-send' says so rather than leaving the user to find out from
the answer.")

(defun ecc-prompt-expand-references (text &optional source root)
  "Return TEXT with its @ references expanded.
A line range, @region, @cursor and @diagnostics are replaced by a short
label and their content is appended as a quote block; a plain @path is
left for the CLI to resolve.  SOURCE is the buffer to read the region,
the cursor and the diagnostics from, and ROOT is what the paths of the
labels are relative to.  Two references to the same thing share the one
block.  What was appended, and which special reference had nothing to
append, are left in `ecc-prompt-last-attachments' and
`ecc-prompt-last-skipped'."
  (let ((source (or source (ecc-window-last-source-buffer)))
        (blocks nil)
        (skipped nil)
        (result text)
        (start 0)
        (reference nil))
    (while (setq reference (ecc-prompt--next-reference result start))
      (pcase-let ((`(,beg ,finish ,token) reference))
        (let ((expansion (ecc-prompt--expansion token source root)))
          (cond
           (expansion
            (setq result (concat (substring result 0 beg)
                                 (car expansion)
                                 (substring result finish))
                  start (+ beg (length (car expansion))))
            ;; The label stands wherever it was written, but one quote
            ;; block says it: two @region in a sentence are one region.
            (unless (member expansion blocks)
              (push expansion blocks)))
           (t
            (when (member (substring token 1) ecc-prompt-special-references)
              (push token skipped))
            (setq start finish))))))
    (setq ecc-prompt-last-attachments (mapcar #'car (reverse blocks))
          ecc-prompt-last-skipped (nreverse skipped))
    (if (null blocks)
        result
      (concat result "\n\n"
              (mapconcat (lambda (block)
                           (format "---\n%s\n%s" (car block) (cdr block)))
                         (nreverse blocks) "\n\n")))))

;;;; Completion

(defun ecc-prompt--annotator (commands terminal)
  "Return the function that annotates a slash command candidate.
COMMANDS is the alist of `ecc-prompt-commands\=' and TERMINAL the list
of `ecc-prompt-terminal-commands\='; a command only the terminal client
can run says so, and the description of the initialize
response follows."
  (lambda (candidate)
    (let ((description (cdr (assoc candidate commands))))
      (concat (when (member candidate terminal) "  terminal UI")
              (unless (or (null description)
                          (string-empty-p description))
                (concat "  " description))))))

(defun ecc-prompt-command-bounds ()
  "Return (START . END) of the slash command word before point, or nil.
A word is one when the slash that opens it follows whitespace or opens
the prompt region, which is what the terminal client completes: it
answers `please run /co\=' with `/copy\=' but leaves `src/fo\=' and
`a/co\=' alone (confirmed 2026-09-09).  Whether the CLI would run it is
another matter -- only the command the prompt opens with is run -- so
this is for the completion, not for the sending."
  (when-let* (((ecc-chat-in-prompt-p))
              (region (ecc-chat-prompt-start)))
    (save-excursion
      (let ((end (point))
            (limit (max region (line-beginning-position))))
        (skip-chars-backward "^ \t" limit)
        (when (eq (char-after (point)) ?/)
          (cons (point) end))))))

(defun ecc-prompt-capf ()
  "Complete a slash command at point.
A word that starts with a slash is completed wherever it stands in the
prompt region, as the terminal client
does (`ecc-prompt-command-bounds\=').  What is offered leaves the
terminal-only commands out \(`ecc-prompt-offered-commands\=')."
  (when-let* ((session ecc-render--session)
              (bounds (ecc-prompt-command-bounds)))
    (let ((commands (ecc-prompt-offered-commands session)))
      (list (car bounds) (cdr bounds) (mapcar #'car commands)
            :exclusive 'no
            :annotation-function
            (ecc-prompt--annotator
             commands (ecc-prompt-terminal-commands session))))))

(defun ecc-prompt-read-command (session)
  "Ask which slash command of SESSION is meant, and return it, or nil.
The name is returned with its slash.  Nil is the answer when nothing
was chosen -- an empty answer, a bare slash, or a `C-g\=' -- which leaves
the slash that was typed alone.  The terminal-only commands
are not offered, but one typed out by hand is still accepted."
  (let* ((commands (ecc-prompt-offered-commands session))
         (annotate (ecc-prompt--annotator
                    commands (ecc-prompt-terminal-commands session)))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata (category . ecc-slash-command)
                                 (annotation-function . ,annotate))
                    (complete-with-action action (mapcar #'car commands)
                                          string predicate))))
         ;; A command the CLI has not named is still worth sending, so
         ;; the answer does not have to be one of the candidates.
         (answer (condition-case nil
                     (completing-read "Slash command: " table nil nil "/")
                   (quit nil))))
    (when answer
      (let ((name (string-trim answer)))
        (unless (member name '("" "/"))
          name)))))

(defconst ecc-prompt-at-specials
  '(("@region" . "Send the region, quoted")
    ("@cursor" . "Send the line the cursor is on, with its neighbours")
    ("@diagnostics" . "Send the diagnostics of this file"))
  "The @ references that are not files.")

(defun ecc-prompt-project-files (session)
  "Return the files of the project of SESSION, relative to its root."
  (let* ((root (ecc-session-project-root session))
         (project (and root (project-current nil root))))
    (when project
      (let ((root (expand-file-name root)))
        (mapcar (lambda (file) (file-relative-name file root))
                (project-files project))))))

(defun ecc-prompt-at-capf ()
  "Complete an @ reference at point."
  (when-let* ((session ecc-render--session)
              (region (ecc-chat-prompt-start)))
    (save-excursion
      (let ((end (point)))
        (when (re-search-backward "@[^ \t\n]*\\=" (max region (line-beginning-position)) t)
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
  "Turn the editor context of this session buffer on or off."
  (interactive)
  (setq ecc-prompt--attach-context (not (ecc-prompt-attach-context-p)))
  (message "Attaching the editor context is %s"
           (if ecc-prompt--attach-context "on" "off")))

(defun ecc-prompt-prepare-text (session text &optional source attach)
  "Return TEXT as it should be sent for SESSION.
The slash command is dealt with first, then the @ references are
expanded, then the editor context of SOURCE is appended when ATTACH is
non-nil.  The paths of the labels are relative to the project of
SESSION, which is where the CLI reading them stands."
  (let* ((root (ecc-window-project-root (ecc-session-project-root session)))
         (text (ecc-prompt-expand-references
                (ecc-prompt-prepare-command session text) source root)))
    (if attach
        (concat text (or (ecc-context-block source root) ""))
      text)))

(defun ecc-prompt--attachment-report ()
  "Return what to add to the message of a send about its @ references.
The empty string when the prompt carried none: what Emacs attached is
worth a word, because the labels of the quote blocks are all the user
sees of it, and a `@region' that expanded to nothing is worth more
."
  (concat
   (when ecc-prompt-last-attachments
     (format "; attached %s" (mapconcat #'identity ecc-prompt-last-attachments ", ")))
   (when ecc-prompt-last-skipped
     (format "; %s had nothing to send and went as it stands"
             (mapconcat #'identity ecc-prompt-last-skipped ", ")))))

(defvar ecc-prompt-intercept-functions nil
  "Functions given a session and a draft before the draft is sent.
The first one to return non-nil takes the draft: nothing is sent to the
CLI, and `ecc-prompt-send\' returns `intercepted\'.  The draft is
emptied and remembered either way, so that a typo can be brought back
with \\[ecc-prompt-history-previous].

Only a draft the CLI is not meant to see belongs here.  The side
question is the one there is: `/btw\' is not a slash
command, and sending it would put it in the conversation it is supposed
to be asked beside.")

(cl-defun ecc-prompt-send ()
  "Send the prompt region, or queue it while a turn runs.
A draft one of `ecc-prompt-intercept-functions\' takes is not sent at
all.  The region is emptied either way; what was sent goes into the
history."
  (interactive)
  (let* ((session (ecc-prompt-session))
         (raw (string-trim (ecc-chat-draft))))
    (when (string-empty-p raw)
      (user-error "Prompt is empty"))
    (when (run-hook-with-args-until-success
           'ecc-prompt-intercept-functions session raw)
      (ecc-prompt-history-add raw)
      (setq ecc-prompt--history-index nil
            ecc-prompt--history-draft nil)
      (ecc-chat-clear-draft)
      (cl-return-from ecc-prompt-send 'intercepted))
    (let* ((source (ecc-window-last-source-buffer))
           (text (ecc-prompt-prepare-text session raw source
                                          (ecc-prompt-attach-context-p)))
           (outcome (ecc-proc-send-prompt session text)))
      (ecc-prompt-history-add raw)
      (setq ecc-prompt--history-index nil
            ecc-prompt--history-draft nil)
      (ecc-chat-clear-draft)
      (if (eq outcome 'sent)
          (message "Sent%s" (ecc-prompt--attachment-report))
        ;; A turn somebody started from a phone queues the prompt just
        ;; the same, and the reason is worth saying: nothing on screen
        ;; would otherwise explain why this was not sent. The queue
        ;; holds the text with its blocks already in it, so what was
        ;; attached belongs in the same message.
        (message "%s; queued at position %d%s"
                 (if (ecc-model-remote-turn-p (ecc-session-current-turn session))
                     "A turn started from Remote Control is running"
                   "A turn is running")
                 outcome (ecc-prompt--attachment-report)))
      outcome)))

(defun ecc-prompt-clear ()
  "Empty the prompt region."
  (interactive)
  (ecc-chat-clear-draft))

(defun ecc-prompt-show-queue ()
  "Show the prompts waiting to be sent."
  (interactive)
  (let ((queue (ecc-session-input-queue (ecc-prompt-session))))
    (if (null queue)
        (message "The queue is empty")
      (message "Queue: %s"
               (mapconcat (lambda (text) (ecc--truncate text 30)) queue " | ")))))

(provide 'ecc-prompt)

;;; ecc-prompt.el ends here
