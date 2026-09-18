;;; ecc-protocol.el --- Stream-json protocol for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
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

;; Turns one line of the CLI stream-json output into an alist, and
;; builds the JSON objects sent back on stdin.  Together with `ecc-proc'
;; this is the only place that is allowed to touch JSON; every other
;; module works on the Emacs data structures of `ecc-model'.
;;
;; Message shapes are the ones recorded from CLI 2.1.261; see
;; test/fixtures.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'iso8601)
(require 'ecc-core)

;; `json' is required where it is used rather than here -- reading and
;; writing JSON is `json-serialize' and `json-parse-string', which are
;; built in, and only the pretty-printer wants the library.  Declared so
;; that the file compiles on its own all the same.
(declare-function json-pretty-print-buffer "json" (&optional minimize))

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
without any change.  Nil when there are none."
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
;; here must be a vector.

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

(defun ecc-protocol-control-cancel (request-id)
  "Return a control_cancel_request alist withdrawing REQUEST-ID.
The CLI drops the work it was doing for that request and answers it with
an error rather than a result; a side question cancelled this way comes
back as \"Side question cancelled\" (measured 2026-09-09)."
  `((type . "control_cancel_request")
    (request_id . ,request-id)))

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
that supports it -- with an error control response (confirmed
2026-09-08)."
  (ecc-protocol-control-request request-id "set_permission_mode" 'mode mode))

(defun ecc-protocol-remote-control (request-id enabled &optional name)
  "Return the remote_control control request with REQUEST-ID.
ENABLED turns the bridge on when non-nil and off otherwise; it goes out
as t or :false, the way the CLI wants a boolean.  NAME, when given, is
the name the session takes on the bridge.  `keep_session_on_exit\=' is
deliberately not sent: the bridge is folded up with the session
\(decided 2026-09-08)."
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
day it is (`ecc-perm' writes the settings file itself instead)."
  `((type . "addRules")
    (rules . ,(vconcat (mapcar (lambda (pattern)
                                 `((toolName . ,tool-name)
                                   (ruleContent . ,pattern)))
                               patterns)))
    (behavior . "allow")
    (destination . ,(or destination "session"))))

;;;; Session history files

;; The jsonl the CLI keeps under ~/.claude/projects is not the stream:
;; it holds the same `user' and `assistant' messages, but wraps them in
;; its own bookkeeping and spells the structured tool result
;; `toolUseResult' rather than `tool_use_result'.  Both shapes are read
;; here, so that `ecc-history' can hand a recorded line to
;; `ecc-dispatch' unchanged.

(defconst ecc-protocol-history-types '("user" "assistant" "system")
  "Line types of a history file that carry conversation content.
Everything else is bookkeeping: `attachment', `summary',
`file-history-snapshot', `last-prompt', `mode', `permission-mode',
`bridge-session', `ai-title', `cost-state' and the rest.")

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
  "Return non-nil when MESSAGE was written by a subagent."
  (eq (alist-get 'isSidechain message) t))

(defconst ecc-protocol-command-output-regexp "\\`[ \t\n]*<local-command-stdout>"
  "Start of a user line that is the output of a slash command.
The interactive CLI writes what a local command printed back into the
conversation as a user message; it is not a prompt and starts no turn.")

;;;; Local commands

;; A slash command the CLI ran itself leaves three kinds of line in the
;; recording: the caveat it writes to tell the model to ignore what
;; follows, the command itself as a user message of tagged fields, and
;; what the command printed, either as `system/local_command' or as
;; another user message.  None of them is something the user typed at
;; the model, so none of them opens a turn (confirmed against the
;; recording of session 4cc012b5).

(defconst ecc-protocol-command-caveat-regexp "\\`[ \t\n]*<local-command-caveat>"
  "Start of the note the CLI writes before the record of a local command.
It is addressed to the model, not to the user, and the terminal client
does not show it either, so it is not drawn.")

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

;;;; Notices the CLI injects

;; A CLI that resumes a session with background tasks left over from the
;; previous process injects a notice about them into the conversation as
;; a plain `user' message: no `isMeta', not a sidechain, not a local
;; command.  What tells it apart is `origin.kind', which is "human" for
;; what somebody typed and names the injection otherwise; the only other
;; value seen on this machine is "task-notification", and lines written
;; before the CLI had the field carry no `origin' at all (confirmed
;; 2026-09-17 against CLI 2.1.271 from the terminal and 2.1.273 from a
;; stream-json client).

(defconst ecc-protocol-task-notification-regexp "\\`[ \t\n]*<task-notification>"
  "Start of the notice the CLI writes about a background task.
It is the fallback for a recording written before the CLI had an
`origin' field: there is nothing else on such a line to go by.")

(defun ecc-protocol-origin-kind (message)
  "Return the string under `origin.kind' of MESSAGE, or nil."
  (let ((kind (alist-get 'kind (alist-get 'origin message))))
    (and (stringp kind) kind)))

(defun ecc-protocol-injected-p (message)
  "Return non-nil when the CLI wrote MESSAGE into the conversation itself.
That is what an `origin.kind' other than \"human\" says.  A message with
no `origin' at all says nothing either way and is not judged here."
  (when-let* ((kind (ecc-protocol-origin-kind message)))
    (not (equal kind "human"))))

(defun ecc-protocol-task-notification-p (text)
  "Return non-nil when TEXT is the CLI notice about a background task."
  (and (stringp text)
       (string-match-p ecc-protocol-task-notification-regexp text)
       t))

(defun ecc-protocol-task-notification-summary (text)
  "Return the one-line summary of the task notice TEXT, or nil."
  (or (ecc-protocol-command-tag text "summary")
      (ecc-protocol-command-tag text "status")))

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
before it, nor what it printed was said to the model.  Neither is a
notice the CLI injected (`ecc-protocol-injected-p\='), such as the one
about background tasks left over from a previous process.

This is the one place every reader of a recording asks, so a notice
rejected here opens no turn, and is nobody\='s last prompt in the resume
list, the dashboard, the paging index or the search."
  (when (and (equal (alist-get 'type message) "user")
             (not (eq (alist-get 'isMeta message) t))
             (not (ecc-protocol-injected-p message))
             (not (ecc-protocol-history-sidechain-p message)))
    (let ((text (ecc-protocol-history-text message)))
      (and text
           (not (string-match-p ecc-protocol-command-output-regexp text))
           (not (string-match-p ecc-protocol-command-name-regexp text))
           (not (ecc-protocol-command-caveat-p text))
           (not (ecc-protocol-task-notification-p text))
           text))))

(defun ecc-protocol-history-timestamp (message)
  "Return the `timestamp' of MESSAGE as an Emacs time, or nil."
  (when-let* ((stamp (alist-get 'timestamp message)))
    (ignore-errors (encode-time (iso8601-parse stamp)))))

(defun ecc-protocol-history-info (line info)
  "Fold LINE of a history file into the summary alist INFO.
Only the keys a line actually carries are set, so that INFO can be
built from the first lines of a file and then from the last ones, the
later value winning.  The keys are `session-id', `cwd', `title',
`prompt', `cost', `model' and `time'."
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
            ("user" (funcall set 'prompt (ecc-protocol-history-prompt object)))
            ;; The model of the last real answer is the one a resume
            ;; would carry on with; a synthetic reply names none.
            ("assistant" (unless (ecc-protocol-synthetic-p object)
                           (funcall set 'model
                                    (alist-get 'model
                                               (alist-get 'message object)))))))
        info)
    (error info)))

(defun ecc-protocol-history-link (line)
  "Return (UUID . PARENT-UUID) of LINE of a history file, or nil.
Every kind of line is looked at, bookkeeping included: an attachment
sits in the chain between two messages, so a walk up the chain that
skipped one would stop early."
  (condition-case nil
      (let ((object (ecc--json-read line)))
        (when-let* ((uuid (and (consp object) (alist-get 'uuid object))))
          (cons uuid (alist-get 'parentUuid object))))
    (error nil)))

(defun ecc-protocol-history-leaf (line)
  "Return the leaf uuid LINE of a history file names, or nil.
The CLI writes a `last-prompt' line after every turn saying which
message the conversation now hangs from; the last one in the file is
the branch a resume would continue."
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

;;;; Settings files

;; The settings file is JSON too, so it is read and written here and not
;; in `ecc-perm'.  `json-pretty-print-buffer' is used for the layout; it
;; keeps {} and [] apart from null, which was checked on the Emacs this
;; is developed on.  Where those files live is here for the same reason:
;; every module that wants one -- the hooks buffer, the permission
;; rules, the model a session would start with -- reads it through this
;; file.

(defvar ecc-protocol-user-directory "~/.claude/"
  "Directory holding the settings file that applies to every project.")

(defvar ecc-protocol-managed-files
  '("/Library/Application Support/ClaudeCode/managed-settings.json"
    "/etc/claude-code/managed-settings.json")
  "Where an administrator's settings live, above every other scope.
They override every other file: the CLI takes what they say and no
setting below them can undo it (2.1.270).")

(defun ecc-protocol-settings-files (root)
  "Return the settings files that apply to ROOT.
Each is (SCOPE . FILE), in the order the CLI reads them: the managed
settings of the machine, then the user\\='s own, then the project\\='s
and the one beside it that is not committed.  ROOT nil leaves out the
two that belong to a project.

The order is the one to read a list of things in -- the hooks of every
scope run.  For a single value the narrowest scope wins instead, which
is the reverse of this, with managed above all of them."
  (append (mapcar (lambda (file) (cons 'managed file)) ecc-protocol-managed-files)
          (list (cons 'user (expand-file-name "settings.json"
                                              ecc-protocol-user-directory)))
          (when root
            (list (cons 'project (expand-file-name ".claude/settings.json" root))
                  (cons 'local (expand-file-name ".claude/settings.local.json"
                                                 root))))))

(defun ecc-protocol-settings-model (root)
  "Return the model the Claude Code settings name for ROOT, or nil.
The `model\\=' key of the settings files, which is what a session
started without --model runs: the local file of the project first, then
the project\\='s own, then the user\\='s, with the managed settings above
all three.  Nil when no file names one, which is the CLI\\='s own default.

A file that does not parse is passed over rather than signalled about:
this answers a footer drawn on every command, and the CLI has the same
file to complain about."
  (let ((managed nil) (model nil))
    (pcase-dolist (`(,scope . ,file) (ecc-protocol-settings-files root))
      (when-let* ((object (ignore-errors (ecc-protocol-read-settings-file file)))
                  (value (alist-get 'model object))
                  ((stringp value))
                  ((not (string-empty-p value))))
        (if (eq scope 'managed)
            (unless managed (setq managed value))
          (setq model value))))
    (or managed model)))

(defun ecc-protocol-read-settings-file (file)
  "Return the JSON object in FILE as an alist, or nil when FILE is absent.
An empty file counts as an empty object.  A file that does not parse,
or whose top level is not an object, signals an error: it is never
written over."
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

;;;; Hooks in a settings file

;; A settings file spells its hooks as
;;
;;   {"hooks": {"PreToolUse": [{"matcher": "Write|Edit",
;;                              "hooks": [{"type": "command", ...}]}]}}
;;
;; so one hook is addressed by four things: the file, the event, which
;; matcher group it is in and where it sits in that group.  The reader
;; below hands that address out with every entry and the writers take it
;; back; `ecc-hooks' never sees the JSON.
;;
;; An entry is left exactly as it was parsed.  The CLI knows five kinds
;; of them (command, prompt, agent, mcp_tool, http) and more fields than
;; this package has any business editing, so nothing is rebuilt: an
;; entry written back is the one that was read (CLI 2.1.270, 2026-09-13).

(defun ecc-protocol--hook-matcher (group)
  "Return the matcher of the hook GROUP, or nil when it matches everything.
The CLI treats an absent matcher and an empty one alike, so both are
nil here."
  (let ((matcher (alist-get 'matcher group)))
    (and (stringp matcher) (not (string-empty-p matcher)) matcher)))

(defun ecc-protocol--alist-put (alist key value)
  "Return ALIST with KEY set to VALUE, and return where it now is.
A key that is already there keeps its place; a new one goes to the end
rather than the front, because this order is the order of the keys in
the file that is written back, and a settings file should not have its
keys shuffled by an edit to one of them."
  (if (assq key alist)
      (progn (setf (alist-get key alist) value) alist)
    (append alist (list (cons key value)))))

(defun ecc-protocol-settings-hook-entries (object)
  "Return the hooks of the settings OBJECT, one plist each.
The plist is (:event :matcher :entry :group-index :hook-index): the
event as a string, the matcher as a string or nil, the entry as it was
parsed, and the address the writers below take.  Anything shaped
unexpectedly is skipped rather than signalled: the file belongs to the
CLI, which has more keys than this package knows."
  (let ((hooks (alist-get 'hooks object))
        (entries nil))
    (when (and hooks (listp hooks))
      (pcase-dolist (`(,event . ,groups) hooks)
        (when (vectorp groups)
          (seq-do-indexed
           (lambda (group group-index)
             (when (listp group)
               (let ((matcher (ecc-protocol--hook-matcher group))
                     (of-group (alist-get 'hooks group)))
                 (when (vectorp of-group)
                   (seq-do-indexed
                    (lambda (entry hook-index)
                      (push (list :event (symbol-name event)
                                  :matcher matcher
                                  :entry entry
                                  :group-index group-index
                                  :hook-index hook-index)
                            entries))
                    of-group)))))
           groups))))
    (nreverse entries)))

(defun ecc-protocol-settings-add-hook (file event matcher entry)
  "Add ENTRY to the hooks of EVENT in the settings FILE, under MATCHER.
MATCHER is a string, or nil for an event that takes none.  The group of
MATCHER is used when the file already has one and made when it does
not; other keys of the file are kept.  Returns the address the entry
was written to, as (GROUP-INDEX . HOOK-INDEX)."
  (let* ((object (ecc-protocol-read-settings-file file))
         (hooks (alist-get 'hooks object))
         (key (intern event)))
    (unless (listp hooks)
      (error "Hooks in %s is not an object" (abbreviate-file-name file)))
    (let* ((groups (append (alist-get key hooks) nil))
           (group-index (seq-position
                         groups matcher
                         (lambda (group m)
                           (equal (ecc-protocol--hook-matcher group) m))))
           (group (cond (group-index (nth group-index groups))
                        (matcher (list (cons 'matcher matcher)
                                       (cons 'hooks [])))
                        (t (list (cons 'hooks [])))))
           (of-group (append (alist-get 'hooks group) nil))
           (hook-index (length of-group)))
      (setf (alist-get 'hooks group) (vconcat of-group (list entry)))
      (if group-index
          (setf (nth group-index groups) group)
        (setq groups (append groups (list group))
              group-index (1- (length groups))))
      (setq hooks (ecc-protocol--alist-put hooks key (vconcat groups)))
      (setq object (ecc-protocol--alist-put object 'hooks hooks))
      (ecc-protocol-write-settings-file file object)
      (cons group-index hook-index))))

(defun ecc-protocol-settings-remove-hook (file event group-index hook-index)
  "Remove one hook of EVENT from the settings FILE, and return its entry.
GROUP-INDEX and HOOK-INDEX are the address
`ecc-protocol-settings-hook-entries' gave out.  A group left with no
hooks, an event left with no groups and a hooks object left with no
events are taken out with it, so that removing the last hook leaves the
file as it would have been written by hand.  Signals when the address
names nothing."
  (let* ((object (ecc-protocol-read-settings-file file))
         (hooks (alist-get 'hooks object))
         (key (intern event))
         (groups (append (and (listp hooks) (alist-get key hooks)) nil))
         (group (nth group-index groups))
         (of-group (append (alist-get 'hooks group) nil))
         (entry (nth hook-index of-group)))
    (unless (and group entry)
      (error "No hook %s[%s][%s] in %s" event group-index hook-index
             (abbreviate-file-name file)))
    (setq of-group (append (seq-take of-group hook-index)
                           (seq-drop of-group (1+ hook-index))))
    (if of-group
        (progn (setf (alist-get 'hooks group) (vconcat of-group))
               (setf (nth group-index groups) group))
      (setq groups (append (seq-take groups group-index)
                           (seq-drop groups (1+ group-index)))))
    (if groups
        (setf (alist-get key hooks) (vconcat groups))
      (setq hooks (assq-delete-all key hooks)))
    (if hooks
        (setf (alist-get 'hooks object) hooks)
      (setq object (assq-delete-all 'hooks object)))
    (ecc-protocol-write-settings-file file object)
    entry))

;;;; The hooks this package has taken out of a settings file

;; The CLI has no way of saying that a hook is there but switched off:
;; an entry either sits in the file and runs, or it is gone (checked
;; against the settings schema of CLI 2.1.270, 2026-09-13).  Turning one
;; off therefore means taking it out, and somewhere has to hold it until
;; it is put back.  That somewhere is a file of this package's own, so
;; that nothing this package invented is ever written into a settings
;; file the CLI reads -- least of all one a team shares.
;;
;;   {"version": 1,
;;    "disabled": {"/abs/path/settings.json":
;;                   {"PreToolUse": [{"matcher": "Write", "hook": {...}}]}}}

(defun ecc-protocol-stash-entries (file)
  "Return the hooks stashed in FILE, one plist each.
The plist is (:settings-file :event :matcher :entry :index), where the
index addresses the entry within its event for
`ecc-protocol-stash-remove'.  A stash that is absent or unreadable is
no stash at all: nil is returned rather than an error."
  (let ((disabled (alist-get 'disabled (ecc-protocol-read-json-file file)))
        (entries nil))
    (pcase-dolist (`(,settings-file . ,events) disabled)
      (when (listp events)
        (pcase-dolist (`(,event . ,stashed) events)
          (when (vectorp stashed)
            (seq-do-indexed
             (lambda (one index)
               (when (listp one)
                 (push (list :settings-file (symbol-name settings-file)
                             :event (symbol-name event)
                             :matcher (ecc-protocol--hook-matcher one)
                             :entry (alist-get 'hook one)
                             :index index)
                       entries)))
             stashed)))))
    (nreverse entries)))

(defun ecc-protocol-stash-add (file settings-file event matcher entry)
  "Stash ENTRY in FILE as the hook of EVENT that SETTINGS-FILE no longer has.
MATCHER is kept with it so that the entry can go back where it came
from.  Returns the index the entry was stashed at."
  (let* ((object (or (ecc-protocol-read-json-file file)
                     (list (cons 'version 1))))
         (disabled (alist-get 'disabled object))
         (file-key (intern settings-file))
         (events (alist-get file-key disabled))
         (event-symbol (intern event))
         (stashed (append (alist-get event-symbol events) nil))
         (one (if matcher
                  (list (cons 'matcher matcher) (cons 'hook entry))
                (list (cons 'hook entry))))
         (index (length stashed)))
    (setf (alist-get event-symbol events) (vconcat stashed (list one)))
    (setf (alist-get file-key disabled) events)
    (setf (alist-get 'disabled object) disabled)
    (ecc-protocol-write-settings-file file object)
    index))

(defun ecc-protocol-stash-remove (file settings-file event index)
  "Take the hook of EVENT at INDEX for SETTINGS-FILE out of the stash FILE.
Returns the entry that was stashed, so that the caller can put it back.
An emptied event and an emptied file are taken out with it.  Signals
when the address names nothing."
  (let* ((object (ecc-protocol-read-json-file file))
         (disabled (alist-get 'disabled object))
         (file-key (intern settings-file))
         (events (alist-get file-key disabled))
         (event-symbol (intern event))
         (stashed (append (alist-get event-symbol events) nil))
         (one (nth index stashed)))
    (unless one
      (error "No stashed %s hook at %s for %s" event index
             (abbreviate-file-name settings-file)))
    (setq stashed (append (seq-take stashed index)
                          (seq-drop stashed (1+ index))))
    (if stashed
        (setf (alist-get event-symbol events) (vconcat stashed))
      (setq events (assq-delete-all event-symbol events)))
    (if events
        (setf (alist-get file-key disabled) events)
      (setq disabled (assq-delete-all file-key disabled)))
    (setf (alist-get 'disabled object) disabled)
    (ecc-protocol-write-settings-file file object)
    (alist-get 'hook one)))

(defun ecc-protocol-value-string (value)
  "Return VALUE, as parsed from JSON, as a string fit for display.
Kept here because it is the only place that knows how the reader spells
null, false and an array.  `json-serialize' answers with a unibyte
string, whose UTF-8 bytes would be drawn one escape at a time, so the
serialized shapes are decoded back to text."
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
