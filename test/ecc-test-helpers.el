;;; ecc-test-helpers.el --- Shared helpers for the ecc test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Fixture loading, snapshot comparison and buffer inspection used by the
;; ERT suites.  Fixtures are whole recordings of the CLI stream-json
;; output, one JSON object per line; see scripts/record-fixture.sh.
;;
;; `ecc-test-feed-fixture' takes the handler to run on each parsed
;; message; from phase 1 on that is usually a closure over `ecc-dispatch'
;; and a session made by `ecc-test-with-fake-session'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-diff)
(require 'ecc-dispatch)

(defconst ecc-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding the ecc test suite.")

(defun ecc-test-fixture-file (name)
  "Return the absolute path of fixture NAME.
NAME may be given with or without the .jsonl extension."
  (expand-file-name (if (string-suffix-p ".jsonl" name) name (concat name ".jsonl"))
                    (expand-file-name "fixtures" ecc-test-directory)))

(defun ecc-test-fixture-lines (name)
  "Return the non-empty lines of fixture NAME as a list of strings."
  (let ((file (ecc-test-fixture-file name)))
    (unless (file-exists-p file)
      (error "No such fixture: %s" file))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (seq-remove #'string-empty-p
                  (split-string (buffer-string) "\n" t "[ \t\r]+")))))

(defun ecc-test-fixture-messages (name)
  "Return the parsed messages of fixture NAME as a list of alists."
  (mapcar #'ecc-protocol-parse-line (ecc-test-fixture-lines name)))

(defun ecc-test-fixture-names ()
  "Return the names of every recorded fixture, sorted."
  (sort (mapcar #'file-name-nondirectory
                (directory-files (expand-file-name "fixtures" ecc-test-directory)
                                 t "\\.jsonl\\'"))
        #'string<))

(defun ecc-test-feed-fixture (name handler)
  "Call HANDLER with each parsed message of fixture NAME, in order.
Returns the list of HANDLER return values."
  (mapcar handler (ecc-test-fixture-messages name)))

(defun ecc-test-find-message (name predicate)
  "Return the first message of fixture NAME satisfying PREDICATE."
  (seq-find predicate (ecc-test-fixture-messages name)))

(defun ecc-test-buffer-string (&optional buffer)
  "Return the text of BUFFER, or the current buffer, without properties."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ecc-test-log-string (buffer)
  "Return the text of the log BUFFER without the time stamps."
  (replace-regexp-in-string "^[0-9:.]+ " "" (ecc-test-buffer-string buffer)))

;;;; Sessions without a process (plan section 8)

(defvar ecc-test-sent nil
  "JSON objects the session under test sent, most recent first.")

(defun ecc-test-sent-messages ()
  "Return what the session under test sent, in the order it was sent."
  (reverse ecc-test-sent))

(defun ecc-test-cleanup-session (session)
  "Kill every buffer SESSION created."
  (dolist (buffer (list (ecc-session-buffer session)
                        (ecc-session-prompt-buffer session)
                        (ecc-session-stream-buffer session)
                        (get-buffer (ecc-log-buffer-name (ecc-session-name session)))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defmacro ecc-test-with-fake-session (var &rest body)
  "Run BODY with VAR bound to a registered session that has no process.
Everything the session sends is collected in `ecc-test-sent' instead of
reaching a process, and the session registry is emptied afterwards so
that tests cannot see each other."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((ecc-test-sent nil)
          (ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-render-debounce 0)
          (,var (ecc-model-create-session
                 :name "test"
                 :project-root temporary-file-directory)))
     (unwind-protect
         (cl-letf (((symbol-function #'ecc-proc-send-json)
                    (lambda (_session object) (push object ecc-test-sent) object))
                   ;; Recorded paths may or may not exist on this machine;
                   ;; the diffs of a replay must not depend on that.
                   ((symbol-function #'ecc-diff-file-content)
                    (lambda (_path) nil)))
           ,@body)
       (ecc-test-cleanup-session ,var))))

