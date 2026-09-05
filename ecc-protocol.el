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
MODE is one of default, acceptEdits, bypassPermissions or plan."
  (ecc-protocol-control-request request-id "set_permission_mode" 'mode mode))

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
    (insert (ecc--json-write object))
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
spells null, false and an array (NFR-2)."
  (cond ((stringp value) value)
        ((null value) "null")
        ((eq value :null) "null")
        ((eq value :false) "false")
        ((eq value t) "true")
        ((numberp value) (number-to-string value))
        (t (condition-case nil
               (ecc--json-write value)
             (error (format "%S" value))))))

(defun ecc-protocol-serialize (object)
  "Serialize OBJECT to the JSON line sent to the CLI, without newline."
  (ecc--json-write object))

(provide 'ecc-protocol)

;;; ecc-protocol.el ends here
