;;; ecc-core.el --- Core utilities for the ecc Claude Code client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Customization group, launch options, logging, UUID generation and the
;; thin JSON wrappers shared by every other `ecc-' module.
;;
;; This file must not depend on any other `ecc-' module.  See section 1.3
;; of IMPLEMENTATION_PLAN.md for the module dependency order.

;;; Code:

(require 'subr-x)

(defgroup ecc nil
  "Run the Claude Code CLI from Emacs."
  :group 'tools
  :prefix "ecc-")

;;;; Launch options (plan section 2.1)

(defcustom ecc-executable "claude"
  "Name of, or path to, the Claude Code CLI executable."
  :type 'string)

(defcustom ecc-model nil
  "Model passed to the CLI with --model, or nil for the CLI default."
  :type '(choice (const :tag "CLI default" nil) string))

(defcustom ecc-permission-mode nil
  "Initial permission mode passed with --permission-mode.
Nil leaves the CLI default in place."
  :type '(choice (const :tag "CLI default" nil)
                 (const "default") (const "acceptEdits")
                 (const "bypassPermissions") (const "plan")))

(defcustom ecc-effort nil
  "Reasoning effort passed with --effort, or nil for the CLI default."
  :type '(choice (const :tag "CLI default" nil) string))

(defcustom ecc-autocompact nil
  "Threshold passed with --autocompact, or nil to leave it unset."
  :type '(choice (const :tag "CLI default" nil) integer))

(defcustom ecc-allowed-tools nil
  "Tool patterns passed with --allowedTools."
  :type '(repeat string))

(defcustom ecc-disallowed-tools nil
  "Tool patterns passed with --disallowedTools."
  :type '(repeat string))

(defcustom ecc-max-budget-usd nil
  "Spending cap passed with --max-budget-usd, or nil for no cap."
  :type '(choice (const :tag "No cap" nil) number))

(defcustom ecc-safe-mode nil
  "Non-nil passes --safe-mode, which disables every customization.
That includes MCP servers, skills, custom commands and agents, which
this package exists to surface, so it is off by default.  To silence a
single misbehaving plugin use `ecc-disabled-plugins' instead."
  :type 'boolean)

(defcustom ecc-disabled-plugins nil
  "Plugin identifiers to disable for the sessions this package starts.
Each entry looks like \"name@marketplace\" and is passed through
--settings, so the plugin stays enabled in the terminal client.

Hooks written for the terminal client cannot do their job behind a
headless one; a well behaved one answers no_capable_terminal and steps
aside, but it still costs a round trip and can inject settings of its
own.  Disabling the plugin that installs it is enough, and unlike
`ecc-safe-mode' it leaves MCP servers and commands alone."
  :type '(repeat string))

(defcustom ecc-streaming-enabled t
  "Non-nil passes --include-partial-messages for incremental rendering."
  :type 'boolean)

(defcustom ecc-subagent-text-enabled t
  "Non-nil passes --forward-subagent-text to receive subagent output."
  :type 'boolean)

(defcustom ecc-prompt-suggestions-enabled nil
  "Non-nil passes --prompt-suggestions."
  :type 'boolean)

(defcustom ecc-hook-events-enabled nil
  "Non-nil passes --include-hook-events.
Only useful when `ecc-safe-mode' is nil, since safe mode disables hooks."
  :type 'boolean)

(defcustom ecc-stream-throttle 0.05
  "Seconds to gather streaming deltas before drawing them (FR-OUT-10).
Zero draws every delta as it arrives.  Only used when
`ecc-stream-throttle-method' is `time'."
  :type 'number)

(defcustom ecc-stream-throttle-method 'time
  "How streaming deltas are thinned out before drawing (FR-OUT-10).
`time' draws at most once per `ecc-stream-throttle' seconds; `count'
draws every `ecc-stream-throttle-count' deltas."
  :type '(choice (const time) (const count)))

(defcustom ecc-stream-throttle-count 1
  "Deltas gathered before drawing when thinning by count."
  :type 'integer)

(defcustom ecc-extra-args nil
  "Extra arguments appended to every CLI invocation."
  :type '(repeat string))

(defcustom ecc-command-wrapper-function nil
  "Function that rewrites the CLI command line before it is run.
Called with the command list and the project root; it must return the
command list to run.  Nil runs the command unchanged."
  :type '(choice (const :tag "None" nil) function))

;;;; Logging (NFR-8)

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

;;;; Faces (plan section 5.3)

;; The session buffer does not use font-lock (plan section 9, item 7), so
;; every face below is applied when the text is inserted.

(defface ecc-user-face
  '((t :inherit font-lock-keyword-face))
  "Face for the margin marker and text of a prompt sent by the user."
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

(defface ecc-error-face
  '((t :inherit error))
  "Face for a failed tool call or a dispatch error."
  :group 'ecc)

(defface ecc-pending-face
  '((t :inherit warning))
  "Face for a request that is waiting for an answer."
  :group 'ecc)

(defface ecc-heading-face
  '((t :inherit bold))
  "Face for the session header and turn headings."
  :group 'ecc)

(defface ecc-dim-face
  '((t :inherit shadow))
  "Face for secondary detail such as costs and durations."
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
;; parsed array read as a list cannot be echoed back.  Echoing input back
;; verbatim is mandatory for the allow response (plan section 12.3), so
;; vectors are the only shape that round-trips.  See docs/verified.md.

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

(provide 'ecc-core)

;;; ecc-core.el ends here
