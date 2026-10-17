;;; ecc-peer-test.el --- Tests for ecc-peer  -*- lexical-binding: t; -*-

;;; Commentary:

;; The sessions a prompt can name with `@session:NAME', what a message
;; from another session becomes in the transcript, and what a session
;; handed work is told about the one that handed it.
;;
;; The running sessions are files in a registry directory of the test's
;; own, written the way the CLI writes them (2.1.296), with the processes
;; taken for alive.  Everything here spans sessions, so every test has
;; two or more.
;;
;; test/fixtures/peer-message.jsonl is the stream a stream-json client
;; got when another session sent it a message with SendMessage (CLI
;; 2.1.296, 2026-10-17): the echoed message, the answer and the result.
;; The sender's process id and name were replaced with 4242 and
;; parent-4b.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-peer)
(require 'ecc-prompt)
(require 'ecc-history)
(require 'ecc-render)

(defmacro ecc-peer-test--with-registry (var &rest body)
  "Run BODY with VAR bound to an empty registry directory of its own.
The processes it names are taken for alive."
  (declare (indent 1))
  `(let* ((,var (make-temp-file "ecc-peer-registry" t))
          (ecc-registry-directory ,var)
          (ecc-registry-check-process nil))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-peer-test--write (directory pid session-id name &rest fields)
  "Write the session file of PID, running SESSION-ID as NAME, into DIRECTORY.
It has a socket unless FIELDS says `:socket nil'; the rest of FIELDS
is a plist of keys of the file, written as they are named."
  (let* ((socket (if (plist-member fields :socket)
                     (plist-get fields :socket)
                   (format "/tmp/cc-socks/%d.sock" pid)))
         (fields (cl-loop for (key value) on fields by #'cddr
                          unless (eq key :socket)
                          collect (cons key value)))
         ;; What FIELDS says comes first, so that it is what is read.
         (entry (append fields
                        (list (cons 'pid pid)
                              (cons 'sessionId session-id)
                              (cons 'name name)
                              (cons 'startedAt pid)
                              (cons 'status "idle")
                              (cons 'entrypoint "sdk-cli"))
                        (and socket (list (cons 'messagingSocketPath socket))))))
    (with-temp-file (expand-file-name (format "%d.json" pid) directory)
      (insert (ecc--json-write entry)))))

(defun ecc-peer-test--names (self)
  "Return the names of the sessions SELF can send a message to."
  (mapcar (lambda (candidate) (alist-get 'name candidate))
          (ecc-peer-candidates self)))

;;;; Who can be talked to

(ert-deftest ecc-peer-test-candidates ()
  "The sessions that take messages, by the name the user knows, less SELF.
A session of this Emacs goes by its own name, not the one its CLI
derived; one elsewhere by the CLI's.  The usage probe and a CLI that
names no socket are nobody to talk to."
  (ecc-test-with-fake-session self
    (ecc-peer-test--with-registry directory
      (let ((other (ecc-model-create-session :name "feat/b"
                                             :project-root "/tmp/repo-b/"))
            (probe (ecc-model-create-session :name "probe"
                                             :options '(:usage-probe t))))
        (ecc-peer-test--write directory 101 (ecc-session-id self) "test-a1")
        (ecc-peer-test--write directory 102 (ecc-session-id other) "repo-b-2c")
        (ecc-peer-test--write directory 103 (ecc-session-id probe) "probe-3d")
        (ecc-peer-test--write directory 104 "external-d" "term-d"
                              'cwd "/tmp/elsewhere" 'entrypoint "cli" 'status "busy")
        (ecc-peer-test--write directory 105 "old-e" "old-e" :socket nil)
        (should (equal (ecc-peer-test--names self) '("feat/b" "term-d")))
        ;; Seen from the other one, the first is a candidate in its turn.
        (should (equal (ecc-peer-test--names other) '("test" "term-d")))
        (let ((here (ecc-peer-resolve "feat/b" self))
              (there (ecc-peer-resolve "term-d" self)))
          (should (eq (alist-get 'session here) other))
          (should (equal (alist-get 'address here) "uds:/tmp/cc-socks/102.sock"))
          (should-not (alist-get 'session there))
          (should (string-search "/tmp/repo-b" (ecc-peer-annotation here)))
          (should (string-search "here" (ecc-peer-annotation here)))
          (should (string-search "/tmp/elsewhere" (ecc-peer-annotation there)))
          (should (string-search "busy" (ecc-peer-annotation there)))
          (should (string-search "terminal" (ecc-peer-annotation there)))
          ;; The label names the address, and the name ListAgents knows
          ;; when it is not the one the user wrote.
          (should (equal (ecc-peer-label here)
                         (concat "the Claude session `feat/b` (reach it with SendMessage"
                                 " to `uds:/tmp/cc-socks/102.sock`; ListAgents lists"
                                 " it as `repo-b-2c`)")))
          (should-not (string-search "ListAgents" (ecc-peer-label there))))
        (should-not (ecc-peer-resolve "probe" self))
        (should-not (ecc-peer-resolve "test" self))))))

(ert-deftest ecc-peer-test-a-taken-name-gets-its-pid ()
  "Two sessions called the same are told apart by the process of the second."
  (ecc-test-with-fake-session self
    (ecc-peer-test--with-registry directory
      (let ((other (ecc-model-create-session :name "review")))
        (ecc-peer-test--write directory 102 (ecc-session-id other) "repo-2c")
        ;; A terminal session the user renamed to the same name.
        (ecc-peer-test--write directory 107 "external" "review")
        (should (equal (ecc-peer-test--names self) '("review" "review<107>")))
        (should (eq (alist-get 'session (ecc-peer-resolve "review" self)) other))
        (should (equal (alist-get 'address (ecc-peer-resolve "review<107>" self))
                       "uds:/tmp/cc-socks/107.sock"))))))

;;;; A message from another session

(ert-deftest ecc-peer-test-message-opens-a-turn-named-after-its-sender ()
  "A message another session sent is the prompt of the turn it starts.
Its body is the prompt and the sender is on the turn, by the name it
has in this Emacs while its process can be found, and by the CLI's
otherwise."
  (ecc-test-with-fake-session session
    (ecc-peer-test--with-registry directory
      (let ((parent (ecc-model-create-session :name "feat/parent")))
        (ecc-peer-test--write directory 4242 (ecc-session-id parent) "parent-4b")
        (ecc-test-dispatch session "peer-message")
        (let ((turn (car (ecc-session-turns session))))
          (should (= 1 (length (ecc-session-turns session))))
          (should (equal (ecc-turn-prompt turn)
                         "Capture test: reply with the single word ack. 日本語の本文もここに。"))
          (should (equal (alist-get 'from (ecc-turn-sender turn))
                         "uds:/tmp/cc-socks/4242.sock"))
          (should (equal (ecc-model-sender-name (ecc-turn-sender turn)) "feat/parent"))
          ;; The result closed it, as it would a prompt sent from here.
          (should-not (ecc-session-current-turn session))
          (should (equal (ecc-test-turn-shape turn) '(text result)))))
      ;; Sent by a session this Emacs does not run, or no longer can find.
      (delete-file (expand-file-name "4242.json" directory))
      (ecc-test-dispatch session "peer-message")
      (should (equal (ecc-model-sender-name
                      (ecc-turn-sender (cadr (ecc-session-turns session))))
                     "parent-4b")))))

(ert-deftest ecc-peer-test-message-into-a-prompted-turn-is-a-note ()
  "A message that finds a turn prompted already is kept in it as a note."
  (ecc-test-with-fake-session session
    (ecc-peer-test--with-registry _directory
      (ecc-test-dispatch session "peer-message" "hello")
      (let ((turn (car (ecc-session-turns session))))
        (should (= 1 (length (ecc-session-turns session))))
        (should (equal (ecc-turn-prompt turn) "hello"))
        (should-not (ecc-turn-sender turn))
        (should (string-prefix-p "Message from parent-4b:\nCapture test"
                                 (ecc-model-node-get (car (ecc-turn-children turn))
                                                     'text)))))))

(ert-deftest ecc-peer-test-recorded-message-reads-back-as-one ()
  "A recording read back draws a message from another session as the stream does.
The recording marks it `isMeta', which on any other line says it is no
prompt, and names the sender in `origin'."
  (ecc-test-with-fake-session session
    (ecc-peer-test--with-registry _directory
      (let* ((text (concat "Another Claude session sent a message:\n"
                           "<cross-session-message from=\"uds:/tmp/cc-socks/4242.sock\""
                           " from-name=\"parent-4b\" from-mode=\"prompting\">\n"
                           "見直してください。\n</cross-session-message>\n\n"
                           "This came from another Claude session."))
             (lines (list (ecc--json-write
                           `((type . "user") (isMeta . t) (uuid . "u1")
                             (timestamp . "2026-10-16T05:51:02.839Z")
                             (origin . ((kind . "peer")
                                        (from . "uds:/tmp/cc-socks/4242.sock")
                                        (name . "parent-4b") (fromMode . "prompting")
                                        (body . "見直してください。")))
                             (message . ((role . "user") (content . ,text)))))
                          (ecc--json-write
                           '((type . "assistant") (uuid . "u2")
                             (message . ((role . "assistant") (id . "m1")
                                         (content . [((type . "text")
                                                      (text . "見直しました。"))]))))))))
        (should (equal (ecc-history-turn-starts lines) '(0)))
        (ecc-history--replay session lines)
        (let ((turn (car (ecc-session-turns session))))
          (should (equal (ecc-turn-prompt turn) "見直してください。"))
          (should (equal (ecc-model-sender-name (ecc-turn-sender turn)) "parent-4b")))))))

;;;; A session handed work by another

(ert-deftest ecc-peer-test-parent-paragraph ()
  "A session handed work is told where the session that handed it is.
Nothing is said when the registry has no socket for it."
  (ecc-test-with-fake-session parent
    (ecc-peer-test--with-registry directory
      (let ((child (ecc-model-create-session :name "feat/child")))
        (ecc-peer-test--write directory 102 (ecc-session-id child) "child-2c")
        (should-not (ecc-peer-parent-paragraph parent))
        (ecc-peer-test--write directory 101 (ecc-session-id parent) "repo-a1"
                              :socket nil)
        (should-not (ecc-peer-parent-paragraph parent))
        (ecc-peer-test--write directory 101 (ecc-session-id parent) "repo-a1")
        (let ((paragraph (ecc-peer-parent-paragraph parent)))
          (should (string-search "`test`" paragraph))
          (should (string-search "SendMessage to `uds:/tmp/cc-socks/101.sock`" paragraph))
          (should (string-search "ListAgents, which listed it as `repo-a1`" paragraph))
          (should-not (string-search "102" paragraph)))))))

(provide 'ecc-peer-test)

;;; ecc-peer-test.el ends here