(defun ecc-test-dispatch (session name &optional prompt)
  "Feed every line of fixture NAME to SESSION through `ecc-dispatch'.
PROMPT, when given, opens the turn the recording answers, the way
sending a prompt from Emacs would."
  (when prompt
    (ecc-model-begin-turn session prompt))
  (dolist (line (ecc-test-fixture-lines name))
    (ecc-dispatch session (ecc-protocol-parse-line line)))
  session)

(defun ecc-test-add-request (session &optional name input)
  "Add a pending request for tool NAME with INPUT to SESSION and return it.
NAME defaults to Write and INPUT to a small Write of /tmp/a.txt; the
kind follows the tool the way `ecc-dispatch' decides it."
  (let* ((tool (or name "Write"))
         (node (ecc-model-add-node session
                                   :type (ecc-dispatch--request-kind tool)
                                   :status 'pending))
         (request (make-ecc-request
                   :request-id (format "req-%d" (hash-table-count (ecc-session-nodes session)))
                   :session session
                   :kind (ecc-dispatch--request-kind tool)
                   :tool-name tool :display-name tool
                   :input (or input '((file_path . "/tmp/a.txt") (content . "hi")))
                   :tool-use-id (format "toolu_%d" (hash-table-count (ecc-session-nodes session)))
                   :created-at (current-time)
                   :node node)))
    (ecc-model-node-put node 'request request)
    (ecc-model-add-request session request)
    request))

(defun ecc-test-feed-until-request (session name prompt)
  "Feed fixture NAME to SESSION under PROMPT up to its first can_use_tool.
Returns the pending request."
  (ecc-model-begin-turn session prompt)
  (let ((lines (ecc-test-fixture-lines name))
        (request nil))
    (while (and lines (null request))
      (let ((message (ecc-protocol-parse-line (pop lines))))
        (ecc-dispatch session message)
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          (setq request (car (ecc-session-pending session))))))
    request))

(defun ecc-test-response (n)
  "Return the inner response of the Nth message sent, oldest first."
  (alist-get 'response (alist-get 'response (nth n (ecc-test-sent-messages)))))

(defun ecc-test-node-types (nodes)
  "Return the list of types of NODES."
  (mapcar #'ecc-node-type nodes))

(defun ecc-test-node-shape (nodes)
  "Return the types of NODES, nesting the children of each."
  (mapcar (lambda (node)
            (if (ecc-node-children node)
                (cons (ecc-node-type node)
                      (ecc-test-node-shape (ecc-node-children node)))
              (ecc-node-type node)))
          nodes))

(defun ecc-test-turn-shape (turn)
  "Return the types of the children of TURN, nesting steps and tools."
  (ecc-test-node-shape (ecc-turn-children turn)))

;;;; Snapshots (plan section 8)

(defun ecc-test-snapshot-file (name)
  "Return the absolute path of snapshot NAME."
  (expand-file-name (concat name ".txt")
                    (expand-file-name "snapshots" ecc-test-directory)))

(defun ecc-test-snapshot (name actual)
  "Compare ACTUAL against snapshot NAME and return non-nil when equal.
Setting the environment variable ECC_UPDATE_SNAPSHOTS to a non-empty
value rewrites the snapshot instead of comparing, and a missing snapshot
is always written.  A mismatch also leaves the new text in NAME.new for
inspection."
  (let ((file (ecc-test-snapshot-file name))
        (update (not (string-empty-p (or (getenv "ECC_UPDATE_SNAPSHOTS") "")))))
    (make-directory (file-name-directory file) t)
    (cond
     ((or update (not (file-exists-p file)))
      (with-temp-file file (insert actual))
      t)
     (t
      (let ((expected (with-temp-buffer
                        (let ((coding-system-for-read 'utf-8-unix))
                          (insert-file-contents file))
                        (buffer-string))))
        (or (equal expected actual)
            (progn (with-temp-file (concat file ".new") (insert actual))
                   nil)))))))

(provide 'ecc-test-helpers)

;;; ecc-test-helpers.el ends here
