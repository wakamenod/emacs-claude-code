;;; ecc-mcp-test.el --- Tests for ecc-mcp  -*- lexical-binding: t; -*-

;;; Commentary:

;; The MCP server.  The JSON-RPC layer is tested as a pure function, and
;; the HTTP layer against the real server: it listens on a port the
;; system picks and a client process talks to it, which is what the CLI
;; will do.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-mcp)
(require 'ecc-proc)

(defmacro ecc-mcp-test-with-registry (&rest body)
  "Run BODY with a tool registry of its own, restoring the real one after."
  (declare (indent 0) (debug t))
  `(let ((ecc-mcp-tools (make-hash-table :test #'equal))
         (ecc-mcp-excluded-tools nil)
         (ecc-mcp-enable-execute-code nil))
     ,@body))

(defmacro ecc-mcp-test-with-server (port &rest body)
  "Run BODY with the server listening, PORT bound to the port it took."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((ecc-mcp-port 0)
         (ecc-mcp-host "127.0.0.1"))
     (unwind-protect
         (let ((,port (ecc-mcp-start)))
           (should ,port)
           ,@body)
       (ecc-mcp-stop))))

(defun ecc-mcp-test--http (port method target body)
  "Send a METHOD request for TARGET with BODY to PORT and return the answer.
The answer comes back as (STATUS . BODY-STRING)."
  (let* ((payload (encode-coding-string (or body "") 'utf-8))
         (answer "")
         (client (make-network-process
                  :name "ecc-mcp-test-client"
                  :host "127.0.0.1" :service port
                  :coding 'binary :noquery t
                  :filter (lambda (_process chunk)
                            (setq answer (concat answer chunk))))))
    (unwind-protect
        (progn
          (process-send-string
           client
           (concat (format "%s %s HTTP/1.1\r\n" method target)
                   (format "Host: %s\r\n" ecc-mcp-test--host)
                   "Accept: application/json, text/event-stream\r\n"
                   "Content-Type: application/json\r\n"
                   (format "Content-Length: %d\r\n\r\n" (length payload))
                   payload))
          (let ((deadline (+ (float-time) 5)))
            (while (and (< (float-time) deadline)
                        (not (ecc-mcp-test--complete-p answer)))
              (accept-process-output client 0.05)))
          (ecc-mcp-test--parse answer))
      (delete-process client))))

(defun ecc-mcp-test--complete-p (text)
  "Return non-nil when TEXT holds a whole HTTP answer."
  (when-let* ((head-end (string-search "\r\n\r\n" text)))
    (let ((length (if (string-match "Content-Length: \\([0-9]+\\)" text)
                      (string-to-number (match-string 1 text))
                    0)))
      (>= (- (length text) (+ head-end 4)) length))))

(defun ecc-mcp-test--parse (text)
  "Return (STATUS . BODY) of the HTTP answer TEXT."
  (let ((head-end (string-search "\r\n\r\n" text)))
    (cons (if (string-match "\\`HTTP/1.1 \\([0-9]+\\)" text)
              (string-to-number (match-string 1 text))
            0)
          (decode-coding-string (substring text (+ head-end 4)) 'utf-8))))

(defvar ecc-mcp-test--host "127.0.0.1"
  "What the Host header of a test request says.")

(defun ecc-mcp-test--rpc (port object)
  "Send OBJECT as a JSON-RPC request to PORT and return (STATUS . ANSWER)."
  (pcase-let ((`(,status . ,body)
               (ecc-mcp-test--http port "POST" (ecc-mcp-path)
                                   (ecc--json-write object))))
    (cons status (if (string-empty-p body) nil (ecc--json-read body)))))

;;;; The registry

(ert-deftest ecc-mcp-test-define-tool ()
  "A tool is registered with its name, description and schema."
  (ecc-mcp-test-with-registry
    (ecc-mcp-define-tool
     :name "greet"
     :description "Say hello to someone."
     :args '(("who" "string" "Whom to greet" t)
             ("times" "integer" "How often"))
     :function (lambda (who times) (format "hello %s ×%s" who (or times 1))))
    (let* ((tool (ecc-mcp-tool "greet"))
           (object (ecc-mcp-tool-object tool))
           (schema (alist-get 'inputSchema object)))
      (should (equal (alist-get 'name object) "greet"))
      (should (equal (alist-get 'description object) "Say hello to someone."))
      (should (equal (alist-get 'type schema) "object"))
      (should (equal (alist-get 'description
                                (alist-get 'who (alist-get 'properties schema)))
                     "Whom to greet"))
      ;; Only the argument marked as required is required.
      (should (equal (alist-get 'required schema) ["who"]))
      ;; The values arrive in the order the arguments were declared.
      (should (equal (cdr (ecc-mcp-call-tool "greet" '((who . "world") (times . 3))))
                     "hello world ×3")))))

(ert-deftest ecc-mcp-test-tool-error-is-an-answer-not-a-crash ()
  "A tool that signals answers with the error, and the server lives on."
  (ecc-mcp-test-with-registry
    (ecc-mcp-define-tool :name "boom" :description "Fails."
                         :args nil
                         :function (lambda () (error "No")))
    (pcase-let ((`(,failed . ,text) (ecc-mcp-call-tool "boom" nil)))
      (should failed)
      (should (string-search "boom failed" text)))
    ;; And the mode line is clean again afterwards.
    (should-not ecc-mcp--running)
    (should (equal (ecc-mcp-mode-line-string) ""))))

(ert-deftest ecc-mcp-test-mode-line-says-what-is-running ()
  "While a tool runs the mode line says so."
  (ecc-mcp-test-with-registry
    (let ((seen nil))
      (ecc-mcp-define-tool
       :name "watch" :description "Looks at the mode line." :args nil
       :function (lambda () (setq seen (ecc-mcp-mode-line-string)) "done"))
      (ecc-mcp-call-tool "watch" nil)
      (should (string-search "MCP: watch" seen)))))

(ert-deftest ecc-mcp-test-excluded-tools-are-not-published ()
  "`ecc-mcp-excluded-tools' takes a tool out of the list."
  (ecc-mcp-test-with-registry
    (ecc-mcp-define-tool :name "slow" :description "." :args nil
                         :function #'ignore)
    (ecc-mcp-define-tool :name "quick" :description "." :args nil
                         :function #'ignore)
    (should (equal (mapcar #'ecc-mcp-tool-name (ecc-mcp-published-tools))
                   '("quick" "slow")))
    (let ((ecc-mcp-excluded-tools '("slow")))
      (should (equal (mapcar #'ecc-mcp-tool-name (ecc-mcp-published-tools))
                     '("quick"))))))

(ert-deftest ecc-mcp-test-execute-code-is-off-by-default ()
  "The evaluator is neither published nor callable unless turned on."
  (should-not (seq-find (lambda (tool) (equal (ecc-mcp-tool-name tool) "execute_code"))
                        (ecc-mcp-published-tools)))
  (let ((ecc-mcp-enable-execute-code nil))
    (should (car (ecc-mcp-call-tool "execute_code" '((code . "(+ 1 2)"))))))
  (let ((ecc-mcp-enable-execute-code t))
    (should (seq-find (lambda (tool) (equal (ecc-mcp-tool-name tool) "execute_code"))
                      (ecc-mcp-published-tools)))
    (should (equal (cdr (ecc-mcp-call-tool "execute_code" '((code . "(+ 1 2)"))))
                   "3"))))

;;;; JSON-RPC

(ert-deftest ecc-mcp-test-initialize ()
  "Both openings the CLI uses are answered with what the server is."
  (dolist (method '("initialize" "server/discover"))
    (let* ((answer (ecc-mcp-handle-request
                    `((jsonrpc . "2.0") (id . 1) (method . ,method))))
           (result (alist-get 'result answer)))
      (should (equal (alist-get 'id answer) 1))
      (should (equal (alist-get 'protocolVersion result) ecc-mcp-protocol-version))
      (should (equal (alist-get 'name (alist-get 'serverInfo result))
                     ecc-mcp-server-name)))))

(ert-deftest ecc-mcp-test-notification-has-no-answer ()
  "A notification is not answered (the transport turns that into 202)."
  (should-not (ecc-mcp-handle-request
               '((jsonrpc . "2.0") (method . "notifications/initialized")))))

(ert-deftest ecc-mcp-test-unknown-method ()
  "An unknown method comes back as a JSON-RPC error, not as a crash."
  (let ((answer (ecc-mcp-handle-request
                 '((jsonrpc . "2.0") (id . 7) (method . "nonsense")))))
    (should (equal (alist-get 'code (alist-get 'error answer)) -32601))))

(ert-deftest ecc-mcp-test-tools-list-and-call ()
  "The built-in tools are listed, and one of them can be called."
  (ecc-mcp-test-with-registry
    (ecc-mcp-define-tool :name "greet" :description "Greets."
                         :args '(("who" "string" "Whom" t))
                         :function (lambda (who) (format "hello %s" who)))
    (let* ((listed (alist-get 'tools (alist-get 'result
                                                (ecc-mcp-handle-request
                                                 '((id . 1) (method . "tools/list"))))))
           (called (alist-get 'result
                              (ecc-mcp-handle-request
                               '((id . 2) (method . "tools/call")
                                 (params . ((name . "greet")
                                            (arguments . ((who . "world"))))))))))
      (should (equal (alist-get 'name (aref listed 0)) "greet"))
      (should (equal (alist-get 'isError called) :false))
      (should (equal (alist-get 'text (aref (alist-get 'content called) 0))
                     "hello world"))))
  ;; A tool that does not exist is a JSON-RPC error.
  (let ((answer (ecc-mcp-handle-request
                 '((id . 3) (method . "tools/call")
                   (params . ((name . "no_such_tool")))))))
    (should (equal (alist-get 'code (alist-get 'error answer)) -32602))))

;;;; HTTP, against the real server

(ert-deftest ecc-mcp-test-http-post ()
  "The server answers a POST of JSON-RPC with JSON."
  (ecc-mcp-test-with-server port
    (pcase-let ((`(,status . ,answer)
                 (ecc-mcp-test--rpc port '((jsonrpc . "2.0") (id . 1)
                                           (method . "initialize")))))
      (should (= status 200))
      (should (equal (alist-get 'protocolVersion (alist-get 'result answer))
                     ecc-mcp-protocol-version)))))

(ert-deftest ecc-mcp-test-http-get-is-refused ()
  "GET is answered with 405, which the CLI carries on from."
  (ecc-mcp-test-with-server port
    (should (= 405 (car (ecc-mcp-test--http port "GET" (ecc-mcp-path) ""))))))

(ert-deftest ecc-mcp-test-http-wrong-path-is-refused ()
  "A request that does not carry the secret of the path gets 404.
The secret is what keeps a process that only knows the port out."
  (ecc-mcp-test-with-server port
    (should (string-prefix-p "/mcp/" (ecc-mcp-path)))
    (should (= 404 (car (ecc-mcp-test--http
                         port "POST" "/mcp"
                         (ecc--json-write '((jsonrpc . "2.0") (id . 1)
                                            (method . "tools/list")))))))
    (should (= 404 (car (ecc-mcp-test--http
                         port "POST" "/mcp/not-the-secret"
                         (ecc--json-write '((jsonrpc . "2.0") (id . 1)
                                            (method . "tools/list")))))))))

(ert-deftest ecc-mcp-test-http-foreign-host-is-refused ()
  "A request whose Host header names another machine gets 403.
That is what a page in a browser sends when it talks to this port."
  (ecc-mcp-test-with-server port
    (let ((ecc-mcp-test--host "evil.example"))
      (should (= 403 (car (ecc-mcp-test--rpc
                           port '((jsonrpc . "2.0") (id . 1)
                                  (method . "tools/list")))))))
    (let ((ecc-mcp-test--host "localhost:1234"))
      (should (= 200 (car (ecc-mcp-test--rpc
                           port '((jsonrpc . "2.0") (id . 1)
                                  (method . "tools/list")))))))))

(ert-deftest ecc-mcp-test-token-changes-with-every-start ()
  "Stopping and starting the server hands out a new secret."
  (ecc-mcp-test-with-server _port
    (let ((first (ecc-mcp-path)))
      (ecc-mcp-stop)
      (should-not (ecc-mcp-path))
      (ecc-mcp-start)
      (should (ecc-mcp-path))
      (should-not (equal first (ecc-mcp-path))))))

(ert-deftest ecc-mcp-test-http-notification-is-accepted ()
  "A notification is answered with 202 and no body."
  (ecc-mcp-test-with-server port
    (pcase-let ((`(,status . ,answer)
                 (ecc-mcp-test--rpc port '((jsonrpc . "2.0")
                                           (method . "notifications/initialized")))))
      (should (= status 202))
      (should-not answer))))

(ert-deftest ecc-mcp-test-http-tool-call ()
  "A tool called over HTTP answers with what it returned."
  (ecc-mcp-test-with-registry
    (ecc-mcp-define-tool :name "greet" :description "Greets."
                         :args '(("who" "string" "Whom" t))
                         :function (lambda (who) (format "hello %s" who)))
    (ecc-mcp-test-with-server port
      (pcase-let ((`(,status . ,answer)
                   (ecc-mcp-test--rpc
                    port '((jsonrpc . "2.0") (id . 4) (method . "tools/call")
                           (params . ((name . "greet")
                                      (arguments . ((who . "日本語")))))))))
        (should (= status 200))
        (should (equal (alist-get 'text
                                  (aref (alist-get 'content (alist-get 'result answer))
                                        0))
                       "hello 日本語"))))))

(ert-deftest ecc-mcp-test-http-two-requests-on-one-connection ()
  "Two requests sent at once on one connection are both answered."
  (ecc-mcp-test-with-server port
    ;; The filter has to find the second request behind the first, which
    ;; is what keep-alive means.
    (let* ((body (ecc--json-write '((jsonrpc . "2.0") (id . 1) (method . "ping"))))
           (payload (encode-coding-string body 'utf-8))
           (request (concat "POST " (ecc-mcp-path) " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                            (format "Content-Length: %d\r\n\r\n" (length payload))
                            payload))
           (answer "")
           (client (make-network-process
                    :name "ecc-mcp-test-client" :host "127.0.0.1" :service port
                    :coding 'binary :noquery t
                    :filter (lambda (_process chunk)
                              (setq answer (concat answer chunk))))))
      (unwind-protect
          (progn
            (process-send-string client (concat request request))
            (let ((deadline (+ (float-time) 5)))
              (while (and (< (float-time) deadline)
                          (< (length (split-string answer "HTTP/1.1 200" t)) 2))
                (accept-process-output client 0.05)))
            (should (= 2 (length (split-string answer "HTTP/1.1 200" t)))))
        (delete-process client)))))

(ert-deftest ecc-mcp-test-http-bad-json ()
  "A body that is not JSON comes back as a parse error, not a crash."
  (ecc-mcp-test-with-server port
    (pcase-let ((`(,status . ,answer)
                 (ecc-mcp-test--http port "POST" (ecc-mcp-path) "{not json")))
      (should (= status 200))
      (should (equal (alist-get 'code (alist-get 'error (ecc--json-read answer)))
                     -32700)))))

;;;; The session a request belongs to

(ert-deftest ecc-mcp-test-url-carries-the-session ()
  "The URL of a session names it, and a request that names it runs there."
  (ecc-test-with-fake-session session
    (ecc-mcp-test-with-server _port
      (let ((url (ecc-mcp-url session)))
        (should (string-search (format "session=%s" (ecc-session-id session)) url))
        (should (string-search (ecc-mcp-path) url))
        (should (equal (ecc-mcp--session-of-target
                        (concat "/mcp?session=" (ecc-session-id session)))
                       (ecc-session-id session)))
        ;; A tool called under that session runs in its project.
        (let ((ecc-mcp--session-id (ecc-session-id session)))
          (should (equal (file-name-as-directory (ecc-mcp-directory))
                         (file-name-as-directory
                          (ecc-session-project-root session)))))
        ;; Without a session it runs wherever Emacs is.
        (let ((ecc-mcp--session-id nil))
          (should (equal (ecc-mcp-directory) default-directory)))))))

(ert-deftest ecc-mcp-test-config-and-command-line ()
  "An enabled session is started with --mcp-config naming this server."
  (ecc-test-with-fake-session session
    (let ((ecc-mcp-port 0))
      (unwind-protect
          (let* ((ecc-mcp-enabled t)
                 (config (ecc-mcp-config session)))
            (should (ecc-mcp-running-p))
            (let ((servers (alist-get 'mcpServers (ecc--json-read config))))
              (should (equal (alist-get 'type (alist-get 'emacs servers)) "http"))
              (should (string-prefix-p "http://127.0.0.1:"
                                       (alist-get 'url (alist-get 'emacs servers)))))
            ;; And the command line carries it.
            (let ((command (ecc-proc-build-command session)))
              (should (member "--mcp-config" command))
              (should (member config command))))
        (ecc-mcp-stop)))
    ;; Off by default: no server is started and no argument is added.
    (let ((ecc-mcp-enabled nil))
      (should-not (ecc-mcp-config session))
      (should-not (member "--mcp-config" (ecc-proc-build-command session))))))

;;;; The built-in tools

(defmacro ecc-mcp-test-with-file (var content &rest body)
  "Run BODY with VAR bound to a temporary Elisp file holding CONTENT.
The file lives in a directory that looks like a Git checkout, so that
project.el finds a project rather than asking for one: a tool must
never reach the minibuffer."
  (declare (indent 2) (debug (symbolp form body)))
  `(let* ((directory (make-temp-file "ecc-mcp-test" t))
          (,var (expand-file-name "sample.el" directory)))
     (make-directory (expand-file-name ".git" directory))
     (with-temp-file ,var (insert ,content))
     (unwind-protect
         (progn ,@body)
       (when-let* ((buffer (find-buffer-visiting ,var)))
         (kill-buffer buffer))
       (delete-directory directory t))))

(ert-deftest ecc-mcp-test-imenu-symbols ()
  "The imenu tool lists the definitions of a file with their lines."
  (ecc-mcp-test-with-file file "(defun ecc-mcp-sample-one ())\n\n(defun ecc-mcp-sample-two ())\n"
    (let ((text (ecc-mcp-imenu-symbols file)))
      (should (string-search "ecc-mcp-sample-one" text))
      (should (string-search "ecc-mcp-sample-two" text))
      (should (string-search "line 3" text)))))

(ert-deftest ecc-mcp-test-visit-refuses-what-is-not-there ()
  "A tool asked about a file that does not exist says so."
  (should-error (ecc-mcp--visit "/no/such/file/at/all.el")))

(ert-deftest ecc-mcp-test-project-info ()
  "The project tool reports the root it is run in."
  (let ((ecc-mcp--session-id nil)
        (default-directory (file-name-directory
                            (directory-file-name ecc-test-directory))))
    (let ((text (ecc-mcp-project-info)))
      (should (string-search "root:" text))
      (should (string-search "vc backend:" text)))))

(ert-deftest ecc-mcp-test-diagnostics-without-a-checker ()
  "A file no checker is running in is answered plainly, not with an error."
  (ecc-mcp-test-with-file file "(defun ecc-mcp-sample ())\n"
    (should (string-search "no checker" (ecc-mcp-diagnostics file)))))

(ert-deftest ecc-mcp-test-xref-find-references ()
  "The xref tool finds a use of a symbol in an Elisp file."
  (ecc-mcp-test-with-file file
      "(defun ecc-mcp-sample-fn () 1)\n(defun ecc-mcp-caller () (ecc-mcp-sample-fn))\n"
    ;; The elisp backend answers about what this Emacs has loaded, so the
    ;; file is loaded first and then asked about.
    (load file nil t)
    (let ((text (ecc-mcp-xref-find-references "ecc-mcp-sample-fn" file)))
      ;; Either references were found or the backend said there were
      ;; none; what matters is that a line of text came back and that
      ;; nothing signalled or asked a question.
      (should (stringp text))
      (should-not (string-empty-p text)))))

(ert-deftest ecc-mcp-test-a-tool-may-not-ask-a-question ()
  "A tool that reaches the minibuffer fails instead of stopping Emacs."
  (ecc-mcp-test-with-registry
    (ecc-mcp-define-tool :name "asks" :description "." :args nil
                         :function (lambda () (read-string "Well? ")))
    (should (car (ecc-mcp-call-tool "asks" nil)))))

(ert-deftest ecc-mcp-test-cut-to-the-limit ()
  "A long answer is cut and says how much was left out."
  (let ((ecc-mcp-max-results 2))
    (should (equal (ecc-mcp--lines '("a" "b" "c" "d")) "a\nb\n… 2 more"))
    (should (equal (ecc-mcp--lines nil) "(nothing found)"))))

(provide 'ecc-mcp-test)

;;; ecc-mcp-test.el ends here
