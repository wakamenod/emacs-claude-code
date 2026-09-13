;;; ecc-window-test.el --- Tests for ecc-window  -*- lexical-binding: t; -*-

;;; Commentary:

;; Where a transcript is shown, hiding and restoring it per project and
;; per tab, the name a session goes by and the rule that picks the
;; session a command talks to.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-window)
(require 'ecc-session)
(require 'ecc-prompt)
(require 'ecc-session)

(defmacro ecc-window-test--with-sessions (first second &rest body)
  "Run BODY with two registered sessions bound to FIRST and SECOND.
They live in different projects; the second is the most recently used."
  (declare (indent 2))
  `(let* ((ecc-test-sent nil)
          (ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-window--last-sub nil)
          (ecc-window--last-source-buffer nil)
          (,first (ecc-model-create-session
                   :name "one" :project-root "/tmp/project-one/"))
          (,second (ecc-model-create-session
                    :name "two" :project-root "/tmp/project-two/")))
     (unwind-protect (progn ,@body)
       (ecc-test-cleanup-session ,first)
       (ecc-test-cleanup-session ,second))))

(defmacro ecc-window-test--with-projects (roots &rest body)
  "Run BODY with each directory in ROOTS answering as a project of its own.
The file system is never asked: `project-current\=' is told that a
directory under one of ROOTS belongs to a transient project rooted
there, which `project.el\=' already knows how to take the root of.  The
caches that would otherwise carry an answer between tests are made
fresh."
  (declare (indent 1))
  `(let ((ecc-window--project-root-cache (make-hash-table :test #'equal))
         (ecc-window--project-source-buffers nil))
     (cl-letf (((symbol-function 'project-current)
                (lambda (&rest _)
                  (let ((directory (expand-file-name default-directory)))
                    (when-let* ((root (seq-find
                                       (lambda (root)
                                         (string-prefix-p root directory))
                                       ,roots)))
                      (cons 'transient root))))))
       ,@body)))

;;;; Projects and names

(ert-deftest ecc-window-test-project-sessions ()
  "A project sees its own sessions only."
  (ecc-window-test--with-sessions one two
    (should (equal (ecc-window-project-sessions "/tmp/project-one/") (list one)))
    (should (equal (ecc-window-project-sessions "/tmp/project-two/") (list two)))
    (should-not (ecc-window-project-sessions "/tmp/elsewhere/"))))

(ert-deftest ecc-window-test-project-key-groups-subdirectories ()
  "A session started in a subdirectory is a session of the whole project.
It used to be a project of its own, because the root was matched as a
string: a session started by mistake one directory down was then
nowhere to be found among its siblings."
  (ecc-window-test--with-projects '("/tmp/project-one/")
    (ecc-window-test--with-sessions one _two
      (let ((deep (ecc-model-create-session
                    :name "deep" :project-root "/tmp/project-one/src/")))
        (unwind-protect
            (progn
              (should (equal (ecc-window-session-project deep)
                             (ecc-window-session-project one)))
              ;; Either directory names the same group, and both
              ;; sessions are in it.
              (dolist (root '("/tmp/project-one/" "/tmp/project-one/src/"))
                (should (equal (sort (mapcar #'ecc-session-name
                                             (ecc-window-project-sessions root))
                                     #'string<)
                               '("deep" "one")))))
          (ecc-test-cleanup-session deep)
          (ecc-model-remove-session deep))))))

(ert-deftest ecc-window-test-session-project-follows-the-cli-cwd ()
  "The project of a session is where the CLI works, not where it started.
A `/cd\=' moves the one and leaves the other."
  (ecc-window-test--with-projects '("/tmp/project-one/" "/tmp/project-two/")
    (ecc-window-test--with-sessions one two
      (should-not (equal (ecc-window-session-project one)
                         (ecc-window-session-project two)))
      (setf (ecc-session-cwd one) "/tmp/project-two/src/")
      (should (equal (ecc-window-session-project one)
                     (ecc-window-session-project two)))
      (should (equal (sort (mapcar #'ecc-session-name
                                   (ecc-window-project-sessions "/tmp/project-two/"))
                           #'string<)
                     '("one" "two"))))))

(ert-deftest ecc-window-test-session-projects-are-distinct ()
  "The projects with a session are listed once each, most recent first."
  (ecc-window-test--with-projects '("/tmp/project-one/" "/tmp/project-two/")
    (ecc-window-test--with-sessions one two
      (let ((third (ecc-model-create-session
                     :name "three" :project-root "/tmp/project-one/lib/")))
        (unwind-protect
            (progn
              ;; Three sessions, two projects, and the one last made
              ;; heads the list.
              (should (equal (ecc-window-session-projects)
                             (list (ecc-window-session-project third)
                                   (ecc-window-session-project two))))
              (ecc-model-touch one)
              (should (equal (car (ecc-window-session-projects))
                             (ecc-window-session-project one))))
          (ecc-test-cleanup-session third)
          (ecc-model-remove-session third))))))

(ert-deftest ecc-window-test-second-session-is-named ()
  "The second session of a project is asked for a name."
  (ecc-window-test--with-sessions _one _two
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "refactor")))
      ;; The first session of a project is named after the directory.
      (should-not (ecc-window-read-session-name "/tmp/project-three/"))
      (should (equal (ecc-window-read-session-name "/tmp/project-one/")
                     "refactor")))
    ;; An empty answer leaves the default name in place.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  ")))
      (should-not (ecc-window-read-session-name "/tmp/project-one/")))))

(ert-deftest ecc-window-test-rename ()
  "Renaming a session renames its buffers with it."
  (ecc-window-test--with-sessions one _two
    (ecc-session-ensure-buffer one)
    (ecc-rename-session one "refactor")
    (should (equal (ecc-session-name one) "refactor"))
    (should (equal (buffer-name (ecc-session-buffer one)) "*ecc: refactor*"))))

;;;; Roles and hiding

(defmacro ecc-window-test--with-frame (roomy &rest body)
  "Run BODY with a frame that has room for a third window when ROOMY.
The frame is not really resized: `set-frame-height' does not reach
`frame-height' in batch, so the threshold is moved instead, which is
the thing being tested anyway.  Any session window BODY opened is taken
down again."
  (declare (indent 1))
  `(let ((ecc-window--last-sub nil)
         (ecc-window-large-frame-min-height
          (if ,roomy 1 (1+ (frame-height)))))
     (unwind-protect (progn ,@body)
       (dolist (window (window-list nil 'no-minibuffer))
         (when (and (window-parameter window 'ecc-window-role)
                    (not (eq window (frame-root-window window))))
           (delete-window window))))))

(ert-deftest ecc-window-test-a-tall-frame-has-three-roles ()
  "A frame with the height to spare gets a third window."
  (let ((ecc-window-large-frame-min-height (frame-height)))
    (should (ecc-window-large-frame-p))
    (should (equal (ecc-window-available-roles) '(main sub-1 sub-2))))
  (let ((ecc-window-large-frame-min-height (1+ (frame-height))))
    (should-not (ecc-window-large-frame-p))
    (should (equal (ecc-window-available-roles) '(main sub-1))))
  ;; The constant is not to be eaten by the roles that are handed out.
  (should (equal ecc-window-roles '(main sub-1 sub-2))))

(ert-deftest ecc-window-test-roles-fill-then-alternate ()
  "Sessions fill the roles in order, then take the subs in turn.
Two sessions are not enough to see this: the fourth is the first one
that has to displace somebody."
  (ecc-window-test--with-sessions one two
    (ecc-window-test--with-frame t
      (let ((three (ecc-model-create-session
                    :name "three" :project-root "/tmp/project-three/"))
            (four (ecc-model-create-session
                   :name "four" :project-root "/tmp/project-four/"))
            (five (ecc-model-create-session
                   :name "five" :project-root "/tmp/project-five/")))
        (unwind-protect
            (progn
              (should (eq (ecc-window-role-for one) 'main))
              (ecc-display-session one)
              (should (eq (ecc-window-role-for two) 'sub-1))
              (ecc-display-session two)
              (should (eq (ecc-window-role-for three) 'sub-2))
              (ecc-display-session three)
              ;; Every role is taken now, so the subs come round in turn
              ;; and `main' is left where it is.
              (should (eq (ecc-window-role-for four) 'sub-1))
              (ecc-display-session four)
              (should (eq (ecc-window--session-role four) 'sub-1))
              (should (eq (ecc-window-role-for five) 'sub-2))
              (ecc-display-session five)
              (should (eq (ecc-window--session-role five) 'sub-2))
              ;; `main' was left alone the whole way through.
              (should (eq (ecc-window--session-role one) 'main))
              ;; A session already on the screen keeps the window it is in.
              (should (eq (ecc-window-role-for one) 'main))
              (should (eq (ecc-window-role-for four) 'sub-1)))
          (dolist (session (list three four five))
            (ecc-test-cleanup-session session)
            (ecc-model-remove-session session)))))))

(ert-deftest ecc-window-test-a-short-frame-keeps-to-two-windows ()
  "Without the height for a third window the subs are all one."
  (ecc-window-test--with-sessions one two
    (ecc-window-test--with-frame nil
      (let ((three (ecc-model-create-session
                    :name "three" :project-root "/tmp/project-three/")))
        (unwind-protect
            (progn
              (ecc-display-session one)
              (ecc-display-session two)
              (should (eq (ecc-window-role-for three) 'sub-1))
              (ecc-display-session three)
              ;; The third session took the window the second was in.
              (should-not (ecc-window-session-visible-p two))
              (should (ecc-window-session-visible-p three)))
          (ecc-test-cleanup-session three)
          (ecc-model-remove-session three))))))

(ert-deftest ecc-window-test-main-is-filled-again-when-it-falls-empty ()
  "A role nobody holds is the first one the next session takes."
  (ecc-window-test--with-sessions one two
    (ecc-window-test--with-frame t
      (ecc-display-session one)
      (should (eq (ecc-window--session-role one) 'main))
      (ecc-window-hide-session one)
      (should (eq (ecc-window-role-for two) 'main)))))

(ert-deftest ecc-window-test-a-side-window-keeps-its-dedication ()
  "Switching what a session window shows leaves it a side window.
`switch-to-buffer' drops the `side' dedication, and an undedicated side
window is the next one `display-buffer' takes over."
  (ecc-window-test--with-sessions one two
    (ecc-window-test--with-frame t
      (ecc-display-session one)
      (let ((window (ecc-window--role-window 'main)))
        (should (eq (window-dedicated-p window) 'side))
        (with-selected-window window
          (switch-to-buffer (ecc-session-ensure-buffer two)))
        (should-not (window-dedicated-p window))
        (ecc-window-repair-side-windows)
        (should (eq (window-dedicated-p window) 'side))))))

(ert-deftest ecc-window-test-hidden-list-is-per-tab ()
  "What was hidden is remembered per tab, not per Emacs."
  (require 'tab-bar)
  (let ((frame-parameter-backup (frame-parameter nil 'ecc-hidden-sessions)))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'ecc-hidden-sessions nil)
          (ecc-window-set-hidden-sessions '("a" "b"))
          (should (equal (ecc-window-hidden-sessions) '("a" "b")))
          (cl-letf (((symbol-function 'tab-bar--current-tab)
                     (lambda (&rest _) '(current-tab (name . "second")))))
            (let ((tab-bar-mode t))
              ;; Another tab starts out with nothing hidden.
              (should-not (ecc-window-hidden-sessions))
              (ecc-window-set-hidden-sessions '("c"))
              (should (equal (ecc-window-hidden-sessions) '("c")))))
          ;; And the first layout is untouched.
          (should (equal (ecc-window-hidden-sessions) '("a" "b"))))
      (set-frame-parameter nil 'ecc-hidden-sessions frame-parameter-backup))))

(ert-deftest ecc-window-test-toggle-hides-then-restores ()
  "Toggle puts back exactly the sessions it took away."
  (ecc-window-test--with-sessions one two
    (let ((hidden nil)
          (shown nil)
          (visible (list one two)))
      (set-frame-parameter nil 'ecc-hidden-sessions nil)
      (cl-letf (((symbol-function 'ecc-window-session-visible-p)
                 (lambda (session &optional _frame) (memq session visible)))
                ((symbol-function 'ecc-window-hide-session)
                 (lambda (session) (push session hidden)
                   (setq visible (delq session visible))))
                ((symbol-function 'ecc-display-session)
                 (lambda (session) (push session shown) (push session visible))))
        ;; Only the sessions of this project are touched without a prefix.
        (let ((default-directory "/tmp/project-one/"))
          (ecc-toggle))
        (should (equal hidden (list one)))
        (should (equal (mapcar #'car (ecc-window-hidden-sessions))
                       (list (ecc-session-id one))))
        (let ((default-directory "/tmp/project-one/"))
          (ecc-toggle))
        (should (equal shown (list one)))
        (should-not (ecc-window-hidden-sessions))
        ;; With a prefix argument every session is hidden.
        (setq hidden nil)
        (ecc-toggle t)
        (should (equal (sort (mapcar #'ecc-session-name hidden) #'string<)
                       '("one" "two")))))))

(ert-deftest ecc-window-test-hide-sessions-keeps-earlier-entries ()
  "Hiding one group after another leaves both of them to come back.
The list used to be replaced rather than added to, so the group hidden
first was forgotten and never came back."
  (ecc-window-test--with-sessions one two
    (set-frame-parameter nil 'ecc-hidden-sessions nil)
    (cl-letf (((symbol-function 'ecc-window-session-visible-p)
               (lambda (&rest _) t))
              ((symbol-function 'ecc-window-hide-session) #'ignore))
      (ecc-window-hide-sessions (list one))
      (ecc-window-hide-sessions (list two))
      (should (equal (sort (mapcar #'car (ecc-window-hidden-sessions)) #'string<)
                     (sort (list (ecc-session-id one) (ecc-session-id two))
                           #'string<)))
      ;; A session hidden twice is remembered once.
      (ecc-window-hide-sessions (list one))
      (should (= 2 (length (ecc-window-hidden-sessions)))))))

(ert-deftest ecc-window-test-toggle-restores-only-its-own-project ()
  "A toggle brings back its own project and leaves the rest hidden.
It used to restore every entry, whichever project had hidden it, so a
toggle after `ecc-focus-project\=' undid the whole of the focus."
  (ecc-window-test--with-sessions one two
    (let ((shown nil)
          (visible (list one two)))
      (set-frame-parameter nil 'ecc-hidden-sessions nil)
      (cl-letf (((symbol-function 'ecc-window-session-visible-p)
                 (lambda (session &optional _frame) (memq session visible)))
                ((symbol-function 'ecc-window-hide-session)
                 (lambda (session) (setq visible (delq session visible))))
                ((symbol-function 'ecc-display-session)
                 (lambda (session) (push session shown) (push session visible))))
        ;; Both projects go into hiding, one after the other.
        (ecc-window-hide-sessions (list one))
        (ecc-window-hide-sessions (list two))
        (should (= 2 (length (ecc-window-hidden-sessions))))
        ;; A toggle in the first project brings back that one alone.
        (let ((default-directory "/tmp/project-one/"))
          (ecc-toggle))
        (should (equal shown (list one)))
        (should (equal (mapcar #'car (ecc-window-hidden-sessions))
                       (list (ecc-session-id two))))
        ;; And the other is still there to come back to.
        (let ((default-directory "/tmp/project-two/"))
          (ecc-toggle))
        (should (equal shown (list two one)))
        (should-not (ecc-window-hidden-sessions))))))

;;;; The source buffer

(ert-deftest ecc-window-test-source-buffer ()
  "The buffers of this package are not what a command quotes from."
  (ecc-window-test--with-sessions one _two
    (let ((source (get-buffer-create "ecc-window-test-source")))
      (unwind-protect
          (progn
            (with-current-buffer source
              (should (eq (ecc-window-last-source-buffer) source)))
            ;; The hooks fire on the selected window, which is what the
            ;; user is looking at.
            (save-window-excursion
              (set-window-buffer (selected-window) source)
              (ecc-window-note-source-buffer))
            ;; A transcript is not a source, so the last ordinary buffer
            ;; is what is left.
            (with-current-buffer (ecc-session-ensure-buffer one)
              (should (ecc-window-own-buffer-p))
              (should (eq (ecc-window-last-source-buffer) source))
              ;; From the prompt region as much as from the transcript.
              (ecc-chat-goto-prompt)
              (should (eq (ecc-window-last-source-buffer) source))))
        (kill-buffer source)))))

;;;; Focusing one project

(defun ecc-window-test--file-buffer (path)
  "Return a fresh buffer pretending to visit PATH, without touching the disk."
  (let ((buffer (generate-new-buffer (file-name-nondirectory path))))
    (with-current-buffer buffer
      (setq buffer-file-name path
            default-directory (file-name-directory path)))
    buffer))

(ert-deftest ecc-window-test-source-buffer-is-remembered-per-project ()
  "The buffer last worked in is remembered for its own project.
A buffer with no file behind it is not: the scratch buffer and a
compilation log are not the source a project should come back to."
  (ecc-window-test--with-projects '("/tmp/project-one/" "/tmp/project-two/")
    (let ((one (ecc-window-test--file-buffer "/tmp/project-one/src/a.el"))
          (two (ecc-window-test--file-buffer "/tmp/project-two/b.el"))
          (scratch (generate-new-buffer "*notes*")))
      (unwind-protect
          (progn
            (dolist (buffer (list one two scratch))
              (with-current-buffer buffer
                (cl-letf (((symbol-function 'selected-window)
                           (lambda (&rest _) nil))
                          ((symbol-function 'window-buffer)
                           (lambda (&rest _) buffer)))
                  (ecc-window-note-source-buffer))))
            ;; Each project remembers its own, and the file in a
            ;; subdirectory counts as the project's.
            (should (eq one (ecc-window-project-source-buffer
                             "/tmp/project-one/" '())))
            (should (eq two (ecc-window-project-source-buffer
                             "/tmp/project-two/" '())))
            ;; The buffer with no file behind it was never recorded.
            (should (= 2 (length ecc-window--project-source-buffers)))
            ;; A buffer that has been killed is dropped rather than
            ;; offered again.
            (kill-buffer one)
            (should-not (ecc-window-project-source-buffer
                         "/tmp/project-one/" '()))
            (should (= 1 (length ecc-window--project-source-buffers))))
        (dolist (buffer (list one two scratch))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest ecc-window-test-source-buffer-prefers-what-is-on-screen ()
  "A buffer of the project already on the screen is left where it is."
  (ecc-window-test--with-projects '("/tmp/project-one/")
    (let ((shown (ecc-window-test--file-buffer "/tmp/project-one/shown.el"))
          (remembered (ecc-window-test--file-buffer "/tmp/project-one/old.el")))
      (unwind-protect
          (progn
            (setf (alist-get (ecc-window-project-key "/tmp/project-one/")
                             ecc-window--project-source-buffers nil nil #'equal)
                  remembered)
            (should (eq shown (ecc-window-project-source-buffer
                               "/tmp/project-one/" (list shown))))
            ;; With nothing of the project on the screen, the one last
            ;; worked in there answers.
            (should (eq remembered (ecc-window-project-source-buffer
                                    "/tmp/project-one/" '()))))
        (dolist (buffer (list shown remembered))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest ecc-window-test-source-window-skips-the-session-windows ()
  "The source belongs in a window that is neither a side window nor ours.
`window-main-window' is no use: with a third session window open the
main area is split and what comes back is the internal window."
  (ecc-window-test--with-sessions one two
    (ecc-window-test--with-frame t
      (ecc-display-session one)
      (ecc-display-session two)
      (let ((window (ecc-window--source-window)))
        (should (window-live-p window))
        (should-not (window-parameter window 'ecc-window-role))
        (should-not (window-parameter window 'window-side))))))

(ert-deftest ecc-window-test-focus-project-moves-rather-than-copies ()
  "A session dealt into another role leaves the window it came from.
The roles are dealt out again from nothing, so a session that already
had a window used to be drawn in both of them and the frame held the
same transcript twice."
  (ecc-window-test--with-projects '("/tmp/project-one/")
    (ecc-window-test--with-sessions one _two
      (let ((deep (ecc-model-create-session
                    :name "deep" :project-root "/tmp/project-one/src/"))
            (taken nil)
            (placed nil))
        (unwind-protect
            (cl-letf (((symbol-function 'ecc-window-session-visible-p)
                       (lambda (&rest _) t))
                      ((symbol-function 'ecc-window-hide-session)
                       (lambda (session) (push session taken)))
                      ((symbol-function 'ecc-window-available-roles)
                       (lambda (&optional _frame) ecc-window-roles))
                      ((symbol-function 'ecc-display-session-in-role)
                       (lambda (session role) (push (cons session role) placed)))
                      ((symbol-function 'ecc-window-focus-source)
                       (lambda (&rest _) nil)))
              (set-frame-parameter nil 'ecc-hidden-sessions nil)
              (ecc-focus-project "/tmp/project-one/")
              ;; Both sessions of the project are taken down before
              ;; either is put back, so neither is left behind in the
              ;; role it used to have.  The third is the other project,
              ;; which is taken down because it is being hidden.
              (should (equal (sort (mapcar #'ecc-session-name taken) #'string<)
                             '("deep" "one" "two")))
              (should (equal (mapcar #'cdr (reverse placed)) '(main sub-1)))
              ;; Only the other project is remembered as hidden: these
              ;; two are back on the screen.
              (should (equal (mapcar #'car (ecc-window-hidden-sessions))
                             (list (ecc-session-id _two)))))
          (ecc-test-cleanup-session deep)
          (ecc-model-remove-session deep))))))

(ert-deftest ecc-window-test-focus-project-hides-the-others ()
  "Focusing a project takes the other projects off the screen, and no more.
Nothing is killed: the hidden list names them, so a toggle brings them
back."
  (ecc-window-test--with-projects '("/tmp/project-one/" "/tmp/project-two/")
    (ecc-window-test--with-sessions one two
      (let ((placed nil)
            (hidden nil)
            (visible (list one two)))
        (set-frame-parameter nil 'ecc-hidden-sessions nil)
        (cl-letf (((symbol-function 'ecc-window-session-visible-p)
                   (lambda (session &optional _frame) (memq session visible)))
                  ((symbol-function 'ecc-window-hide-session)
                   (lambda (session) (push session hidden)
                     (setq visible (delq session visible))))
                  ((symbol-function 'ecc-window-available-roles)
                   (lambda (&optional _frame) ecc-window-roles))
                  ((symbol-function 'ecc-display-session-in-role)
                   (lambda (session role) (push (cons session role) placed)))
                  ((symbol-function 'ecc-window-focus-source)
                   (lambda (&rest _) nil)))
          (ecc-focus-project "/tmp/project-one/")
          ;; The other project is off the screen and remembered; this
          ;; one comes down too, but only to be dealt out again.
          (should (memq two hidden))
          (should (equal (mapcar #'car (ecc-window-hidden-sessions))
                         (list (ecc-session-id two))))
          ;; This one is in the main window, and is not in the hidden
          ;; list even though it was on the screen already.
          (should (equal placed (list (cons one 'main))))
          ;; A project with no session is refused rather than emptying
          ;; the frame.
          (should-error (ecc-focus-project "/tmp/elsewhere/")
                        :type 'user-error))))))

;;;; Which session a command talks to

(ert-deftest ecc-window-test-resolve-in-a-session-buffer ()
  "A command in a session buffer talks to that session."
  (ecc-window-test--with-sessions one two
    (with-current-buffer (ecc-session-ensure-buffer two)
      (should (eq (ecc-window-resolve-session) two)))
    (with-current-buffer (ecc-session-ensure-buffer one)
      (ecc-chat-goto-prompt)
      (should (eq (ecc-window-resolve-session) one)))))

(ert-deftest ecc-window-test-resolve-by-project-then-recency ()
  "The project decides, and failing that the session last used."
  (ecc-window-test--with-sessions one two
    (with-temp-buffer
      (let ((default-directory "/tmp/project-one/"))
        (should (eq (ecc-window-resolve-session) one)))
      ;; No session of this project: the most recently used one wins.
      (let ((default-directory "/tmp/elsewhere/"))
        (should (eq (ecc-window-resolve-session) two))
        (ecc-model-touch one)
        (should (eq (ecc-window-resolve-session) one))))))

(ert-deftest ecc-window-test-resolve-by-the-only-window ()
  "The one session on screen wins over the one used last."
  (ecc-window-test--with-sessions one two
    (with-temp-buffer
      (cl-letf (((symbol-function 'ecc-window-session-visible-p)
                 (lambda (session &optional _frame) (eq session two))))
        (let ((default-directory "/tmp/elsewhere/"))
          (ecc-model-touch one)
          (should (eq (ecc-window-resolve-session) two)))))))

(ert-deftest ecc-window-test-resolve-asks-and-remembers ()
  "A prefix argument asks, and the answer sticks to the buffer."
  (ecc-window-test--with-sessions one two
    (with-temp-buffer
      (let ((asked 0))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (setq asked (1+ asked))
                     (ecc-window-session-label two))))
          (let ((default-directory "/tmp/project-one/"))
            (should (eq (ecc-window-resolve-session t) two))
            (should (= asked 1))
            ;; Asked once: from now on this buffer talks to that session.
            (should (eq (ecc-window-resolve-session) two))
            (should (= asked 1))
            ;; Unless the user asks again.
            (should (eq (ecc-window-resolve-session t) two))
            (should (= asked 2))))))))


;;;; Opening a review

(ert-deftest ecc-window-test-review-leaves-the-windows-alone-by-default ()
  "With the defaults a review just opens; nothing is hidden."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let ((review (generate-new-buffer "*ecc-review-test*"))
          (ecc-window-hide-on-review nil)
          (ecc-window-review-focus nil))
      (unwind-protect
          (progn
            (ecc-display-session session)
            (should (ecc-window-display-review review session))
            (should (ecc-window-session-visible-p session))
            (should-not (ecc-window-hidden-sessions)))
        (kill-buffer review)
        (ecc-window-hide-session session)))))

(ert-deftest ecc-window-test-review-can-hide-the-session ()
  "`ecc-window-hide-on-review' takes the session windows away."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let ((review (generate-new-buffer "*ecc-review-test*"))
          (ecc-window-hide-on-review 'all)
          (ecc-window-review-focus 'review))
      (unwind-protect
          (progn
            (ecc-display-session session)
            (should (ecc-window-session-visible-p session))
            (ecc-window-display-review review session)
            (should-not (ecc-window-session-visible-p session))
            ;; What was hidden is remembered, so `ecc-toggle' brings it back.
            (should (assoc (ecc-session-id session)
                           (ecc-window-hidden-sessions)))
            (should (eq (window-buffer (selected-window)) review)))
        (kill-buffer review)
        (ecc-window-set-hidden-sessions nil)))))

(ert-deftest ecc-window-test-review-focus-can-stay-in-the-transcript ()
  "`ecc-window-review-focus' session leaves point in the transcript."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let ((review (generate-new-buffer "*ecc-review-test*"))
          (ecc-window-hide-on-review nil)
          (ecc-window-review-focus 'session))
      (unwind-protect
          (progn
            (ecc-display-session session)
            (ecc-window-display-review review session)
            (should (eq (window-buffer (selected-window))
                        (ecc-session-buffer session))))
        (kill-buffer review)
        (ecc-window-hide-session session)))))

(ert-deftest ecc-window-test-killing-the-transcript-forgets-the-session ()
  "Killing a session buffer kills the session: nothing lingers in the list.
An agent transcript of the same session does not count."
  (ecc-test-with-fake-session session
    (let ((buffer (ecc-session-ensure-buffer session))
          (id (ecc-session-id session)))
      (should (ecc-model-session id))
      (kill-buffer buffer)
      (should-not (ecc-model-session id))
      (should-not (assoc id (ecc-window-hidden-sessions))))))

(provide 'ecc-window-test)

;;; ecc-window-test.el ends here
