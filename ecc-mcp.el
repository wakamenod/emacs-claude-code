;;; ecc-mcp.el --- An MCP server inside Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.15 of IMPLEMENTATION_PLAN.md: an MCP server listening on
;; the loopback interface, registered with the CLI through --mcp-config,
;; which lets Claude ask Emacs what only Emacs knows -- the references
;; xref can find, the symbols imenu lists, the diagnostics flymake has
;; (FR-MCP-1).
;;
;; The transport is HTTP, and only POST is implemented: the CLI was
;; observed to open with server/discover, initialize and
;; notifications/initialized, to accept 405 for the GET it tries, and
;; never to need Server-Sent Events (docs/verified.md, 2026-09-05,
;; item 5).  So this is a small HTTP/1.1 reader and a JSON-RPC 2.0
;; dispatcher, and nothing more.
;;
;; A tool is an Elisp function with a name, a description and an
;; argument specification (FR-MCP-2).  The built-in ones are registered
;; here; `ecc-mcp-define-tool' registers any other.  Every tool runs in
;; the project of the session that asked, which is how the URL of each
;; session carries its session id.
;;
;; Emacs is busy while a tool runs, so the mode line says which one is
;; running, and `ecc-mcp-excluded-tools' takes a tool that turns out to
;; be slow out of the list altogether (FR-MCP-4).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'imenu)
(require 'vc-hooks)
(require 'ecc-core)
(require 'ecc-model)

(defcustom ecc-mcp-enabled nil
  "Non-nil registers the Emacs MCP server with every session started.
The server is started the first time a session needs it and stopped by
`ecc-mcp-stop' (FR-MCP-1)."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-mcp-port 0
  "Port the MCP server listens on.  Zero lets the system choose one."
  :type 'integer
  :group 'ecc)

(defcustom ecc-mcp-host "127.0.0.1"
  "Interface the MCP server listens on.
Anything but the loopback interface publishes an evaluator for your
Emacs to the network; there is no authentication here."
  :type 'string
  :group 'ecc)

(defcustom ecc-mcp-enable-execute-code nil
  "Non-nil publishes the tool that evaluates arbitrary Elisp (FR-MCP-3).
It is off by default: anything the model writes would run with the
rights of this Emacs."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-mcp-excluded-tools nil
  "Names of tools that are not published, whatever else registered them.
A tool that turns out to take long enough to be felt belongs here
\(FR-MCP-4)."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-mcp-server-name "emacs"
  "Name the MCP server registers itself under.
The CLI prefixes the tools with it: `mcp__emacs__xref_find_references'."
  :type 'string
  :group 'ecc)

(defcustom ecc-mcp-max-results 200
  "Most results a built-in tool returns in one answer."
  :type 'integer
  :group 'ecc)

(defconst ecc-mcp-protocol-version "2025-06-18"
  "Version of the MCP protocol this server answers with.")

;;;; The tool registry (FR-MCP-2)

(cl-defstruct ecc-mcp-tool
  "One tool published to Claude."
  name          ; the name the model calls it by
  description
  args          ; list of (NAME TYPE DESCRIPTION &optional REQUIRED)
  function)     ; called with the argument values, in the order of ARGS

(defvar ecc-mcp-tools (make-hash-table :test #'equal)
  "Hash of a tool name to its `ecc-mcp-tool'.")

(cl-defun ecc-mcp-define-tool (&key name description args function)
  "Publish FUNCTION to Claude as the tool called NAME (FR-MCP-2).
DESCRIPTION is what the model reads to decide whether to call it.
ARGS is a list of (ARG-NAME TYPE ARG-DESCRIPTION &optional REQUIRED),
where TYPE is a JSON schema type such as \"string\" or \"integer\";
FUNCTION is called with the values in that order and returns a string.
Registering a name again replaces what was there."
  (puthash name
           (make-ecc-mcp-tool :name name :description description
                              :args args :function function)
           ecc-mcp-tools)
  name)

(defun ecc-mcp-tool (name)
  "Return the tool called NAME, or nil."
  (gethash name ecc-mcp-tools))

(defun ecc-mcp-published-tools ()
  "Return the tools that are published, sorted by name.
`ecc-mcp-excluded-tools' and `ecc-mcp-enable-execute-code' are what
decide whether a registered tool is published (FR-MCP-3, FR-MCP-4)."
  (let (tools)
    (maphash (lambda (name tool)
               (unless (or (member name ecc-mcp-excluded-tools)
                           (and (equal name "execute_code")
                                (not ecc-mcp-enable-execute-code)))
                 (push tool tools)))
             ecc-mcp-tools)
    (sort tools (lambda (a b) (string< (ecc-mcp-tool-name a)
                                       (ecc-mcp-tool-name b))))))

(defun ecc-mcp-tool-schema (tool)
  "Return the JSON schema of the arguments of TOOL."
  (let ((properties nil)
        (required nil))
    (dolist (arg (ecc-mcp-tool-args tool))
      (pcase-let ((`(,name ,type ,description . ,rest) arg))
        (push (cons (intern name)
                    `((type . ,type) (description . ,description)))
              properties)
        (when (car rest) (push name required))))
    `((type . "object")
      (properties . ,(nreverse properties))
      (required . ,(vconcat (nreverse required))))))

(defun ecc-mcp-tool-object (tool)
  "Return TOOL as the object `tools/list' publishes."
  `((name . ,(ecc-mcp-tool-name tool))
    (description . ,(or (ecc-mcp-tool-description tool)
                        (ecc-mcp-tool-name tool)))
    (inputSchema . ,(ecc-mcp-tool-schema tool))))

;;;; Running a tool (FR-MCP-4)

(defvar ecc-mcp--running nil
  "Name of the tool running now, or nil.")

(defvar ecc-mcp--session-id nil
  "Session id the request being served came from, or nil.")

(defun ecc-mcp-session ()
  "Return the session the request being served belongs to, or nil."
  (and ecc-mcp--session-id (ecc-model-session ecc-mcp--session-id)))

(defun ecc-mcp-directory ()
  "Return the directory a tool should run in.
The session that registered the server names its project; a request
that names no session runs where Emacs is."
  (or (when-let* ((session (ecc-mcp-session)))
        (or (ecc-session-project-root session) (ecc-session-cwd session)))
      default-directory))

(defmacro ecc-mcp-with-project (&rest body)
  "Run BODY with `default-directory' at the project of the session (FR-MCP-2)."
  (declare (indent 0) (debug t))
  `(let ((default-directory (ecc-mcp-directory)))
     ,@body))

(defun ecc-mcp-call-tool (name arguments)
  "Call the tool NAME with ARGUMENTS, an alist, and return its text.
Signals when there is no such tool.  Errors from the tool itself are
turned into text: an MCP tool answers with a failure, it does not take
the server down with it."
  (let ((tool (or (ecc-mcp-tool name)
                  (error "No such tool: %s" name))))
    (unwind-protect
        (progn
          (setq ecc-mcp--running name)
          (force-mode-line-update t)
          (condition-case error
              (let ((values (mapcar (lambda (arg)
                                      (alist-get (intern (car arg)) arguments))
                                    (ecc-mcp-tool-args tool)))
                    ;; Nobody is at the keyboard for a tool: a question
                    ;; asked here would stop Emacs until someone noticed.
                    ;; Asking is made an error, which comes back to the
                    ;; model as a failed call (FR-MCP-4).
                    (inhibit-interaction t))
                (cons nil (format "%s" (apply (ecc-mcp-tool-function tool)
                                              values))))
            (error (cons t (format "%s failed: %s" name
                                   (error-message-string error))))))
      (setq ecc-mcp--running nil)
      (force-mode-line-update t))))

(defun ecc-mcp-mode-line-string ()
  "Return what the mode line says while a tool runs (FR-MCP-4)."
  (if ecc-mcp--running
      (propertize (format " MCP: %s… " ecc-mcp--running)
                  'face 'ecc-pending-face
                  'help-echo "Claude is using an Emacs tool")
    ""))

(defconst ecc-mcp--mode-line-construct '(:eval (ecc-mcp-mode-line-string))
  "What `ecc-mcp-indicator-mode' adds to `global-mode-string'.")

(define-minor-mode ecc-mcp-indicator-mode
  "Say in every mode line which Emacs tool Claude is using (FR-MCP-4)."
  :global t
  :group 'ecc
  (if ecc-mcp-indicator-mode
      (unless (member ecc-mcp--mode-line-construct global-mode-string)
        (setq global-mode-string
              (append (or global-mode-string '(""))
                      (list ecc-mcp--mode-line-construct))))
    (setq global-mode-string
          (remove ecc-mcp--mode-line-construct global-mode-string)))
  (force-mode-line-update t))

;;;; JSON-RPC 2.0

(defun ecc-mcp--result (id result)
  "Return the JSON-RPC answer carrying RESULT for ID."
  `((jsonrpc . "2.0") (id . ,(or id :null)) (result . ,result)))

(defun ecc-mcp--error (id code message)
  "Return the JSON-RPC answer carrying the error CODE and MESSAGE for ID."
  `((jsonrpc . "2.0") (id . ,(or id :null))
    (error . ((code . ,code) (message . ,message)))))

(defun ecc-mcp--server-info ()
  "Return what this server says about itself."
  `((protocolVersion . ,ecc-mcp-protocol-version)
    (capabilities . ((tools . ((listChanged . :false)))))
    (serverInfo . ((name . ,ecc-mcp-server-name) (version . "0.1.0")))))

(defun ecc-mcp-handle-request (request)
  "Answer the JSON-RPC REQUEST, an alist, or return nil for a notification."
  (let ((id (alist-get 'id request))
        (method (alist-get 'method request))
        (params (alist-get 'params request)))
    (pcase method
      ;; The CLI opens with this one before initialize; it wants the same
      ;; thing initialize answers (docs/verified.md).
      ((or "initialize" "server/discover")
       (ecc-mcp--result id (ecc-mcp--server-info)))
      ((pred (lambda (m) (and (stringp m) (string-prefix-p "notifications/" m))))
       nil)
      ("ping" (ecc-mcp--result id nil))
      ("tools/list"
       (ecc-mcp--result
        id `((tools . ,(vconcat (mapcar #'ecc-mcp-tool-object
                                        (ecc-mcp-published-tools)))))))
      ("tools/call"
       (let ((name (alist-get 'name params))
             (arguments (alist-get 'arguments params)))
         (if (null (ecc-mcp-tool name))
             (ecc-mcp--error id -32602 (format "No such tool: %s" name))
           (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool name arguments)))
             (ecc-mcp--result
              id `((content . [((type . "text") (text . ,text))])
                   (isError . ,(if failed t :false))))))))
      (_ (ecc-mcp--error id -32601 (format "Unknown method: %s" method))))))

;;;; HTTP (plan section 6.15: POST only)

(defvar ecc-mcp--server nil
  "The listening process, or nil.")

;; The server has no login.  What keeps it to the CLI it was started for
;; is a secret in the path, handed to the CLI through --mcp-config and to
;; nobody else, and a look at the Host header: a page in a browser can
;; POST to a loopback port without asking anybody, but it cannot guess
;; the path and it sends the host it was told to talk to.

(defvar ecc-mcp--token nil
  "Secret path segment of the running server, or nil.
Made afresh every time the server starts.")

(defun ecc-mcp-path ()
  "Return the path the CLI reaches this server at, or nil when it is down."
  (and ecc-mcp--token (concat "/mcp/" ecc-mcp--token)))

(defconst ecc-mcp-allowed-hosts '("127.0.0.1" "localhost" "[::1]")
  "Hosts a request may name in its Host header, besides `ecc-mcp-host'.")

(defun ecc-mcp--header (name header-lines)
  "Return the value of the header NAME in HEADER-LINES, or nil."
  (let ((regexp (concat "\\`" (regexp-quote name) ":[ \t]*\\(.*?\\)[ \t]*\\'")))
    (seq-some (lambda (line)
                (when (let ((case-fold-search t)) (string-match regexp line))
                  (match-string 1 line)))
              header-lines)))

(defun ecc-mcp--host-allowed-p (header-lines)
  "Return non-nil when the Host header in HEADER-LINES names this machine.
The port is not looked at; a request without a Host header is refused."
  (when-let* ((host (ecc-mcp--header "Host" header-lines)))
    (let ((name (if (string-match "\\`\\(\\[[^]]*\\]\\|[^:]*\\)" host)
                    (match-string 1 host)
                  host)))
      (and (member name (cons ecc-mcp-host ecc-mcp-allowed-hosts)) t))))

(defun ecc-mcp--target-allowed-p (target)
  "Return non-nil when TARGET, the request path, carries the secret."
  (and ecc-mcp--token
       (equal (car (split-string target "?")) (ecc-mcp-path))))

(defun ecc-mcp-running-p ()
  "Return non-nil when the MCP server is listening."
  (and ecc-mcp--server (process-live-p ecc-mcp--server)))

(defun ecc-mcp-listening-port ()
  "Return the port the server listens on, or nil when it is not running."
  (and (ecc-mcp-running-p)
       (cadr (process-contact ecc-mcp--server))))

;;;###autoload
(defun ecc-mcp-start ()
  "Start the MCP server and return the port it listens on (FR-MCP-1)."
  (interactive)
  (unless (ecc-mcp-running-p)
    (setq ecc-mcp--token (ecc--uuid))
    (setq ecc-mcp--server
          (make-network-process
           :name "ecc-mcp"
           :server t
           :host ecc-mcp-host
           :service ecc-mcp-port
           :family 'ipv4
           :coding 'binary
           :noquery t
           :filter #'ecc-mcp--filter
           :log #'ecc-mcp--log))
    (ecc-mcp-indicator-mode 1)
    (ecc-log "mcp" "listening on %s:%s" ecc-mcp-host (ecc-mcp-listening-port)))
  (ecc-mcp-listening-port))

;;;###autoload
(defun ecc-mcp-stop ()
  "Stop the MCP server."
  (interactive)
  (when ecc-mcp--server
    (delete-process ecc-mcp--server)
    (setq ecc-mcp--server nil))
  (setq ecc-mcp--token nil)
  (ecc-mcp-indicator-mode -1))

(defun ecc-mcp--log (_server connection _message)
  "Prepare CONNECTION, which the server just accepted."
  (set-process-coding-system connection 'binary 'binary)
  (process-put connection 'ecc-mcp-pending ""))

(defun ecc-mcp--filter (connection chunk)
  "Gather CHUNK from CONNECTION and answer every whole request in it."
  (let ((pending (concat (or (process-get connection 'ecc-mcp-pending) "") chunk)))
    (while (let ((used (ecc-mcp--consume connection pending)))
             (when used
               (setq pending (substring pending used))
               t)))
    (process-put connection 'ecc-mcp-pending pending)))

(defun ecc-mcp--consume (connection text)
  "Answer the first whole HTTP request in TEXT on CONNECTION.
Returns the number of characters used, or nil when TEXT does not hold
a whole request yet."
  (when-let* ((head-end (string-search "\r\n\r\n" text)))
    (let* ((head (substring text 0 head-end))
           (body-start (+ head-end 4))
           (lines (split-string head "\r\n" t))
           (request-line (split-string (or (car lines) "") " "))
           (method (car request-line))
           (target (or (cadr request-line) ""))
           (length (ecc-mcp--content-length (cdr lines))))
      (when (<= (+ body-start length) (length text))
        (let ((body (substring text body-start (+ body-start length))))
          (ecc-mcp--respond connection method target body (cdr lines))
          (+ body-start length))))))

(defun ecc-mcp--content-length (header-lines)
  "Return the Content-Length of HEADER-LINES, or zero."
  (or (seq-some (lambda (line)
                  (when (string-match "\\`[Cc]ontent-[Ll]ength:[ \t]*\\([0-9]+\\)"
                                      line)
                    (string-to-number (match-string 1 line))))
                header-lines)
      0))

(defun ecc-mcp--session-of-target (target)
  "Return the session id named in the query string of TARGET, or nil."
  (when (string-match "[?&]session=\\([^&]+\\)" target)
    (match-string 1 target)))

(defun ecc-mcp--respond (connection method target body &optional header-lines)
  "Answer the request of METHOD for TARGET with BODY on CONNECTION.
HEADER-LINES are the request headers.  A request from another host, or
one that does not carry the secret of the path, is refused before
anything else is looked at."
  (let ((ecc-mcp--session-id (ecc-mcp--session-of-target target)))
    (cond
     ((not (ecc-mcp--host-allowed-p header-lines))
      (ecc-log "mcp" "refused a request for host %S"
               (ecc-mcp--header "Host" header-lines))
      (ecc-mcp--send connection 403 nil))
     ((not (ecc-mcp--target-allowed-p target))
      (ecc-log "mcp" "refused a request for %s" (car (split-string target "?")))
      (ecc-mcp--send connection 404 nil))
     ;; Only POST is implemented; the CLI tries a GET and carries on when
     ;; it is refused (docs/verified.md, 2026-09-05, item 5).
     ((not (equal method "POST"))
      (ecc-mcp--send connection 405 nil))
     (t
      (let* ((request (condition-case error
                          (ecc--json-read (decode-coding-string body 'utf-8))
                        (error
                         (ecc-log "mcp" "unparseable request: %s"
                                  (error-message-string error))
                         nil)))
             (answer (if request
                         (ecc-mcp-handle-request request)
                       (ecc-mcp--error nil -32700 "Parse error"))))
        (if answer
            (ecc-mcp--send connection 200 answer)
          ;; A notification is answered with 202 and no body.
          (ecc-mcp--send connection 202 nil)))))))

(defun ecc-mcp--send (connection status object)
  "Send OBJECT as the JSON body of a STATUS answer on CONNECTION."
  (let* ((body (if object (encode-coding-string (ecc--json-write object) 'utf-8) ""))
         (head (format (concat "HTTP/1.1 %d %s\r\n"
                               "Content-Type: application/json\r\n"
                               "Content-Length: %d\r\n"
                               "Connection: keep-alive\r\n\r\n")
                       status
                       (pcase status (200 "OK") (202 "Accepted")
                              (403 "Forbidden") (404 "Not Found")
                              (405 "Method Not Allowed") (_ "Error"))
                       (length body))))
    (when (process-live-p connection)
      (process-send-string connection (concat head body)))
    body))

;;;; Registering the server with a session (FR-MCP-1)

(defun ecc-mcp-url (session)
  "Return the URL the CLI of SESSION reaches this server at.
The path carries the secret of this server and the query string the
session id, which is how a tool knows whose project to run in."
  (format "http://%s:%s%s?session=%s"
          ecc-mcp-host (ecc-mcp-listening-port) (ecc-mcp-path)
          (ecc-session-id session)))

(defun ecc-mcp-config (session)
  "Return the --mcp-config argument for SESSION, or nil when MCP is off.
Starts the server when it is not running yet."
  (when (ecc-model-option session :mcp ecc-mcp-enabled)
    (ecc-mcp-start)
    (when (ecc-mcp-running-p)
      (ecc--json-write
       `((mcpServers . ((,(intern ecc-mcp-server-name)
                         . ((type . "http") (url . ,(ecc-mcp-url session)))))))))))

(setq ecc-mcp-config-function #'ecc-mcp-config)

;;;; The built-in tools (FR-MCP-1)

(declare-function xref-find-backend "xref" ())
(declare-function xref-backend-references "xref" (backend identifier))
(declare-function xref-backend-apropos "xref" (backend pattern))
(declare-function xref-item-summary "xref" (item))
(declare-function xref-item-location "xref" (item))
(declare-function xref-location-group "xref" (location))
(declare-function xref-location-line "xref" (location))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-text "flymake" (diagnostic))
(declare-function flymake-diagnostic-type "flymake" (diagnostic))
(declare-function flymake-diagnostic-beg "flymake" (diagnostic))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(declare-function project-files "project" (project &optional dirs))
(declare-function treesit-parser-list "treesit" (&optional buffer language tag))
(declare-function treesit-parser-language "treesit" (parser))
(declare-function treesit-buffer-root-node "treesit" (&optional language))
(declare-function treesit-node-type "treesit" (node))
(declare-function treesit-node-child-count "treesit" (node &optional named))
(declare-function treesit-node-child "treesit" (node n &optional named))
(declare-function treesit-node-start "treesit" (node))
(declare-function treesit-node-at "treesit" (pos &optional parser-or-lang named))

(defun ecc-mcp--visit (file)
  "Return a buffer visiting FILE, opening it when it is not open yet.
Signals when FILE does not exist: a tool that quietly answers about
nothing is worse than one that says what went wrong."
  (let ((path (expand-file-name file (ecc-mcp-directory))))
    (unless (file-readable-p path)
      (error "No such file: %s" path))
    (or (find-buffer-visiting path)
        (find-file-noselect path t))))

(defun ecc-mcp--lines (strings)
  "Return STRINGS as lines, cut to `ecc-mcp-max-results' with a note."
  (let ((total (length strings)))
    (if (zerop total)
        "(nothing found)"
      (concat (string-join (seq-take strings ecc-mcp-max-results) "\n")
              (when (> total ecc-mcp-max-results)
                (format "\n… %d more" (- total ecc-mcp-max-results)))))))

(defun ecc-mcp--xref-line (item)
  "Return the one line description of the xref ITEM."
  (let ((location (xref-item-location item)))
    (format "%s:%s: %s"
            (or (xref-location-group location) "?")
            (or (xref-location-line location) 0)
            (string-trim (or (xref-item-summary item) "")))))

(defun ecc-mcp-xref-find-references (identifier file)
  "Return where IDENTIFIER is used, as seen from FILE.
FILE decides which xref backend answers, so a reference search in a
Lisp file is not answered by the backend of some other language."
  (require 'xref)
  (with-current-buffer (if (and file (not (string-empty-p file)))
                           (ecc-mcp--visit file)
                         (current-buffer))
    (let* ((backend (or (xref-find-backend)
                        (error "No xref backend for %s" major-mode)))
           (items (xref-backend-references backend identifier)))
      (ecc-mcp--lines (mapcar #'ecc-mcp--xref-line items)))))

(defun ecc-mcp-xref-find-apropos (pattern file)
  "Return the symbols matching PATTERN, as seen from FILE."
  (require 'xref)
  (with-current-buffer (if (and file (not (string-empty-p file)))
                           (ecc-mcp--visit file)
                         (current-buffer))
    (let* ((backend (or (xref-find-backend)
                        (error "No xref backend for %s" major-mode)))
           (items (xref-backend-apropos backend pattern)))
      (ecc-mcp--lines (mapcar #'ecc-mcp--xref-line items)))))

(defun ecc-mcp-imenu-symbols (file)
  "Return the symbols imenu finds in FILE, one per line."
  (with-current-buffer (ecc-mcp--visit file)
    (let ((index (condition-case nil
                     (let ((imenu-auto-rescan t))
                       (imenu--make-index-alist t))
                   (error nil))))
      (ecc-mcp--lines (ecc-mcp--flatten-imenu index "")))))

(defun ecc-mcp--flatten-imenu (index prefix)
  "Return the entries of the imenu INDEX as lines, named under PREFIX."
  (let (lines)
    (dolist (entry index)
      (cond
       ((not (consp entry)) nil)
       ((equal (car entry) "*Rescan*") nil)
       ((and (consp (cdr entry)) (listp (cdr entry)) (consp (cadr entry)))
        (setq lines (append lines
                            (ecc-mcp--flatten-imenu
                             (cdr entry) (concat prefix (car entry) " / ")))))
       (t
        (let ((position (if (markerp (cdr entry))
                            (marker-position (cdr entry))
                          (cdr entry))))
          (push (format "%s%s: line %s" prefix (car entry)
                        (if (numberp position)
                            (line-number-at-pos position t)
                          "?"))
                lines)))))
    (nreverse lines)))

(defun ecc-mcp-treesit-info (file line)
  "Return what tree-sitter knows about FILE, around LINE when given."
  (with-current-buffer (ecc-mcp--visit file)
    (if (not (and (fboundp 'treesit-parser-list) (treesit-parser-list)))
        (format "%s has no tree-sitter parser (mode %s)" file major-mode)
      (let* ((languages (mapcar #'treesit-parser-language (treesit-parser-list)))
             (root (treesit-buffer-root-node))
             (children (let (types)
                         (dotimes (n (treesit-node-child-count root t))
                           (let ((child (treesit-node-child root n t)))
                             (push (format "%s at line %s"
                                           (treesit-node-type child)
                                           (line-number-at-pos
                                            (treesit-node-start child) t))
                                   types)))
                         (nreverse types))))
        (concat (format "languages: %s\n"
                        (string-join (mapcar #'symbol-name languages) ", "))
                (when (and line (> line 0))
                  (save-excursion
                    (goto-char (point-min))
                    (forward-line (1- line))
                    (format "node at line %s: %s\n" line
                            (treesit-node-type
                             (treesit-node-at (point))))))
                (ecc-mcp--lines children))))))

(defun ecc-mcp-project-info ()
  "Return what Emacs knows about the project of the session."
  (ecc-mcp-with-project
    (require 'project)
    (let* ((project (project-current nil default-directory))
           (root (if project (project-root project) default-directory))
           (files (and project
                       (condition-case nil (project-files project) (error nil))))
           (open (seq-filter (lambda (buffer)
                               (when-let* ((name (buffer-file-name buffer)))
                                 (string-prefix-p (expand-file-name root) name)))
                             (buffer-list))))
      (string-join
       (list (format "root: %s" (abbreviate-file-name root))
             (format "vc backend: %s"
                     (or (ignore-errors (vc-responsible-backend root)) "none"))
             (format "files: %s" (if files (length files) "unknown"))
             (format "open in Emacs: %s"
                     (or (string-join
                          (mapcar (lambda (buffer)
                                    (file-relative-name (buffer-file-name buffer)
                                                        root))
                                  (seq-take open ecc-mcp-max-results))
                          ", ")
                         "nothing")))
       "\n"))))

(defun ecc-mcp-diagnostics (file)
  "Return the flymake or flycheck diagnostics of FILE, one per line."
  (with-current-buffer (ecc-mcp--visit file)
    (cond
     ((and (bound-and-true-p flymake-mode) (fboundp 'flymake-diagnostics))
      (ecc-mcp--lines
       (mapcar (lambda (diagnostic)
                 (format "%s:%s: %s: %s"
                         (file-name-nondirectory file)
                         (line-number-at-pos (flymake-diagnostic-beg diagnostic) t)
                         (flymake-diagnostic-type diagnostic)
                         (flymake-diagnostic-text diagnostic)))
               (flymake-diagnostics))))
     ((bound-and-true-p flycheck-current-errors)
      (ecc-mcp--lines
       (mapcar (lambda (error) (format "%s" error))
               (symbol-value 'flycheck-current-errors))))
     (t (format "%s: no checker is running in this buffer" file)))))

(defun ecc-mcp-execute-code (code)
  "Read and evaluate CODE in the project of the session (FR-MCP-3)."
  (unless ecc-mcp-enable-execute-code
    (error "Evaluating Elisp is disabled; see `ecc-mcp-enable-execute-code'"))
  (ecc-mcp-with-project
    (format "%S" (eval (car (read-from-string code)) t))))

(defun ecc-mcp-register-builtin-tools ()
  "Register the tools Emacs offers out of the box (FR-MCP-1)."
  (ecc-mcp-define-tool
   :name "xref_find_references"
   :description "Find every use of a symbol in the project, with xref.  \
Answers with one line per reference: file, line and the text of the line."
   :args '(("symbol" "string" "The identifier to look for" t)
           ("file" "string" "A file of the language in question, \
relative to the project root; it decides which xref backend answers"))
   :function #'ecc-mcp-xref-find-references)
  (ecc-mcp-define-tool
   :name "xref_find_apropos"
   :description "Find the symbols of the project whose name matches a \
pattern, with xref."
   :args '(("pattern" "string" "The pattern to match, as xref apropos takes it" t)
           ("file" "string" "A file of the language in question, \
relative to the project root"))
   :function #'ecc-mcp-xref-find-apropos)
  (ecc-mcp-define-tool
   :name "imenu_list_symbols"
   :description "List the definitions of a file the way imenu sees them: \
functions, variables, classes, sections, with the line each starts on."
   :args '(("file" "string" "The file, relative to the project root" t))
   :function #'ecc-mcp-imenu-symbols)
  (ecc-mcp-define-tool
   :name "treesit_info"
   :description "Report the tree-sitter parse of a file: the languages of \
its parsers, its top level nodes, and the node at a line."
   :args '(("file" "string" "The file, relative to the project root" t)
           ("line" "integer" "A line to report the node of, one based"))
   :function #'ecc-mcp-treesit-info)
  (ecc-mcp-define-tool
   :name "project_info"
   :description "Report the project Emacs is working in: its root, its \
version control backend, how many files it holds and which are open."
   :args nil
   :function #'ecc-mcp-project-info)
  (ecc-mcp-define-tool
   :name "get_diagnostics"
   :description "Report the diagnostics flymake or flycheck has for a \
file: the errors and warnings the checkers of Emacs found."
   :args '(("file" "string" "The file, relative to the project root" t))
   :function #'ecc-mcp-diagnostics)
  (ecc-mcp-define-tool
   :name "execute_code"
   :description "Evaluate an Emacs Lisp expression in this Emacs and \
return what it returned.  Disabled unless the user turned it on."
   :args '(("code" "string" "The expression to evaluate" t))
   :function #'ecc-mcp-execute-code))

(ecc-mcp-register-builtin-tools)

(provide 'ecc-mcp)

;;; ecc-mcp.el ends here
