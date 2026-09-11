;;; ecc-core.el --- Core utilities for the ecc Claude Code client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Customization group, launch options, logging, UUID generation and the
;; thin JSON wrappers shared by every other `ecc-' module.
;;
;; This file must not depend on any other `ecc-' module.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup ecc nil
  "Run the Claude Code CLI from Emacs."
  :group 'tools
  :prefix "ecc-")

;;;; Launch options

(defcustom ecc-executable "claude"
  "Name of, or path to, the Claude Code CLI executable."
  :type 'string)

;; There is deliberately no `ecc-model' (decided 2026-09-08). The model
;; belongs to the Claude Code settings, and a session that wants one of
;; its own carries it in `:model\=' among its options.

(defcustom ecc-permission-mode nil
  "Initial permission mode passed with --permission-mode.
Nil leaves the CLI default in place."
  :type '(choice (const :tag "CLI default" nil)
                 (const "default") (const "acceptEdits") (const "plan")
                 (const "auto") (const "bypassPermissions")))

(defvar ecc-permission-mode-functions nil
  "Functions run once a session has switched permission mode.
Each is called with the session and the mode the CLI acknowledged.
The switch is a control request, so its answer arrives from the
process filter rather than from the command that asked for it, and
this is how what shows the mode -- the footer of `ecc-chat' -- hears
about it.")

;; There is deliberately no `ecc-remote-control' setting (decided
;; 2026-09-10).  Remote Control belongs to the Claude Code settings
;; (`remoteControlAtStartup' at user scope) and this package follows
;; them: the initialize response says whether this session should turn
;; the bridge on, and it is obeyed.  A session that wants otherwise
;; carries `:remote-control' among its options, and
;; `ecc-remote-control-toggle' switches a running one.  The name a
;; session takes on the bridge is its own.

(defvar ecc-remote-control-functions nil
  "Functions run when the Remote Control state of a session changes.
Each is called with the session.  Like the permission mode, the answer
arrives from the process filter rather than from the command that
asked, so this is how the header line hears about it.")

;; There is deliberately no `ecc-effort', `ecc-autocompact',
;; `ecc-allowed-tools', `ecc-disallowed-tools' or `ecc-safe-mode'
;; (decided 2026-09-10).  All five belong to the Claude Code settings,
;; the way the model and the budget do; a session that wants one of its
;; own carries it among its options, as `:effort', `:autocompact',
;; `:allowed-tools', `:disallowed-tools' or `:safe-mode'.  `--safe-mode'
;; in particular takes away the MCP servers, skills, commands and agents
;; this package exists to surface, so nothing here recommends it.

(defvar ecc-disabled-plugins nil
  "Plugin identifiers to disable for the sessions this package starts.
Each entry looks like \"name@marketplace\" and is passed through
--settings, so the plugin stays enabled in the terminal client.

Hooks written for the terminal client cannot do their job behind a
headless one; a well behaved one answers no_capable_terminal and steps
aside, but it still costs a round trip and can inject settings of its
own.  Disabling the plugin that installs it is enough, and unlike
`--safe-mode' it leaves MCP servers and commands alone.")

(defvar ecc-streaming-enabled t
  "Non-nil passes --include-partial-messages for incremental rendering.")

(defvar ecc-replay-user-messages t
  "Non-nil passes --replay-user-messages, so that prompts come back.
The CLI then echoes every user message on the output stream, marked
`isReplay\='.  The ones this package sent are dropped again -- it knows
what it sent -- and what is left is a prompt somebody sent from
somewhere else: from a phone over Remote Control, above all.  Without
this the transcript shows the answer to such a prompt with nothing in
front of it, since the text reaches the CLI without ever passing through
Emacs (measured 2026-09-08).

It costs one extra line per turn and nothing else.")

(defvar ecc-subagent-text-enabled t
  "Non-nil passes --forward-subagent-text to receive subagent output.")

(defcustom ecc-prompt-suggestions-enabled nil
  "Non-nil passes --prompt-suggestions."
  :type 'boolean)

(defvar ecc-hook-events-enabled nil
  "Non-nil passes --include-hook-events.
Only useful without --safe-mode, which disables hooks altogether.")

(defcustom ecc-stream-throttle 0.05
  "Seconds to gather streaming deltas before drawing them.
Zero draws every delta as it arrives.  Thinning by a count of deltas was
dropped on 2026-09-10 along with the requirement behind it; a rate in
seconds says what it does, and zero covers the case a count of one
covered."
  :type 'number)

(defvar ecc-extra-args nil
  "Extra arguments appended to every CLI invocation.
This is the way to pass a flag this package has no setting for, such as
--effort or --safe-mode.  Nothing checks what goes in: an argument that
overrides one this package relies on -- --verbose, --output-format,
--input-format or --print -- breaks the session rather than the flag.")

(defvar ecc-extra-environment '("CLAUDE_CODE_ARTIFACT=1")
  "Extra \"NAME=VALUE\" entries put in the environment of every CLI.
They are prepended to `process-environment', so they win over what
Emacs inherited.  A session can carry its own list in
:extra-environment instead.

CLAUDE_CODE_ARTIFACT is here because the CLI hides the Artifact tool
from a session it considers to be driven by an SDK, and this package
drives it over stream-json, which is exactly that: the CLI turns its
own CLAUDE_CODE_ENTRYPOINT from \"cli\" into \"sdk-cli\" when it is
started the way this package starts it, and then withholds the tool
with the reason sdk_default_off unless CLAUDE_CODE_ARTIFACT is set to
a true value (1, true, yes or on).  Setting it opts back in; it does
not turn anything on that the terminal does not already have, since
the feature flag and the account policy are read separately
\(confirmed against 2.1.267 on 2026-09-11).")

(defcustom ecc-command-wrapper-function nil
  "Function that rewrites the CLI command line before it is run.
Called with the command list and the project root; it must return the
command list to run.  Nil runs the command unchanged."
  :type '(choice (const :tag "None" nil) function))

(defvar ecc-mcp-config-function nil
  "Function returning the --mcp-config argument of a session, or nil.
`ecc-mcp' installs itself here when it is loaded, which is how
`ecc-proc' can register the Emacs MCP server without depending on it
.")

;;;; Logging

(defcustom ecc-log-max-lines 5000
  "Maximum number of lines kept in a session log buffer.
Nil keeps every line."
  :type '(choice (const :tag "Unlimited" nil) integer))

(defcustom ecc-debug nil
  "Non-nil logs internal diagnostics in addition to raw protocol lines."
  :type 'boolean)

(defun ecc-log-buffer-name (name)
  "Return the name of the log buffer for the session called NAME."
  (format "*ecc-log: %s*" name))

(defun ecc--log-buffer (name)
  "Return the log buffer for the session called NAME, creating it if needed."
  (let ((buffer (get-buffer-create (ecc-log-buffer-name name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (setq-local window-point-insertion-type t))
    buffer))

(defun ecc--log-trim ()
  "Trim the current buffer to `ecc-log-max-lines' lines from the end."
  (when ecc-log-max-lines
    (save-excursion
      (goto-char (point-max))
      (forward-line (- ecc-log-max-lines))
      (when (> (point) (point-min))
        (let ((inhibit-read-only t))
          (delete-region (point-min) (point)))))))

(defun ecc--log-insert (name text)
  "Append TEXT as one line to the log buffer of the session called NAME.
Each line is stamped with the time it was written."
  (with-current-buffer (ecc--log-buffer name)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert (format-time-string "%H:%M:%S.%3N ") text)
        (unless (bolp) (insert "\n")))
      (ecc--log-trim))))

(defun ecc-log-raw (name direction line)
  "Log LINE verbatim for the session called NAME.
DIRECTION is a symbol, normally `recv' or `send'."
  (ecc--log-insert name (format "%s %s" (if (eq direction 'send) ">>" "<<") line)))

(defun ecc-log (name format-string &rest args)
  "Log a diagnostic for the session called NAME.
FORMAT-STRING and ARGS are passed to `format'."
  (ecc--log-insert name (concat "-- " (apply #'format format-string args)))
  (when ecc-debug
    (apply #'message (concat "ecc[" name "]: " format-string) args)))

;;;; The mode line and the header line

(defun ecc--mode-line-escape (string)
  "Return STRING as it must be written to reach a mode line intact.
A mode line and a header line read `%' as the start of a construct of
their own: `%s' is the process status, and an unrecognised one takes
the character after it away with it: \"83% left\" arrives as
\"83left\".  Everything this package puts there is text meant for a
person, and it carries session names, shell commands and percentages,
so every `%' is doubled.  The added character copies the properties of
the one it stands next to, so a face is not broken in the middle."
  (when string
    (let ((result nil)
          (start 0)
          (pos nil))
      (while (setq pos (string-search "%" string start))
        (push (substring string start (1+ pos)) result)
        (push (substring string pos (1+ pos)) result)
        (setq start (1+ pos)))
      (push (substring string start) result)
      (apply #'concat (nreverse result)))))

;;;; Faces

;; The session buffer does not use font-lock, so every face below is
;; applied when the text is inserted.

(defface ecc-user-face
  '((((background dark))  :extend t :background "#3b5329")
    (((background light)) :extend t :background "#e6f0d4")
    (t :inherit font-lock-keyword-face))
  "Face for the band a prompt sent by the user is drawn in.
Only the background is set, so that the colour the theme gives the
text is what is read, and it extends past the end of the line so that
the band spans the window however wide it is.  A display that names no
background falls back to a colour for the text instead."
  :group 'ecc)

(defface ecc-user-mark-face
  '((t :inherit (bold font-lock-keyword-face)))
  "Face of the mark that opens the band of a prompt sent by the user.
The band is a background; the mark is what gives it a colour of its
own, so that the eye finds where a turn begins."
  :group 'ecc)

(defface ecc-assistant-face
  '((t :inherit default))
  "Face for assistant text."
  :group 'ecc)

(defface ecc-thinking-face
  '((t :inherit shadow :slant italic))
  "Face for thinking blocks."
  :group 'ecc)

(defface ecc-synthetic-face
  '((t :inherit shadow))
  "Face for replies the CLI itself made up, such as slash command output."
  :group 'ecc)

(defface ecc-tool-face
  '((t :inherit font-lock-function-name-face))
  "Face for a tool name in a heading."
  :group 'ecc)

;; The prose is what is read; the tool calls are what is skimmed.  Drawing
;; the calls a little smaller lets the eye pass over them.
(defface ecc-tool-line-face
  '((t :height 0.9))
  "Face put over the whole of a tool or agent block, heading and body.
It carries the height alone, so that the colours of the heading and of
the body come through it."
  :group 'ecc)

(defface ecc-error-face
  '((t :inherit error))
  "Face for a failed tool call or a dispatch error."
  :group 'ecc)

;; The icon that opens a tool heading is drawn as a small badge: the
;; colour says what kind of work the tool does, so that a Bash is told
;; from a Read before the name is read.  The background is kept close to
;; the background of the frame, so that a screenful of them stays quiet;
;; a display with few colours gets the foreground alone.

(defface ecc-icon-face
  '((((background dark) (min-colors 88)) :foreground "#b0b6c0" :background "#26292e")
    (((background light) (min-colors 88)) :foreground "#555b66" :background "#ebedf0")
    (t :inherit shadow))
  "Face of the icon of a tool that falls in no other group."
  :group 'ecc)

(defface ecc-icon-read-face
  '((((background dark) (min-colors 88)) :foreground "#8ab4f8" :background "#1e2a3a")
    (((background light) (min-colors 88)) :foreground "#1a5fb4" :background "#dce8f8")
    (((background dark)) :foreground "brightblue")
    (t :foreground "blue"))
  "Face of the icon of a tool that reads."
  :group 'ecc)

(defface ecc-icon-write-face
  '((((background dark) (min-colors 88)) :foreground "#8fd18f" :background "#1f2e1f")
    (((background light) (min-colors 88)) :foreground "#1c7430" :background "#dff0dd")
    (((background dark)) :foreground "brightgreen")
    (t :foreground "green"))
  "Face of the icon of a tool that writes a file."
  :group 'ecc)

(defface ecc-icon-shell-face
  '((((background dark) (min-colors 88)) :foreground "#c9a0ff" :background "#2a2338")
    (((background light) (min-colors 88)) :foreground "#6b3fa0" :background "#ece2f8")
    (((background dark)) :foreground "brightmagenta")
    (t :foreground "magenta"))
  "Face of the icon of a tool that runs a command."
  :group 'ecc)

(defface ecc-icon-search-face
  '((((background dark) (min-colors 88)) :foreground "#e8c66a" :background "#302a1c")
    (((background light) (min-colors 88)) :foreground "#8a6100" :background "#f6ecd2")
    (((background dark)) :foreground "brightyellow")
    (t :foreground "yellow"))
  "Face of the icon of a tool that searches."
  :group 'ecc)

(defface ecc-icon-agent-face
  '((((background dark) (min-colors 88)) :foreground "#f08ac0" :background "#33202c")
    (((background light) (min-colors 88)) :foreground "#a3216e" :background "#fadfec")
    (((background dark)) :foreground "brightmagenta")
    (t :foreground "magenta"))
  "Face of the icon of a tool that hands the work to an agent."
  :group 'ecc)

(defface ecc-icon-web-face
  '((((background dark) (min-colors 88)) :foreground "#6fc9c9" :background "#1b2e2e")
    (((background light) (min-colors 88)) :foreground "#16706f" :background "#d8f0ef")
    (((background dark)) :foreground "brightcyan")
    (t :foreground "cyan"))
  "Face of the icon of a tool that goes out to the network."
  :group 'ecc)

(defface ecc-icon-task-face
  '((((background dark) (min-colors 88)) :foreground "#f0a06a" :background "#33261c")
    (((background light) (min-colors 88)) :foreground "#a35316" :background "#fbe6d5")
    (((background dark)) :foreground "brightred")
    (t :foreground "red"))
  "Face of the icon of a tool that plans or asks."
  :group 'ecc)

(defface ecc-pending-face
  '((t :inherit warning))
  "Face for a request that is waiting for an answer."
  :group 'ecc)

(defface ecc-running-face
  '((((class color) (min-colors 88) (background dark)) :foreground "#a6e22e")
    (((class color) (min-colors 88) (background light)) :foreground "#4e8f00")
    (((class color)) :foreground "green")
    (t :inherit default))
  "Face for a session that is working under its own steam.
Yellow green, so that the amber of `ecc-pending-face' is left to mean
one thing only: that the session is waiting on the user.  A light
background takes a darker shade, the bright one being unreadable
there."
  :group 'ecc)

(defface ecc-heading-face
  '((t :inherit bold))
  "Face for the session header and turn headings."
  :group 'ecc)

(defface ecc-dim-face
  '((t :inherit shadow))
  "Face for secondary detail such as costs and durations."
  :group 'ecc)

(defface ecc-warning-face
  '((t :inherit warning))
  "Face for a hint that is worth noticing, such as a small context left."
  :group 'ecc)

(defface ecc-ok-face
  '((((background dark) (min-colors 88)) :foreground "#a6d189")
    (((background light) (min-colors 88)) :foreground "#3d7a1f")
    (((background dark)) :foreground "brightgreen")
    (t :foreground "green"))
  "Face for a measure that is still in good health, such as the context left.
Yellow-green: it reads as room to spare next to the amber of
`ecc-warning-face' and the red of `ecc-error-face'."
  :group 'ecc)

;; The three permission modes the terminal client colours, in the colours
;; it gives them (`claude\=' 2.1.263, its light and dark themes; the
;; ansi fallbacks are the ones it uses on a terminal with no more than
;; sixteen colours).  Shown under the prompt by `ecc-chat\='.

(defface ecc-accept-edits-face
  '((((background dark) (min-colors 88)) :foreground "#af87ff")
    (((background light) (min-colors 88)) :foreground "#8700ff")
    (((background dark)) :foreground "brightmagenta")
    (t :foreground "magenta"))
  "Face naming the acceptEdits permission mode."
  :group 'ecc)

(defface ecc-plan-mode-face
  '((((background dark) (min-colors 88)) :foreground "#48968c")
    (((background light) (min-colors 88)) :foreground "#006666")
    (((background dark)) :foreground "brightcyan")
    (t :foreground "cyan"))
  "Face naming the plan permission mode."
  :group 'ecc)

(defface ecc-auto-mode-face
  '((((background dark) (min-colors 88)) :foreground "#ffc107")
    (((background light) (min-colors 88)) :foreground "#966c1e")
    (((background dark)) :foreground "brightyellow")
    (t :foreground "yellow"))
  "Face naming the auto permission mode, which answers requests itself."
  :group 'ecc)

;;;; UUID

(defun ecc--hex4 ()
  "Return four random hexadecimal digits."
  (format "%04x" (random 65536)))

(defun ecc--uuid ()
  "Return a random RFC 4122 version 4 UUID string.
Implemented locally so that no dependency on `org-id' is needed."
  (format "%s%s-%s-4%s-%s%s-%s%s%s"
          (ecc--hex4) (ecc--hex4)
          (ecc--hex4)
          (substring (ecc--hex4) 1)
          (format "%x" (logior 8 (random 4)))
          (substring (ecc--hex4) 1)
          (ecc--hex4) (ecc--hex4) (ecc--hex4)))

;;;; JSON

;; The CLI protocol is one JSON object per line.  Arrays are read as
;; vectors, not lists: `json-serialize' treats a list as an object, so a
;; parsed array read as a list cannot be echoed back.  Echoing input
;; back verbatim is mandatory for the allow response, so vectors are the
;; only shape that round-trips.

(defun ecc--json-read (string)
  "Parse STRING as one JSON object and return it as an alist.
Object keys become symbols, arrays become vectors, JSON null becomes
nil and JSON false becomes the keyword `:false'."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'array
                     :null-object nil
                     :false-object :false))

(defun ecc--json-read-verbatim (string)
  "Parse STRING as one JSON object, keeping JSON null as `:null'.
`ecc--json-read' maps null to nil, which serializes back as an empty
object; use this reader for a value that has to be echoed to the CLI
byte for byte, such as the tool input of an allow response."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'array
                     :null-object :null
                     :false-object :false))

(defun ecc--json-true-p (value)
  "Return non-nil when VALUE is a JSON true.
JSON false reads as `:false\=', which is a symbol and therefore true to
Emacs; a boolean of the CLI has to be asked this way rather than tested
for itself."
  (and value (not (eq value :false)) (not (eq value :null))))

(defun ecc--json-write (object)
  "Serialize OBJECT to a JSON string.
Alists become objects, vectors become arrays, nil becomes an empty
object, `:null' becomes null and `:false' becomes false."
  (json-serialize object :null-object :null :false-object :false))

;;;; Small helpers

(defun ecc--truncate (string width)
  "Return STRING shortened to at most WIDTH characters.
Newlines are replaced by spaces and an ellipsis marks a cut."
  (let ((flat (replace-regexp-in-string "[ \t\n\r]+" " " (or string ""))))
    (if (<= (length flat) width)
        flat
      (concat (substring flat 0 (max 0 (1- width))) "…"))))

(defun ecc--fit (string width)
  "Return STRING shortened to at most WIDTH columns on the display.
Like `ecc--truncate', but counts what a column costs to draw rather
than how many characters it holds: a Japanese title is twice as wide as
it is long, and counting characters is what tears a list of them out of
line."
  (let ((flat (replace-regexp-in-string "[ \t\n\r]+" " " (or string ""))))
    (if (<= (string-width flat) width)
        flat
      ;; The padding fills the half column left behind when the cut
      ;; falls in the middle of a wide character.
      (truncate-string-to-width flat width nil ?\s "…"))))

(defun ecc--column (string width)
  "Return STRING as a field of exactly WIDTH columns, padded with spaces."
  (let ((fitted (ecc--fit string width)))
    (concat fitted (make-string (max 0 (- width (string-width fitted))) ?\s))))

(defun ecc--duration (seconds)
  "Return SECONDS as a short duration, such as \"9s\" or \"2m05s\".
Minutes are spelled out above a minute, because \"90s\" is read twice."
  (let ((seconds (round seconds)))
    (if (>= seconds 60)
        (format "%dm%02ds" (/ seconds 60) (% seconds 60))
      (format "%ds" seconds))))

;;;; Naming a session in a list

(defconst ecc--session-time-units
  '((31536000 . "year") (2592000 . "month") (604800 . "week")
    (86400 . "day") (3600 . "hour") (60 . "minute"))
  "Seconds and the name of the unit, largest first.
The month and the year are the rounded ones a reader expects of \"3
months ago\"; nothing here is meant to be a calendar.")

(defun ecc--session-time-label (time)
  "Return how long ago TIME was, in words, or an empty string when nil.
A list of sessions is read to tell one conversation from another, and
which one was last worked in is what tells them apart; the reading is
kept to a single unit (\"3 hours ago\") for that reason."
  (if (null time)
      ""
    (let ((age (float-time (time-subtract (current-time) time))))
      (if (< age 60)
          "just now"
        (let ((unit (seq-find (lambda (u) (>= age (car u)))
                              ecc--session-time-units)))
          (let ((n (floor (/ age (car unit)))))
            (format "%d %s%s ago" n (cdr unit) (if (= n 1) "" "s"))))))))

(defun ecc--short-model-name (model)
  "Return the family MODEL belongs to, or nil when it names none.
The CLI names a model in full, `claude-sonnet-4-5-20250929\='; what
tells one from another in a list is the family, `sonnet\='.  A name the
CLI made up rather than ran -- the `<synthetic>\=' of a slash command --
is not a model to show, so nil comes back for it."
  (when (and model (not (string-empty-p model))
             (not (string-prefix-p "<" model)))
    (replace-regexp-in-string
     "-[0-9].*\\'" "" (replace-regexp-in-string "\\`claude-" "" model))))

(defun ecc--project-label (directory)
  "Return the name of DIRECTORY itself, without the path leading to it.
A dashboard column has room for the project, not for where it lives."
  (if (or (null directory) (equal directory ""))
      ""
    (file-name-nondirectory (directory-file-name (expand-file-name directory)))))

(provide 'ecc-core)

;;; ecc-core.el ends here
