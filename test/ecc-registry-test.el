;;; ecc-registry-test.el --- Tests for ecc-registry  -*- lexical-binding: t; -*-

;;; Commentary:

;; Reading the files Claude Code keeps about the sessions it is running
;; (FR-DASH-2 b, FR-DASH-6).
;;
;; test/fixtures/registry holds three files copied from ~/.claude/sessions
;; on this machine: two sessions of one project and one of another.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-registry)

(defconst ecc-registry-test-directory
  (expand-file-name "fixtures/registry" ecc-test-directory)
  "The recorded session registry.")

(defmacro ecc-registry-test--with-fixture (&rest body)
  "Run BODY with the recorded registry in place.
The processes of a recording are long gone, so their liveness is not
checked; `ecc-registry-test-drops-a-dead-process' covers that."
  `(let ((ecc-registry-directory ecc-registry-test-directory)
         (ecc-registry-check-process nil))
     ,@body))

(defmacro ecc-registry-test--with-temp-registry (var &rest body)
  "Run BODY with VAR bound to an empty registry directory in use."
  (declare (indent 1))
  `(let* ((,var (make-temp-file "ecc-registry" t))
          (ecc-registry-directory ,var))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-registry-test--write (directory pid session-id &rest fields)
  "Write a session file for PID and SESSION-ID into DIRECTORY.
FIELDS is a plist of extra keys, whose names are used as they are."
  (let ((entry (append (list (cons 'pid pid)
                             (cons 'sessionId session-id))
                       (cl-loop for (key value) on fields by #'cddr
                                collect (cons key value)))))
    (with-temp-file (expand-file-name (format "%d.json" pid) directory)
      (insert (ecc--json-write entry)))))

;;;; Reading (FR-DASH-2 b)

(ert-deftest ecc-registry-test-reads-every-file ()
  "Every running session is read, newest first, with what it says."
  (ecc-registry-test--with-fixture
   (let ((sessions (ecc-registry-sessions)))
     (should (= 3 (length sessions)))
     ;; Newest first: the fixture was recorded with these start times.
     (should (equal '("emacs-claude-code-00" "emacs-claude-code-65"
                      "emacs-gravity-a6")
                    (mapcar (lambda (e) (alist-get 'name e)) sessions)))
     (let ((first (car sessions)))
       (should (equal "abe5fa5a-a837-4357-8791-52d1cc1c9909"
                      (alist-get 'sessionId first)))
       (should (equal "busy" (alist-get 'status first)))
       (should (equal "interactive" (alist-get 'kind first)))
       (should (integerp (alist-get 'pid first)))
       ;; The registry says more than `claude agents --json' does.
       (should (alist-get 'messagingSocketPath first))
       (should (alist-get 'version first))))))

(ert-deftest ecc-registry-test-lookup ()
  "A session can be found, and asked about, by its id."
  (ecc-registry-test--with-fixture
   (should (ecc-registry-live-p "abe5fa5a-a837-4357-8791-52d1cc1c9909"))
   (should (equal "emacs-gravity-a6"
                  (alist-get 'name (ecc-registry-session
                                    "3871172f-2450-499e-bea4-ab1656261571"))))
   (should-not (ecc-registry-live-p "no-such-session"))
   (should-not (ecc-registry-session "no-such-session"))))

(ert-deftest ecc-registry-test-filters-by-directory ()
  "The sessions of one project are told apart by their working directory."
  (ecc-registry-test--with-fixture
   (let ((sessions (ecc-registry-in-directory
                    "/Users/jun/Projects/SideProjects/emacs-claude-code")))
     (should (= 2 (length sessions)))
     (should (seq-every-p (lambda (e)
                            (string-suffix-p "emacs-claude-code"
                                             (alist-get 'cwd e)))
                          sessions)))
   (should-not (ecc-registry-in-directory "/nowhere-at-all"))))

(ert-deftest ecc-registry-test-resolves-symlinks ()
  "A working directory is matched with its symbolic links resolved.
The CLI records the resolved path, so /var and /private/var have to
mean the same project."
  (ecc-registry-test--with-temp-registry directory
    (let* ((project (make-temp-file "ecc-registry-project" t))
           (resolved (file-truename project)))
      (unwind-protect
          (let ((ecc-registry-check-process nil))
            (ecc-registry-test--write directory 4242 "s-1" 'cwd resolved)
            (should (= 1 (length (ecc-registry-in-directory project))))
            (should (= 1 (length (ecc-registry-in-directory resolved)))))
        (delete-directory project t)))))

(defun ecc-registry-test--proc-start (pid)
  "Return the start time of PID the way the CLI writes it."
  (format-time-string ecc-registry-proc-start-format
                      (alist-get 'start (process-attributes pid)) t))

(ert-deftest ecc-registry-test-drops-a-dead-process ()
  "A file left behind by a killed session is not believed."
  (ecc-registry-test--with-temp-registry directory
    (ecc-registry-test--write directory (emacs-pid) "alive" 'name "alive"
                              'procStart (ecc-registry-test--proc-start
                                          (emacs-pid)))
    (ecc-registry-test--write directory 999999 "dead" 'name "dead")
    (should (equal '("alive") (mapcar (lambda (e) (alist-get 'name e))
                                      (ecc-registry-sessions))))
    ;; The check can be turned off for a registry that is only read.
    (let ((ecc-registry-check-process nil))
      (should (= 2 (length (ecc-registry-sessions)))))))

(ert-deftest ecc-registry-test-drops-a-reused-process-id ()
  "An id that now belongs to something else is not the old session.
A session killed outright leaves its file behind; the start time the
CLI recorded is what tells the two apart."
  (ecc-registry-test--with-temp-registry directory
    ;; The id is this very Emacs, but the session claims to have started
    ;; at another time, so it is somebody else's process now.
    (ecc-registry-test--write directory (emacs-pid) "stale" 'name "stale"
                              'procStart "Thu Jan  1 00:00:00 1970")
    (should-not (ecc-registry-sessions))
    ;; With the real start time it is believed again.
    (ecc-registry-test--write directory (emacs-pid) "fresh" 'name "fresh"
                              'procStart (ecc-registry-test--proc-start
                                          (emacs-pid)))
    (should (equal '("fresh") (mapcar (lambda (e) (alist-get 'name e))
                                      (ecc-registry-sessions))))
    ;; A file that says nothing about when it started is taken at its word.
    (ecc-registry-test--write directory (emacs-pid) "quiet" 'name "quiet")
    (should (equal '("quiet") (mapcar (lambda (e) (alist-get 'name e))
                                      (ecc-registry-sessions))))))

(ert-deftest ecc-registry-test-drops-a-process-on-its-way-out ()
  "A session killed a moment ago is gone, even before it leaves the table.
`process-attributes' answers for a process that has just been killed,
but with nothing in it, so there is no start time to confirm."
  (ecc-registry-test--with-temp-registry directory
    (ecc-registry-test--write directory (emacs-pid) "dying" 'name "dying"
                              'procStart (ecc-registry-test--proc-start
                                          (emacs-pid)))
    (should (ecc-registry-sessions))
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (_pid) '((comm . "claude")))))
      (should-not (ecc-registry-sessions)))
    ;; A zombie has stopped as well.
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (_pid) '((state . "Z") (start . (0 0))))))
      (should-not (ecc-registry-sessions)))))

(ert-deftest ecc-registry-test-survives-a-bad-file ()
  "A file that does not parse, or has no session id, is skipped."
  (ecc-registry-test--with-temp-registry directory
    (let ((ecc-registry-check-process nil))
      (ecc-registry-test--write directory 1 "s-1" 'name "good")
      (with-temp-file (expand-file-name "2.json" directory) (insert "{not json"))
      ;; A file the CLI is halfway through writing has no session id yet.
      (with-temp-file (expand-file-name "3.json" directory) (insert "{\"pid\": 3}"))
      (should (equal '("good") (mapcar (lambda (e) (alist-get 'name e))
                                       (ecc-registry-sessions)))))))

(ert-deftest ecc-registry-test-missing-directory ()
  "No registry at all is an empty list, not an error."
  (let ((ecc-registry-directory "/nowhere-at-all/sessions/"))
    (should-not (ecc-registry-files))
    (should-not (ecc-registry-sessions))
    (should-not (ecc-registry-watch))))

(ert-deftest ecc-registry-test-describe ()
  "A running session describes itself in one line."
  (ecc-registry-test--with-fixture
   (let ((line (ecc-registry-describe (car (ecc-registry-sessions)))))
     (should (string-search "emacs-claude-code-00" line))
     (should (string-search "busy" line)))))

;;;; Watching (FR-DASH-6)

(ert-deftest ecc-registry-test-watch-announces-a-change ()
  "Starting a watch announces what happens in the registry directory."
  (ecc-registry-test--with-temp-registry directory
    (let* ((changes 0)
           (ecc-registry-changed-hook (list (lambda () (cl-incf changes)))))
      (unwind-protect
          (progn
            (should (ecc-registry-watch))
            ;; Watching twice keeps the one descriptor.
            (should (eq (ecc-registry-watch) ecc-registry--watch))
            ;; The notification itself is what the hook hangs on; the
            ;; file system is not waited for in a batch test.
            (ecc-registry--notify '(nil created "x"))
            (should (= 1 changes)))
        (ecc-registry-unwatch))
      (should-not ecc-registry--watch)
      (ignore directory))))

(provide 'ecc-registry-test)

;;; ecc-registry-test.el ends here
