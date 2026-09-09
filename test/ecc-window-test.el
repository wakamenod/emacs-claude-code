;;; ecc-window-test.el --- Tests for ecc-window  -*- lexical-binding: t; -*-

;;; Commentary:

;; Where a transcript is shown (FR-WIN-1), hiding and restoring it per
;; project and per tab (FR-WIN-2, FR-WIN-5), the name a session goes by
;; (FR-WIN-3) and the rule that picks the session a command talks to
;; (FR-WIN-4).

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

;;;; Projects and names (FR-WIN-3)

(ert-deftest ecc-window-test-project-sessions ()
  "A project sees its own sessions only (FR-WIN-3)."
  (ecc-window-test--with-sessions one two
    (should (equal (ecc-window-project-sessions "/tmp/project-one/") (list one)))
    (should (equal (ecc-window-project-sessions "/tmp/project-two/") (list two)))
    (should-not (ecc-window-project-sessions "/tmp/elsewhere/"))))

(ert-deftest ecc-window-test-second-session-is-named ()
  "The second session of a project is asked for a name (FR-WIN-3)."
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
  "Renaming a session renames its buffers with it (FR-WIN-3)."
  (ecc-window-test--with-sessions one _two
    (ecc-session-ensure-buffer one)
    (ecc-rename-session one "refactor")
    (should (equal (ecc-session-name one) "refactor"))
    (should (equal (buffer-name (ecc-session-buffer one)) "*ecc: refactor*"))))

;;;; Roles and hiding (FR-WIN-1, FR-WIN-2, FR-WIN-5)

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
  "A frame with the height to spare gets a third window (FR-WIN-1)."
  (let ((ecc-window-large-frame-min-height (frame-height)))
    (should (ecc-window-large-frame-p))
    (should (equal (ecc-window-available-roles) '(main sub-1 sub-2))))
  (let ((ecc-window-large-frame-min-height (1+ (frame-height))))
    (should-not (ecc-window-large-frame-p))
    (should (equal (ecc-window-available-roles) '(main sub-1))))
  ;; The constant is not to be eaten by the roles that are handed out.
  (should (equal ecc-window-roles '(main sub-1 sub-2))))

(ert-deftest ecc-window-test-roles-fill-then-alternate ()
  "Sessions fill the roles in order, then take the subs in turn (FR-WIN-1).
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
  "Without the height for a third window the subs are all one (FR-WIN-1)."
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
  "A role nobody holds is the first one the next session takes (FR-WIN-1)."
  (ecc-window-test--with-sessions one two
    (ecc-window-test--with-frame t
      (ecc-display-session one)
      (should (eq (ecc-window--session-role one) 'main))
      (ecc-window-hide-session one)
      (should (eq (ecc-window-role-for two) 'main)))))

(ert-deftest ecc-window-test-a-side-window-keeps-its-dedication ()
  "Switching what a session window shows leaves it a side window (FR-WIN-1).
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
  "What was hidden is remembered per tab, not per Emacs (FR-WIN-5)."
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
  "Toggle puts back exactly the sessions it took away (FR-WIN-2)."
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

;;;; The source buffer (FR-CTX-1)

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

;;;; Which session a command talks to (FR-WIN-4)

(ert-deftest ecc-window-test-resolve-in-a-session-buffer ()
  "A command in a session buffer talks to that session (FR-WIN-4)."
  (ecc-window-test--with-sessions one two
    (with-current-buffer (ecc-session-ensure-buffer two)
      (should (eq (ecc-window-resolve-session) two)))
    (with-current-buffer (ecc-session-ensure-buffer one)
      (ecc-chat-goto-prompt)
      (should (eq (ecc-window-resolve-session) one)))))

(ert-deftest ecc-window-test-resolve-by-project-then-recency ()
  "The project decides, and failing that the session last used (FR-WIN-4)."
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
  "The one session on screen wins over the one used last (FR-WIN-4)."
  (ecc-window-test--with-sessions one two
    (with-temp-buffer
      (cl-letf (((symbol-function 'ecc-window-session-visible-p)
                 (lambda (session &optional _frame) (eq session two))))
        (let ((default-directory "/tmp/elsewhere/"))
          (ecc-model-touch one)
          (should (eq (ecc-window-resolve-session) two)))))))

(ert-deftest ecc-window-test-resolve-asks-and-remembers ()
  "A prefix argument asks, and the answer sticks to the buffer (FR-WIN-4)."
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


;;;; Opening a review (FR-WIN-5)

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
  "`ecc-window-hide-on-review' takes the session windows away (FR-WIN-5)."
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
