;;; ecc-restore-test.el --- Tests for ecc-restore  -*- lexical-binding: t; -*-

;;; Commentary:

;; Saving which sessions and Spaces are open, and bringing them back as
;; stopped sessions.  No CLI is started anywhere in this file: every
;; case stands in `ecc-proc-start' with a failure.  The recordings are
;; the two history fixtures, laid out the way the CLI lays them out.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc)
(require 'ecc-restore)
(require 'ecc-space)
(require 'ecc-sidebar)

(defconst ecc-restore-test--a "24a1aa86-d53f-4457-b09e-4f4caf450f03"
  "Session id of the `session' history fixture.")

(defconst ecc-restore-test--b "4cc012b5-389b-420b-8569-306cbc5b6abf"
  "Session id of the `local-commands' history fixture.")

(defvar ecc-restore-test--one nil "A project directory of the case running.")
(defvar ecc-restore-test--two nil "Another project directory of the case running.")

(defmacro ecc-restore-test--with-world (&rest body)
  "Run BODY with two projects, two recordings and nothing open.
`ecc-restore-file' is a file of its own, saving is on as in an
interactive Emacs, and starting a CLI fails the test."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ecc-restore" t)))
          (history (expand-file-name "projects/" dir))
          (ecc-restore-test--one (file-name-as-directory
                                  (expand-file-name "one" dir)))
          (ecc-restore-test--two (file-name-as-directory
                                  (expand-file-name "two" dir)))
          (ecc-restore-file (expand-file-name "ecc-state.eld" dir))
          (ecc-restore-enabled t)
          (ecc-restore--written nil)
          (ecc-restore--owned nil)
          (ecc-restore--frozen nil)
          (ecc-restore--previous 'unread)
          (ecc-restore--timer nil)
          (ecc-history-directory history)
          (ecc-history--files (make-hash-table :test #'equal))
          (ecc-history--abandoned (make-hash-table :test #'equal))
          (ecc-registry-directory (expand-file-name "sessions/" dir))
          (ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-render-debounce 0)
          (ecc-use-spaces nil)
          (ecc-visual-enable-icons nil)
          (ecc-visual-enable-spinner nil)
          (ecc-window--project-root-cache (make-hash-table :test #'equal))
          (ecc-window--project-source-buffers nil)
          (ecc-window--last-source-buffer nil)
          (ecc-worktree--cache (make-hash-table :test #'equal))
          (started nil))
     (make-directory ecc-restore-test--one t)
     (make-directory ecc-restore-test--two t)
     (make-directory (expand-file-name "-tmp-project/" history) t)
     (copy-file (ecc-test-history-fixture "session")
                (expand-file-name (concat "-tmp-project/" ecc-restore-test--a ".jsonl")
                                  history))
     (copy-file (ecc-test-history-fixture "local-commands")
                (expand-file-name (concat "-tmp-project/" ecc-restore-test--b ".jsonl")
                                  history))
     (unwind-protect
         (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                   ((symbol-function 'ecc-worktree-main) (lambda (_) nil))
                   ((symbol-function 'ecc-worktree-branch) (lambda (_) nil))
                   ((symbol-function 'ecc-proc-start)
                    (lambda (&rest _) (ert-fail "a CLI was started")))
                   ;; Recorded rather than failed: a Space starting its
                   ;; session catches the error and says it instead.
                   ((symbol-function 'ecc-start)
                    (lambda (&rest args) (push args started))))
           ,@body
           (should-not started))
       (when ecc-restore--timer
         (cancel-timer ecc-restore--timer))
       (mapc #'ecc-test-cleanup-session (ecc-model-sessions))
       (delete-directory dir t))))

(defun ecc-restore-test--open (id name root)
  "Make a session of ID called NAME in ROOT, as if its CLI had just started."
  (let ((session (ecc-model-create-session :id id :name name :project-root root)))
    (ecc-model-set-state session 'idle)
    session))

(defun ecc-restore-test--flush ()
  "Make the save that is waiting, failing when none is."
  (should ecc-restore--timer)
  (ecc-restore-save))

(defun ecc-restore-test--saved-ids (&optional file)
  "Return the session ids saved in FILE, in the order saved."
  (mapcar (lambda (entry) (plist-get entry :id))
          (plist-get (ecc-restore--read file) :sessions)))

;;;; Saving

(ert-deftest ecc-restore-test-saves-when-a-session-starts-and-goes ()
  "A session starting and a session killed are both written down."
  (ecc-restore-test--with-world
    (let ((a (ecc-restore-test--open "id-a" "a" ecc-restore-test--one)))
      (ecc-restore-test--flush)
      (should (equal (ecc-restore-test--saved-ids) '("id-a")))
      (ecc-restore-test--open "id-b" "b" ecc-restore-test--two)
      (ecc-restore-test--flush)
      ;; Most recently used first, with what is needed to find it again.
      (should (equal (ecc-restore-test--saved-ids) '("id-b" "id-a")))
      (let ((entry (car (plist-get (ecc-restore--read) :sessions))))
        (should (equal (plist-get entry :name) "b"))
        (should (equal (plist-get entry :root) ecc-restore-test--two)))
      ;; A session killed on purpose leaves the file.
      (ecc-kill a)
      (ecc-restore-test--flush)
      (should (equal (ecc-restore-test--saved-ids) '("id-b"))))))

(ert-deftest ecc-restore-test-no-write-when-nothing-changed ()
  "A save that would write the same thing again writes nothing."
  (ecc-restore-test--with-world
    (ecc-restore-test--open "id-a" "a" ecc-restore-test--one)
    (ecc-restore-test--open "id-b" "b" ecc-restore-test--two)
    (should (ecc-restore-save))
    (let ((writes 0))
      (cl-letf* ((write (symbol-function 'write-region))
                 ((symbol-function 'write-region)
                  (lambda (&rest args)
                    (cl-incf writes)
                    (apply write args))))
        ;; A turn going round changes the state of a session and nothing
        ;; that is saved.
        (ecc-model-set-state (car (ecc-model-sessions)) 'running)
        (should-not (ecc-restore-save))
        (should (= writes 0))))))

(ert-deftest ecc-restore-test-a-recording-being-read-is-not-saved ()
  "Only the user's own sessions are saved: a recording opened to read is not."
  (ecc-restore-test--with-world
    (ecc-restore-test--open "id-a" "a" ecc-restore-test--one)
    (ecc-history-session ecc-restore-test--b)
    (ecc-restore-save)
    (should (equal (ecc-restore-test--saved-ids) '("id-a")))))

(ert-deftest ecc-restore-test-exit-is-not-overwritten-by-the-teardown ()
  "What is open at exit is what is saved, whatever goes down after it."
  (ecc-restore-test--with-world
    (let ((a (ecc-restore-test--open "id-a" "a" ecc-restore-test--one))
          (b (ecc-restore-test--open "id-b" "b" ecc-restore-test--two)))
      (ecc-restore-test--flush)
      (ecc-restore--save-at-exit)
      ;; Emacs going down takes the sessions with it.
      (ecc-kill a)
      (ecc-kill b)
      (should-not ecc-restore--timer)
      (should-not (ecc-restore-save))
      (should (equal (ecc-restore-test--saved-ids) '("id-b" "id-a"))))))

(ert-deftest ecc-restore-test-an-idle-emacs-leaves-the-file-alone-at-exit ()
  "An Emacs that never had a session open does not save one at exit.
The file is still what the last Emacs left, waiting to be restored."
  (ecc-restore-test--with-world
    (ecc-restore--write (list :version ecc-restore--version :spaces nil
                              :sessions (list (list :id "id-old" :name "old"
                                                    :root ecc-restore-test--one))))
    (setq ecc-restore--written nil)
    (ecc-restore--save-at-exit)
    (should (equal (ecc-restore-test--saved-ids) '("id-old")))))

(ert-deftest ecc-restore-test-a-new-session-keeps-what-is-to-be-restored ()
  "Starting a session before restoring does not lose the last Emacs's state.
Until `ecc-restore' has run, the sessions left last time are carried
along in every write, the one at exit as well."
  (ecc-restore-test--with-world
    (ecc-restore--write (list :version ecc-restore--version :spaces nil
                              :sessions (list (list :id "id-old" :name "old"
                                                    :root ecc-restore-test--one))))
    (setq ecc-restore--written nil)
    (ecc-restore-test--open "id-new" "new" ecc-restore-test--two)
    (ecc-restore-test--flush)
    (should (equal (ecc-restore-test--saved-ids) '("id-new" "id-old")))
    (ecc-restore--save-at-exit)
    (should (equal (ecc-restore-test--saved-ids) '("id-new" "id-old")))))

(ert-deftest ecc-restore-test-quitting-before-restoring-keeps-the-last-sessions ()
  "Five sessions saved, one new session, quit without restoring: six remain.
The exit write stored only what was open, and the five were gone
\(second review of PR #94)."
  (ecc-restore-test--with-world
    (let ((old (mapcar (lambda (n)
                         (list :id (format "id-old-%d" n) :name (format "old-%d" n)
                               :root ecc-restore-test--one))
                       '(1 2 3 4 5))))
      (ecc-restore-test--write-state nil old)
      (ecc-restore-test--open "id-new" "new" ecc-restore-test--two)
      ;; Straight to the exit, with no save in between.
      (ecc-restore--save-at-exit)
      (should (equal (ecc-restore-test--saved-ids)
                     (cons "id-new" (mapcar (lambda (entry) (plist-get entry :id))
                                            old)))))))

(ert-deftest ecc-restore-test-after-a-restore-a-killed-session-leaves-at-exit ()
  "Once restored, a session killed on purpose is not written back at exit."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (ecc-restore)
    (ecc-kill (ecc-model-session ecc-restore-test--b))
    (ecc-restore--save-at-exit)
    (should (equal (ecc-restore-test--saved-ids) (list ecc-restore-test--a)))))

;;;; Restoring

(defun ecc-restore-test--write-state (spaces sessions)
  "Save a state of the Space roots SPACES and the session plists SESSIONS."
  (ecc-restore--write (list :version ecc-restore--version
                            :spaces spaces :sessions sessions))
  (setq ecc-restore--written nil
        ecc-restore--previous 'unread))

(defun ecc-restore-test--two-sessions ()
  "Save the two recordings as open, one in each project, B used last."
  (ecc-restore-test--write-state
   (list ecc-restore-test--two ecc-restore-test--one)
   (list (list :id ecc-restore-test--b :name "bee" :root ecc-restore-test--two
               :cwd ecc-restore-test--two)
         (list :id ecc-restore-test--a :name "ay" :root ecc-restore-test--one
               :cwd ecc-restore-test--one))))

(ert-deftest ecc-restore-test-sessions-come-back-stopped ()
  "Every saved session comes back read from its recording, with no process."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (let ((restored (ecc-restore)))
      (should (= 2 (length restored)))
      ;; The order of use is the saved one.
      (should (equal (mapcar #'ecc-session-name (ecc-model-sessions))
                     '("bee" "ay")))
      (dolist (session (ecc-model-sessions))
        (should-not (ecc-session-process session))
        (should (eq (ecc-session-state session) 'exited))
        (should (eq (ecc-session-kind session) 'own))
        (should (ecc-model-option session :restored nil))
        (should (buffer-live-p (ecc-session-buffer session)))
        ;; Read from the recording: the conversation is there.
        (should (ecc-session-turns session)))
      (let ((a (ecc-model-session ecc-restore-test--a)))
        (should (equal (ecc-session-project-root a) ecc-restore-test--one))
        (should (string-search "hello"
                               (with-current-buffer (ecc-session-buffer a)
                                 (buffer-string))))))))

(ert-deftest ecc-restore-test-running-it-twice-brings-nothing-back-twice ()
  "A session that is open already is left alone."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (ecc-restore)
    (let ((before (ecc-model-sessions)))
      (should-not (ecc-restore))
      (should (equal (ecc-model-sessions) before)))
    ;; A session opened by hand before restoring is not doubled either.
    (mapc #'ecc-kill (ecc-model-sessions))
    (ecc-restore-test--two-sessions)
    (ecc-restore-test--open ecc-restore-test--a "mine" ecc-restore-test--one)
    (should (= 1 (length (ecc-restore))))
    (should (= 2 (length (ecc-model-sessions))))
    (should (equal (ecc-session-name (ecc-model-session ecc-restore-test--a))
                   "mine"))))

(ert-deftest ecc-restore-test-a-directory-that-is-gone-is-skipped ()
  "A session whose directory is gone is skipped and named in the message."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (delete-directory ecc-restore-test--two t)
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq said (apply #'format-message format args)))))
        (should (equal (mapcar #'ecc-session-id (ecc-restore))
                       (list ecc-restore-test--a))))
      (should (string-search "bee" said))
      (should (string-search "gone" said)))
    (should-not (ecc-model-session ecc-restore-test--b))))

(ert-deftest ecc-restore-test-a-prompt-starts-a-restored-session ()
  "Sending a prompt to a restored session resumes it first, and only once."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (ecc-restore)
    (let ((session (ecc-model-session ecc-restore-test--a))
          (resumed nil)
          (process nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ecc-resume)
                     (lambda (session &rest _)
                       (push session resumed)
                       ;; What starting the CLI does: a process, and
                       ;; the state it puts the session in.
                       (setq process (make-pipe-process :name "ecc-restore-test"
                                                        :noquery t))
                       (setf (ecc-session-process session) process)
                       (ecc-model-set-state session 'idle))))
            (ecc-prompt--start-restored session)
            (should (equal resumed (list session)))
            ;; Started once, it is a session like any other.
            (should-not (ecc-model-option session :restored nil))
            (delete-process process)
            (ecc-model-set-state session 'exited)
            (ecc-prompt--start-restored session)
            (should (= 1 (length resumed))))
        (when (process-live-p process)
          (delete-process process))
        (setf (ecc-session-process session) nil)))))

(ert-deftest ecc-restore-test-classic-restores-sessions-and-no-space ()
  "Under `ecc-use-spaces' nil the sessions come back and no Space is opened."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (let ((tabs (length (funcall tab-bar-tabs-function))))
      (cl-letf (((symbol-function 'ecc-space-select)
                 (lambda (&rest _) (ert-fail "a Space was opened")))
                ((symbol-function 'ecc-space-tab-roots)
                 (lambda (&rest _) (ert-fail "the Spaces were asked"))))
        (should (= 2 (length (ecc-restore))))
        (should (= tabs (length (funcall tab-bar-tabs-function))))
        ;; Saving under `classic' does not ask the Spaces either.
        (should-not (plist-get (ecc-restore-state) :spaces))))))

;;;; What only looks like a session

(ert-deftest ecc-restore-test-a-tab-or-a-reader-does-not-empty-the-file-at-exit ()
  "An Emacs with no session of its own leaves the last one's state at exit.
Opening a tab saves, and so does reading a recording; neither is a
session that belongs in the file, and the exit write stored an empty
state over the two sessions still to be restored (review of PR #94)."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    ;; What a tab opening and closing does: a save, which now writes
    ;; nothing, there being nothing of this Emacs's own to write.
    (ecc-restore-save)
    (should-not ecc-restore--written)
    ;; A recording opened to be read changes state, which saves too.
    (ecc-history-session "id-read" (ecc-history-file ecc-restore-test--b))
    (ecc-restore-save)
    (ecc-restore--save-at-exit)
    (should (equal (ecc-restore-test--saved-ids)
                   (list ecc-restore-test--b ecc-restore-test--a)))))

(defun ecc-restore-test--open-and-close-a-tab ()
  "Open a tab and close it again, making the saves that schedules."
  (let ((was tab-bar-mode))
    (unwind-protect
        (progn
          (tab-bar-mode 1)
          (tab-bar-new-tab)
          (should ecc-restore--timer)
          (ecc-restore-save)
          (tab-bar-close-tab)
          (ecc-restore-save))
      (tab-bar-mode (if was 1 -1)))))

(ert-deftest ecc-restore-test-a-tab-does-not-write-over-an-unreadable-file ()
  "A state file this version cannot read survives a tab opening and closing.
There is nothing to carry along from it, so a save wrote an empty state
over it before `ecc-restore' could be run (third review of PR #94)."
  (ecc-restore-test--with-world
    (let ((text "(:version 99 :sessions ((:id \"from-the-future\")))\n"))
      (with-temp-file ecc-restore-file (insert text))
      (ecc-restore-test--open-and-close-a-tab)
      (ecc-restore--save-at-exit)
      (should (equal (with-temp-buffer
                       (insert-file-contents ecc-restore-file)
                       (buffer-string))
                     text)))))

(ert-deftest ecc-restore-test-a-tab-writes-nothing-in-an-emacs-without-sessions ()
  "An Emacs with no session of its own does not write the file at all.
Not even the same state again: the file is left as the last Emacs
wrote it."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (let ((writes 0))
      (cl-letf* ((write (symbol-function 'write-region))
                 ((symbol-function 'write-region)
                  (lambda (&rest args)
                    (cl-incf writes)
                    (apply write args))))
        (ecc-restore-test--open-and-close-a-tab)
        (ecc-restore--save-at-exit))
      (should (= writes 0))
      (should (equal (ecc-restore-test--saved-ids)
                     (list ecc-restore-test--b ecc-restore-test--a))))))

(ert-deftest ecc-restore-test-a-recording-being-read-becomes-the-restored-session ()
  "A saved session open to be read is taken over by the restore, not skipped.
Skipped, it was dropped for good: a recording being read is never
saved, and the restore let go of the last Emacs's state (review of
PR #94).  A session that is really open is skipped and counted."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (let ((read (ecc-history-open ecc-restore-test--a))
          (said nil))
      (should (eq (ecc-session-kind read) 'archived))
      (ecc-restore-test--open ecc-restore-test--b "mine" ecc-restore-test--two)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq said (apply #'format-message format args)))))
        (should (equal (ecc-restore) (list read))))
      (should (string-search "1 open already" said))
      ;; The same session, in the buffer it had, now the restored one.
      (should (eq (ecc-model-session ecc-restore-test--a) read))
      (should (eq (ecc-session-kind read) 'own))
      (should (ecc-model-option read :restored nil))
      (should (equal (ecc-session-name read) "ay"))
      (should (equal (ecc-session-project-root read) ecc-restore-test--one))
      (should (eq (ecc-tab-state read) 'restored))
      ;; And it is saved again, so the next Emacs has it too.
      (ecc-restore-save)
      (should (member ecc-restore-test--a (ecc-restore-test--saved-ids))))))

;;;; What a stopped session says

(ert-deftest ecc-restore-test-a-restored-session-names-no-exit-code ()
  "A session that never ran here says so, rather than `exited (code ?)'.
A real exit still names its code; there was a process to have one."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (ecc-restore)
    (let ((restored (ecc-model-session ecc-restore-test--a))
          (read (ecc-history-session "id-read" (ecc-history-file
                                                ecc-restore-test--b))))
      (dolist (session (list restored read))
        (should-not (string-search "?" (ecc-render-status-line session)))
        (should-not (string-search "?" (ecc-render--tail-string session))))
      (should (equal (substring-no-properties (ecc-render-status-line restored))
                     "○ restored"))
      (should (string-search "a prompt or R starts it"
                             (ecc-render--tail-string restored)))
      (should (string-search "R resumes it" (ecc-render--tail-string read)))
      ;; The mode line says the same, not the red `✗ exited'.
      (let ((line (ecc-render-mode-line-state restored)))
        (should (equal (substring-no-properties line) "○ restored"))
        (should (eq (get-text-property 0 'face line) 'ecc-dim-face)))
      (should (equal (substring-no-properties (ecc-render-mode-line-state read))
                     "○ not running"))
      ;; An exit with a status is the error it always was.
      (setf (alist-get 'exit-status (ecc-session-progress restored)) 1)
      (should (equal (substring-no-properties (ecc-render-status-line restored))
                     "✗ exited (code 1)"))
      (should (equal (substring-no-properties (ecc-render-mode-line-state restored))
                     "✗ exited"))
      (should (string-search "Exited with code 1"
                             (ecc-render--tail-string restored))))))

(ert-deftest ecc-restore-test-the-tabs-and-the-sidebar-say-restored ()
  "The tab line and the sidebar draw a restored session quietly, not as ✗.
A Space folds it under the louder states: an exit still wins, and a
restored session wins over an idle one."
  (ecc-restore-test--with-world
    (ecc-restore-test--two-sessions)
    (ecc-restore)
    (let ((restored (ecc-model-session ecc-restore-test--a))
          (other (ecc-model-session ecc-restore-test--b)))
      (should (eq (ecc-tab-state restored) 'restored))
      (should (equal (ecc-tab-mark restored) "○"))
      (should (equal (ecc-tab-faces restored nil) '(ecc-tab-idle-face)))
      (should (equal (ecc-sidebar--state-word restored) "restored"))
      (should (eq (ecc-tab-state-roll-up (list restored other)) 'restored))
      ;; Beside an idle session it is still what the group says.
      (ecc-model-set-state other 'idle)
      (should (eq (ecc-tab-state-roll-up (list other restored)) 'restored))
      ;; A real exit is louder, and is still the error it was.
      (setf (ecc-session-options other) nil)
      (ecc-model-set-state other 'exited)
      (should (eq (ecc-tab-state other) 'exited))
      (should (equal (ecc-tab-mark other) "✗"))
      (should (eq (ecc-tab-state-roll-up (list restored other)) 'exited)))))

;;;; Spaces

(defmacro ecc-restore-test--with-spaces (&rest body)
  "Run BODY with Spaces on and a fresh tab bar, closing its tabs afterwards."
  (declare (indent 0))
  `(let ((was tab-bar-mode)
         (tabs-was (frame-parameter nil 'ecc-space-tabs))
         (ecc-use-spaces t)
         (ecc-space--used nil)
         (ecc-space--implicit nil)
         (ecc-space--ensuring-parent nil)
         (ecc-space--closing nil))
     (set-frame-parameter nil 'ecc-space-tabs nil)
     (unwind-protect
         (progn (tab-bar-mode 1) ,@body)
       (dolist (tab (funcall tab-bar-tabs-function))
         (unless (eq (car tab) 'current-tab)
           (tab-bar-close-tab-by-name (alist-get 'name tab))))
       (tab-bar-rename-tab "")
       (set-frame-parameter nil 'ecc-space-tabs tabs-was)
       (tab-bar-mode (if was 1 -1)))))

(ert-deftest ecc-restore-test-saves-the-spaces-in-the-order-of-their-tabs ()
  "The Spaces are saved in the order their tabs stand in."
  (ecc-restore-test--with-world
    (ecc-restore-test--with-spaces
      (ecc-restore-test--open "id-a" "a" ecc-restore-test--one)
      (ecc-restore-test--open "id-b" "b" ecc-restore-test--two)
      (ecc-space-select (ecc-space-of-root ecc-restore-test--one))
      (ecc-space-select (ecc-space-of-root ecc-restore-test--two))
      (ecc-restore-test--flush)
      (should (equal (plist-get (ecc-restore--read) :spaces)
                     (list ecc-restore-test--one ecc-restore-test--two)))
      ;; Closing a tab is saved as well.
      (tab-bar-close-tab-by-name (ecc-space-tab (ecc-space-of-root
                                                 ecc-restore-test--one)))
      (ecc-restore-test--flush)
      (should (equal (plist-get (ecc-restore--read) :spaces)
                     (list ecc-restore-test--two))))))

(ert-deftest ecc-restore-test-spaces-come-back-in-order-with-their-sessions ()
  "Each Space gets its tab back, in order, with its session laid out in it."
  (ecc-restore-test--with-world
    (ecc-restore-test--with-spaces
      (ecc-restore-test--two-sessions)
      (should (= 2 (length (ecc-restore))))
      (should (equal (ecc-space-tab-roots)
                     (list ecc-restore-test--two ecc-restore-test--one)))
      ;; The first Space is the one left showing, its session beside the
      ;; source.
      (should (equal (ecc-space-current-key) ecc-restore-test--two))
      (should (get-buffer-window
               (ecc-session-buffer (ecc-model-session ecc-restore-test--b))))
      (ecc-space-select (ecc-space-of-root ecc-restore-test--one))
      (should (get-buffer-window
               (ecc-session-buffer (ecc-model-session ecc-restore-test--a))))
      ;; Twice is once.
      (ecc-restore)
      (should (equal (ecc-space-tab-roots)
                     (list ecc-restore-test--two ecc-restore-test--one))))))

(ert-deftest ecc-restore-test-a-space-with-nothing-in-it-starts-nothing ()
  "A Space saved with no session comes back as a tab and starts no session."
  (ecc-restore-test--with-world
    (ecc-restore-test--with-spaces
      (let ((ecc-space-always-session t))
        (ecc-restore-test--write-state
         (list ecc-restore-test--one ecc-restore-test--two
               (expand-file-name "gone/" ecc-restore-test--one))
         (list (list :id ecc-restore-test--b :name "bee"
                     :root ecc-restore-test--two)))
        (ecc-restore)
        ;; The one that is gone is skipped; the empty one is a tab.
        (should (equal (ecc-space-tab-roots)
                       (list ecc-restore-test--one ecc-restore-test--two)))
        (should (= 1 (length (ecc-model-sessions))))))))

(provide 'ecc-restore-test)

;;; ecc-restore-test.el ends here
