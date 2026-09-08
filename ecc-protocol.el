;;; ecc-protocol.el --- stream-json protocol for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Turns one line of the CLI stream-json output into an alist, and builds
;; the JSON objects sent back on stdin.  Together with `ecc-proc' this is
;; the only place that is allowed to touch JSON; every other module works
;; on the Emacs data structures of section 3 of IMPLEMENTATION_PLAN.md.
;;
;; Message shapes are the ones recorded from CLI 2.1.261; see
;; test/fixtures and docs/verified.md.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'iso8601)
(require 'ecc-core)

;;;; Receiving

(defun ecc-protocol-parse-line (line)
  "Parse LINE of CLI output and return it as an alist.
A line that is not valid JSON is not discarded: an alist of type
`unknown' carrying the raw text and the error message is returned
instead, so that the caller can keep it in the transcript."
  (condition-case err
      (let ((object (ecc--json-read line)))
        (if (consp object)
            ;; Control requests are small and their input has to be
            ;; echoed back unchanged, so keep the raw text with them.
            (if (equal (alist-get 'type object) "control_request")
                (append object (list (cons 'ecc-raw line)))
              object)
          (list (cons 'type "unknown")
                (cons 'error "top-level value is not an object")
                (cons 'raw line))))
    (error
     (list (cons 'type "unknown")
           (cons 'error (error-message-string err))
           (cons 'raw line)))))

(defun ecc-protocol-type (message)
  "Return the `type' of MESSAGE as a symbol, or nil when absent."
  (let ((type (alist-get 'type message)))
    (and (stringp type) (intern type))))

(defun ecc-protocol-subtype (message)
  "Return the `subtype' of MESSAGE as a symbol, or nil when absent."
  (let ((subtype (alist-get 'subtype message)))
    (and (stringp subtype) (intern subtype))))

(defun ecc-protocol-control-subtype (message)
  "Return the request subtype of control_request MESSAGE, as a symbol."
  (let ((subtype (alist-get 'subtype (alist-get 'request message))))
    (and (stringp subtype) (intern subtype))))

(defun ecc-protocol-request-input (message)
  "Return the tool input of the can_use_tool MESSAGE, ready to echo back.
The value is re-read from the raw line with JSON null preserved, so
that serializing it reproduces what the CLI sent.  Falls back to the
already parsed input when the raw line was not kept."
  (let ((raw (alist-get 'ecc-raw message)))
    (alist-get 'input
               (alist-get 'request
                          (if raw (ecc--json-read-verbatim raw) message)))))

(defun ecc-protocol-request-suggestions (message)
  "Return the permission_suggestions of the can_use_tool MESSAGE, verbatim.
Like `ecc-protocol-request-input', the value is re-read from the raw
line so that a suggestion can be sent back as updatedPermissions
without any change (FR-PERM-3).  Nil when there are none."
  (let* ((raw (alist-get 'ecc-raw message))
         (suggestions (alist-get 'permission_suggestions
                                 (alist-get 'request
                                            (if raw (ecc--json-read-verbatim raw)
                                              message)))))
    (and (vectorp suggestions) (> (length suggestions) 0) suggestions)))

(defun ecc-protocol-replay-p (message)
  "Return non-nil when MESSAGE is the CLI echo of a message we sent.
The CLI marks these with isReplay when --replay-user-messages is on."
  (eq (alist-get 'isReplay message) t))

(defun ecc-protocol-synthetic-p (message)
  "Return non-nil when MESSAGE is a synthetic assistant reply.
Slash commands answered by the CLI itself carry the model name
\"<synthetic>\" and report zero token usage."
  (equal (alist-get 'model (alist-get 'message message)) "<synthetic>"))

(defun ecc-protocol-content-blocks (message)
  "Return the content blocks of assistant or user MESSAGE as a list.
A plain string content is returned as a single text block."
  (let ((content (alist-get 'content (alist-get 'message message))))
    (cond ((stringp content) (list (list (cons 'type "text") (cons 'text content))))
          ((vectorp content) (append content nil))
          ((consp content) content)
          (t nil))))

;;;; Sending

;; `json-serialize' reads a list as an object, so every JSON array built
;; here must be a vector (plan section 9, item 4).

(defun ecc-protocol-user-message (content)
  "Return a user message alist carrying CONTENT.
CONTENT is either a string or a vector of content blocks."
  `((type . "user")
    (message . ((role . "user")
                (content . ,content)))))

(defun ecc-protocol-control-request (request-id subtype &rest fields)
  "Return a control_request alist with REQUEST-ID and SUBTYPE.
FIELDS is a plist whose keys are symbols; each pair is added to the
request object, in the order given."
  (let ((request (list (cons 'subtype subtype))))
    (while fields
      (setq request (append request (list (cons (car fields) (cadr fields)))))
      (setq fields (cddr fields)))
    `((type . "control_request")
      (request_id . ,request-id)
      (request . ,request))))

(defun ecc-protocol-control-response (request-id response)
  "Return a successful control_response alist for REQUEST-ID.
RESPONSE is the inner response object."
  `((type . "control_response")
    (response . ((subtype . "success")
                 (request_id . ,request-id)
                 (response . ,response)))))

(cl-defun ecc-protocol-permission-allow (request-id &key updated-input
                                                    updated-permissions)
  "Return an allow response to the can_use_tool request REQUEST-ID.
UPDATED-INPUT is the tool input echoed back, possibly edited; it must be
the parsed input so that arrays stay vectors.  UPDATED-PERMISSIONS is a
vector of permission update objects, or nil to send none."
  (ecc-protocol-control-response
   request-id
   (append `((behavior . "allow")
             (updatedInput . ,updated-input))
           (when updated-permissions
             `((updatedPermissions . ,updated-permissions))))))

(defun ecc-protocol-permission-deny (request-id message)
  "Return a deny response to the can_use_tool request REQUEST-ID.
MESSAGE is shown to Claude as the tool result and must not be empty."
  (ecc-protocol-control-response
   request-id
   `((behavior . "deny")
     (message . ,message))))

(defun ecc-protocol-answers (pairs)
  "Return the answers object of an AskUserQuestion allow response.
PAIRS is an alist mapping the question text to the answer string; the
answer to a multiSelect question joins the chosen labels with a comma
and a space, which is what the CLI reports back in the tool result.
Keys are interned because `json-serialize' wants symbols and because an
alist, unlike a hash table, keeps the questions in order."
  (mapcar (lambda (pair) (cons (intern (car pair)) (cdr pair))) pairs))

(defun ecc-protocol-initialize (request-id)
  "Return the initialize control request with REQUEST-ID.
The empty hooks object is sent as nil, which serializes to {}."
  (ecc-protocol-control-request request-id "initialize" 'hooks nil))

(defun ecc-protocol-interrupt (request-id)
  "Return the interrupt control request with REQUEST-ID."
  (ecc-protocol-control-request request-id "interrupt"))

(defun ecc-protocol-set-permission-mode (request-id mode)
  "Return the set_permission_mode control request with REQUEST-ID.
MODE is one of default, acceptEdits, plan, auto, bypassPermissions or
dontAsk.  The CLI refuses one it cannot have -- auto asks for a model
that supports it -- with an error control response (docs/verified.md,
2026-09-08)."
  (ecc-protocol-control-request request-id "set_permission_mode" 'mode mode))

(defun ecc-protocol-remote-control (request-id enabled &optional name)
  "Return the remote_control control request with REQUEST-ID.
ENABLED turns the bridge on when non-nil and off otherwise; it goes out
as t or :false, the way the CLI wants a boolean.  NAME, when given, is
the name the session takes on the bridge.  `keep_session_on_exit\=' is
deliberately not sent: the bridge is folded up with the session
\(2026-09-08, `docs/decisions.md\=')."
  (apply #'ecc-protocol-control-request request-id "remote_control"
         'enabled (if enabled t :false)
         (when name (list 'name name))))

(defun ecc-protocol-set-mode-suggestion (mode &optional destination)
  "Return one setMode permission suggestion for MODE.
DESTINATION defaults to \"session\"."
  `((type . "setMode")
    (mode . ,mode)
    (destination . ,(or destination "session"))))

(defun ecc-protocol-settings-json (&optional disabled-plugins)
  "Return the JSON to pass to --settings, or nil when there is nothing to say.
DISABLED-PLUGINS is a list of plugin identifiers to turn off for this
session only.  The CLI merges this on top of the user settings files, so
the plugin stays enabled everywhere else."
  (when disabled-plugins
    (ecc--json-write
     `((enabledPlugins . ,(mapcar (lambda (id) (cons (intern id) :false))
                                  disabled-plugins))))))

(defun ecc-protocol-add-rules-update (tool-name patterns &optional destination)
  "Return one addRules permission update allowing PATTERNS of TOOL-NAME.
PATTERNS are rule contents such as \"git push *\"; DESTINATION
defaults to \"session\".  Unverified against the CLI, kept for the
day it is (FR-PERM-8 writes the settings file itself instead)."
  `((type . "addRules")
    (rules . ,(vconcat (mapcar (lambda (pattern)
                                 `((toolName . ,tool-name)
                                   (ruleContent . ,pattern)))
                               patterns)))
    (behavior . "allow")
    (destination . ,(or destination "session"))))

;;;; Session history files (FR-HIST-1, 2)

;; The jsonl the CLI keeps under ~/.claude/projects is not the stream: it
;; holds the same `user' and `assistant' messages, but wraps them in its
;; own bookkeeping and spells the structured tool result `toolUseResult'
;; rather than `tool_use_result'.  Both shapes are read here, so that
;; `ecc-history' can hand a recorded line to `ecc-dispatch' unchanged
;; (plan section 6.8).

(defconst ecc-protocol-history-types '("user" "assistant" "system")
  "Line types of a history file that carry conversation content.
Everything else is bookkeeping: `attachment', `summary',
`file-history-snapshot', `last-prompt', `mode', `permission-mode',
`bridge-session', `ai-title', `cost-state' and the rest (FR-HIST-2).")

(defun ecc-protocol-history-user-line-p (line)
  "Return non-nil when LINE of a history file might be a user message.
A cheap test used to skip the lines that cannot open a turn before
paying for a parse.  The type of a line is not always its first key —
an assistant line puts the message, and the type of every block in it,
first — so a line that passes still has to be parsed to be sure."
  (and (string-match-p "\"type\"[ \t]*:[ \t]*\"user\"" line) t))

(defun ecc-protocol-history-parse (line)
  "Parse LINE of a history file into a message `ecc-dispatch' understands.
Returns nil for a line that carries no conversation content, and for a
line that does not parse: a history file is read for display, so one
broken line must not stop the rest.  The structured tool result is
renamed to the name the stream uses."
  (condition-case nil
      (let ((object (ecc--json-read line)))
        (when (and (consp object)
                   (member (alist-get 'type object) ecc-protocol-history-types))
          (if-let* ((result (alist-get 'toolUseResult object)))
              (cons (cons 'tool_use_result result) object)
            object)))
    (error nil)))

(defun ecc-protocol-history-sidechain-p (message)
  "Return non-nil when MESSAGE was written by a subagent (FR-HIST-2)."
  (eq (alist-get 'isSidechain message) t))

(defconst ecc-protocol-command-output-regexp "\\`[ \t\n]*<local-command-stdout>"
  "Start of a user line that is the output of a slash command.
The interactive CLI writes what a local command printed back into the
conversation as a user message; it is not a prompt and starts no turn.")

;;;; Local commands (FR-HIST-2)

;; A slash command the CLI ran itself leaves three kinds of line in the
;; recording: the caveat it writes to tell the model to ignore what
;; follows, the command itself as a user message of tagged fields, and
;; what the command printed, either as `system/local_command' or as
;; another user message.  None of them is something the user typed at
;; the model, so none of them opens a turn (confirmed against the
;; recording of session 4cc012b5, see docs/verified.md).

(defconst ecc-protocol-command-caveat-regexp "\\`[ \t\n]*<local-command-caveat>"
  "Start of the note the CLI writes before the record of a local command.
It is addressed to the model, not to the user, and the terminal client
does not show it either, so it is not drawn (FR-HIST-2).")

(defconst ecc-protocol-command-name-regexp "\\`[ \t\n]*<command-name>"
  "Start of the user line that records a slash command the CLI ran.")

(defun ecc-protocol-command-tag (text tag)
  "Return what TEXT holds between <TAG> and </TAG>, or nil.
The value is trimmed: the CLI indents the fields it writes after the
first one."
  (when (and (stringp text)
             (string-match (format "<%s>\\(\\(?:.\\|
\\)*?\\)</%s>"
                                   (regexp-quote tag) (regexp-quote tag))
                           text))
    (string-trim (match-string 1 text))))

(defun ecc-protocol-command-caveat-p (text)
  "Return non-nil when TEXT is the caveat before a local command."
  (and (stringp text)
       (string-match-p ecc-protocol-command-caveat-regexp text)
       t))

(defun ecc-protocol-parse-command (text)
  "Return the fields of the local command TEXT records, or nil.
The alist holds `name' (with its leading slash), `message' and `args';
`args' is nil when the command was given none."
  (when (and (stringp text)
             (string-match-p ecc-protocol-command-name-regexp text))
    (let ((name (ecc-protocol-command-tag text "command-name"))
          (message (ecc-protocol-command-tag text "command-message"))
          (args (ecc-protocol-command-tag text "command-args")))
      (list (cons 'name (or name "?"))
            (cons 'message message)
            (cons 'args (and args (not (string-empty-p args)) args))))))

(defun ecc-protocol-command-output (text)
  "Return what TEXT records a local command as having printed, or nil."
  (when (and (stringp text)
             (string-match-p ecc-protocol-command-output-regexp text))
    (or (ecc-protocol-command-tag text "local-command-stdout") "")))

(defun ecc-protocol-history-text (message)
  "Return the text content of the user MESSAGE of a history file, or nil.
The blocks of a message that carries several are joined by newlines;
a message of tool results has no text at all."
  (let ((content (alist-get 'content (alist-get 'message message))))
    (cond
     ((stringp content) content)
     ((vectorp content)
      (let ((texts (seq-keep
                    (lambda (block)
                      (and (equal (alist-get 'type block) "text")
                           (alist-get 'text block)))
                    content)))
        (and texts (string-join texts "\n"))))
     (t nil))))

(defun ecc-protocol-history-prompt (message)
  "Return the prompt MESSAGE opens a turn with, or nil.
A turn starts at a `user' line whose content is text the user typed.
A line carrying only tool results continues the turn it is in, a line
the CLI wrote itself (`isMeta') is not a prompt at all, and neither is
the record of a local command: neither the command, nor the caveat
before it, nor what it printed was said to the model (FR-HIST-2)."
  (when (and (equal (alist-get 'type message) "user")
             (not (eq (alist-get 'isMeta message) t))
             (not (ecc-protocol-history-sidechain-p message)))
    (let ((text (ecc-protocol-history-text message)))
      (and text
           (not (string-match-p ecc-protocol-command-output-regexp text))
           (not (string-match-p ecc-protocol-command-name-regexp text))
           (not (ecc-protocol-command-caveat-p text))
           text))))

(defun ecc-protocol-history-timestamp (message)
  "Return the `timestamp' of MESSAGE as an Emacs time, or nil."
  (when-let* ((stamp (alist-get 'timestamp message)))
    (ignore-errors (encode-time (iso8601-parse stamp)))))

(defun ecc-protocol-history-info (line info)
  "Fold LINE of a history file into the summary alist INFO.
Only the keys a line actually carries are set, so that INFO can be
built from the first lines of a file and then from the last ones, the
later value winning (plan section 6.7).  The keys are `session-id',
`cwd', `title', `prompt', `cost' and `time'."
  (condition-case nil
      (let* ((object (ecc--json-read line))
             (type (and (consp object) (alist-get 'type object)))
             (set (lambda (key value) (when value (setf (alist-get key info) value)))))
        (when (consp object)
          (funcall set 'session-id (alist-get 'sessionId object))
          (funcall set 'cwd (alist-get 'cwd object))
          (funcall set 'time (ecc-protocol-history-timestamp object))
          (pcase type
            ("ai-title" (funcall set 'title (alist-get 'aiTitle object)))
            ("cost-state" (funcall set 'cost (alist-get 'totalCostUSD object)))
            ("user" (funcall set 'prompt (ecc-protocol-history-prompt object)))))
        info)
    (error info)))

(defun ecc-protocol-history-link (line)
  "Return (UUID . PARENT-UUID) of LINE of a history file, or nil.
Every kind of line is looked at, bookkeeping included: an attachment
sits in the chain between two messages, so a walk up the chain that
skipped one would stop early (FR-HIST-1)."
  (condition-case nil
      (let ((object (ecc--json-read line)))
        (when-let* ((uuid (and (consp object) (alist-get 'uuid object))))
          (cons uuid (alist-get 'parentUuid object))))
    (error nil)))

(defun ecc-protocol-history-leaf (line)
  "Return the leaf uuid LINE of a history file names, or nil.
The CLI writes a `last-prompt' line after every turn saying which
message the conversation now hangs from; the last one in the file is
the branch a resume would continue (FR-HIST-1)."
  (when (string-match-p "\"last-prompt\"" line)
    (condition-case nil
        (let ((object (ecc--json-read line)))
          (when (equal (alist-get 'type object) "last-prompt")
            (alist-get 'leafUuid object)))
      (error nil))))

(defun ecc-protocol-read-json-file (file)
  "Return the JSON object in FILE as an alist, or nil.
Never signals: the file belongs to another program, which may be
writing it right now."
  (condition-case nil
      (let ((object (ecc--json-read
                     (with-temp-buffer
                       (let ((coding-system-for-read 'utf-8-unix))
                         (insert-file-contents file))
                       (buffer-string)))))
        (and (consp object) object))
    (error nil)))

(defun ecc-protocol-parse-agents (output)
  "Return the sessions listed in OUTPUT, the JSON of `claude agents --json'.
Each is an alist with pid, cwd, kind, startedAt, sessionId, name and,
usually, status.  Returns nil when OUTPUT does not parse, which is what
a CLI that does not know the subcommand prints.

The session list is read from the files of `ecc-registry' rather than
from this command, which costs a subprocess and says less; this reader
is what checks that the two still agree (`ecc-test-live-agents')."
  (condition-case nil
      (let ((agents (ecc--json-read output)))
        (and (vectorp agents) (append agents nil)))
    (error nil)))

;;;; Settings files (FR-PERM-8)

;; The settings file is JSON too, so it is read and written here and not
;; in `ecc-perm' (NFR-2).  `json-pretty-print-buffer' is used for the
;; layout; it keeps {} and [] apart from null, which was checked on the
;; Emacs this is developed on.

(defun ecc-protocol-read-settings-file (file)
  "Return the JSON object in FILE as an alist, or nil when FILE is absent.
An empty file counts as an empty object.  A file that does not parse,
or whose top level is not an object, signals an error: it is never
written over (plan section 9, item 16)."
  (when (file-exists-p file)
    (let ((text (with-temp-buffer
                  (insert-file-contents file)
                  (string-trim (buffer-string)))))
      (if (string-empty-p text)
          nil
        (let ((object (condition-case err
                          (ecc--json-read-verbatim text)
                        (error (error "%s does not parse as JSON: %s"
                                      (abbreviate-file-name file)
                                      (error-message-string err))))))
          (unless (listp object)
            (error "%s does not hold a JSON object" (abbreviate-file-name file)))
          object)))))

(defun ecc-protocol-write-settings-file (file object)
  "Write OBJECT to FILE as indented JSON, creating the directory."
  (require 'json)
  (make-directory (file-name-directory file) t)
  (with-temp-buffer
    (insert (decode-coding-string (ecc--json-write object) 'utf-8))
    (json-pretty-print-buffer)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (write-region (point-min) (point-max) file nil 'silent)))

(defun ecc-protocol-settings-allow-list (object)
  "Return the permissions.allow patterns of the settings OBJECT as a list."
  (let ((allow (alist-get 'allow (alist-get 'permissions object))))
    (and (vectorp allow) (append allow nil))))

(defun ecc-protocol-settings-add-allow (file patterns)
  "Add PATTERNS to permissions.allow in the settings FILE.
Other keys of the file are kept.  Returns the patterns that were new;
nothing is written when there is none."
  (let* ((object (ecc-protocol-read-settings-file file))
         (existing (ecc-protocol-settings-allow-list object))
         (new (seq-remove (lambda (pattern) (member pattern existing)) patterns)))
    (when new
      (let ((permissions (alist-get 'permissions object)))
        (unless (listp permissions)
          (error "Permissions in %s is not an object" (abbreviate-file-name file)))
        (setf (alist-get 'allow permissions) (vconcat existing new))
        (setf (alist-get 'permissions object) permissions))
      (ecc-protocol-write-settings-file file object))
    new))

(defun ecc-protocol-value-string (value)
  "Return VALUE, as parsed from JSON, as a string fit for display.
Kept here because it is the only place that knows how the reader
spells null, false and an array (NFR-2).  `json-serialize' answers with
a unibyte string, whose UTF-8 bytes would be drawn one escape at a time,
so the serialized shapes are decoded back to text."
  (cond ((stringp value) value)
        ((null value) "null")
        ((eq value :null) "null")
        ((eq value :false) "false")
        ((eq value t) "true")
        ((numberp value) (number-to-string value))
        (t (condition-case nil
               (decode-coding-string (ecc--json-write value) 'utf-8)
             (error (format "%S" value))))))

(defun ecc-protocol-serialize (object)
  "Serialize OBJECT to the JSON line sent to the CLI, without newline."
  (ecc--json-write object))

(provide 'ecc-protocol)

;;; ecc-protocol.el ends here
