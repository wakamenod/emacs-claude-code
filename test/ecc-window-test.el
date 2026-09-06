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

(defmacro ecc-window-test--with-sessions (first second &rest body)
  "Run BODY with two registered sessions bound to FIRST and SECOND.
They live in different projects; the second is the most recently used."
  (declare (indent 2))
  `(let* ((ecc-test-sent nil)
          (ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-window--slots nil)
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
    (ecc-prompt-ensure-buffer one)
    (ecc-rename-session one "refactor")
    (should (equal (ecc-session-name one) "refactor"))
    (should (equal (buffer-name (ecc-session-buffer one)) "*ecc: refactor*"))
    (should (equal (buffer-name (ecc-session-prompt-buffer one))
                   "*ecc-prompt: refactor*"))))

;;;; Slots and hiding (FR-WIN-1, FR-WIN-2, FR-WIN-5)

(ert-deftest ecc-window-test-slots-are-stable ()
  "Each session keeps the slot it was given (FR-WIN-1)."
  (ecc-window-test--with-sessions one two
    (should (= (ecc-window-slot one) 0))
    (should (= (ecc-window-slot two) 1))
    (should (= (ecc-window-slot one) 0))
    ;; The prompt of a session sits next to its transcript.
    (should (equal (alist-get 'slot (ecc-window--side-parameters
                                     (1+ (* 2 (ecc-window-slot two)))))
                   3))
    (ecc-window-forget-session one)
    (should (= (ecc-window-slot one) 2))))

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
        (should (equal (ecc-window-hidden-sessions) (list (ecc-session-id one))))
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
              (should (eq (ecc-window-last-source-buffer) source)))
            (with-current-buffer (ecc-prompt-ensure-buffer one)
              (should (ecc-window-own-buffer-p))
              (should (eq (ecc-window-last-source-buffer) source))))
        (kill-buffer source)))))

;;;; Which session a command talks to (FR-WIN-4)

(ert-deftest ecc-window-test-resolve-in-a-session-buffer ()
  "A command in a transcript or a prompt talks to that session (FR-WIN-4)."
  (ecc-window-test--with-sessions one two
    (with-current-buffer (ecc-session-ensure-buffer two)
      (should (eq (ecc-window-resolve-session) two)))
    (with-current-buffer (ecc-prompt-ensure-buffer one)
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
            (should (member (ecc-session-id session)
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
The prompt buffer goes with it; an agent transcript of the same
session does not count."
  (ecc-test-with-fake-session session
    (let ((buffer (ecc-session-ensure-buffer session))
          (prompt (ecc-prompt-ensure-buffer session))
          (id (ecc-session-id session)))
      (should (ecc-model-session id))
      (kill-buffer buffer)
      (should-not (ecc-model-session id))
      (should-not (buffer-live-p prompt))
      (should-not (assoc id ecc-window--slots)))))

(provide 'ecc-window-test)

;;; ecc-window-test.el ends here
