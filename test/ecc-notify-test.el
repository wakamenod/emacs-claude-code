;;; ecc-notify-test.el --- Tests for ecc-notify  -*- lexical-binding: t; -*-

;;; Commentary:

;; The three events worth an interruption, the levels they are announced
;; at, and the rule that a desktop notification is pointless while the
;; user is looking at Emacs (FR-NOTIFY-1).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-notify)
(require 'ecc-session)

(defmacro ecc-notify-test--collecting (var &rest body)
  "Run BODY with `ecc-notify-function' collecting (EVENT . TEXT) into VAR."
  (declare (indent 1))
  ;; Appended rather than pushed, so that BODY can look at what has been
  ;; collected so far without reversing it first.
  `(let ((,var nil))
     (let ((ecc-notify-function
            (lambda (_session event text)
              (setq ,var (append ,var (list (cons event text)))))))
       ,@body)))

(ert-deftest ecc-notify-test-events-can-be-turned-off ()
  "Only the events that were asked for are announced (FR-NOTIFY-1, NFR-3)."
  (ecc-test-with-fake-session session
    (ecc-notify-test--collecting seen
      (let ((ecc-notify-events '(request)))
        (ecc-notify session 'turn-finished "done")
        (ecc-notify session 'request "waiting"))
      (should (equal seen '((request . "waiting")))))
    (ecc-notify-test--collecting seen
      (let ((ecc-notify-level nil))
        (ecc-notify session 'request "waiting"))
      (should-not seen))))

(ert-deftest ecc-notify-test-hooks ()
  "A finished turn and a new request reach the notifier (FR-NOTIFY-1)."
  (ecc-test-with-fake-session session
    (unwind-protect
        (ecc-notify-test--collecting seen
          (ecc-notify-mode 1)
          (ecc-model-begin-turn session "hello")
          (ecc-test-add-request session)
          (ecc-model-finish-turn session '((duration_ms . 1500)))
          (should (equal (mapcar #'car seen) '(request turn-finished)))
          (should (string-search "Write" (cdr (assq 'request seen))))
          (should (string-search "done" (cdr (assq 'turn-finished seen))))
          (should (string-search "1.5s" (cdr (assq 'turn-finished seen)))))
      (ecc-notify-mode -1))))

(ert-deftest ecc-notify-test-only-an-abnormal-exit-is-announced ()
  "A session the user stopped is not worth a notification (FR-NOTIFY-1)."
  (ecc-test-with-fake-session session
    (ecc-notify-test--collecting seen
      (ecc-notify--exited session 0)
      (should-not seen)
      (ecc-notify--exited session 1)
      (should (equal (mapcar #'car seen) '(exited)))
      (should (string-search "code 1" (cdar seen))))
    (ecc-notify-test--collecting seen
      ;; Stopped on request: silence.
      (setf (alist-get 'stop-requested (ecc-session-progress session)) t)
      (ecc-notify--exited session 9)
      (should-not seen))))

(ert-deftest ecc-notify-test-desktop-is-held-back-while-focused ()
  "A desktop notification is skipped when Emacs already has the focus."
  (let ((ecc-notify-level 'desktop)
        (ecc-notify-suppress-when-focused t))
    (cl-letf (((symbol-function 'ecc-notify-focused-p) (lambda () t)))
      (should-not (ecc-notify-desktop-p)))
    (cl-letf (((symbol-function 'ecc-notify-focused-p) (lambda () nil)))
      (should (ecc-notify-desktop-p))
      ;; The setting turns the rule off.
      (let ((ecc-notify-suppress-when-focused nil))
        (cl-letf (((symbol-function 'ecc-notify-focused-p) (lambda () t)))
          (should (ecc-notify-desktop-p))))))
  ;; At the other levels nothing reaches the desktop at all.
  (let ((ecc-notify-level 'message))
    (cl-letf (((symbol-function 'ecc-notify-focused-p) (lambda () nil)))
      (should-not (ecc-notify-desktop-p)))))

(ert-deftest ecc-notify-test-applescript-is-quoted ()
  "A quote in a session name does not end the AppleScript string."
  (let ((ecc-notify-title "Claude Code")
        (ecc-notify-sound nil))
    (should (equal (ecc-notify--applescript "say \"hi\"")
                   "display notification \"say \\\"hi\\\"\" with title \"Claude Code\""))
    (let ((ecc-notify-sound "Glass"))
      (should (string-suffix-p " sound name \"Glass\""
                               (ecc-notify--applescript "done"))))))

(ert-deftest ecc-notify-test-default-says-it-in-the-echo-area ()
  "The default notifier writes one line and asks for no desktop help."
  (ecc-test-with-fake-session session
    (let ((ecc-notify-level 'message)
          (said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq said (apply #'format format args))))
                ((symbol-function 'ecc-notify-desktop)
                 (lambda (_text) (error "The desktop must not be bothered"))))
        (should (ecc-notify-default session 'request "waiting"))
        (should (equal said "waiting"))))))


;;;; The tab line of the sessions (FR-NOTIFY-2)

(ert-deftest ecc-notify-test-tab-state ()
  "A session is running, waiting, exited or idle, and shows the mark of it."
  (ecc-test-with-fake-session session
    (ecc-model-set-state session 'idle)
    (should (eq (ecc-tab-state session) 'idle))
    (ecc-model-set-state session 'running)
    (should (eq (ecc-tab-state session) 'running))
    ;; A request waiting for an answer beats anything else: it is the
    ;; one state the user has to do something about.
    (ecc-test-add-request session)
    (should (eq (ecc-tab-state session) 'attention))
    (should (equal (ecc-tab-mark session) "⚠"))))

(ert-deftest ecc-notify-test-tab-line-lists-every-session ()
  "Every session is a tab, the one being shown is marked as current."
  (ecc-test-with-fake-session first
    (let ((second (ecc-model-create-session
                   :name "other" :project-root temporary-file-directory)))
      (unwind-protect
          (progn
            (ecc-session-ensure-buffer first)
            (ecc-model-set-state second 'running)
            (let ((line (substring-no-properties
                         (ecc-tab-line-string (ecc-session-buffer first)))))
              (should (string-search "test" line))
              (should (string-search "other" line))
              (should (string-search "●" line)))
            ;; From the buffer of the first session, the first tab is the
            ;; current one and the second is not.
            (let* ((line (ecc-tab-line-string (ecc-session-buffer first)))
                   (at (lambda (name)
                         (get-text-property (string-search name line) 'face line))))
              (should (eq (funcall at "test") 'ecc-tab-current-face))
              (should (eq (funcall at "other") 'ecc-tab-running-face))))
        (ecc-test-cleanup-session second)
        (ecc-model-remove-session second)))))

(ert-deftest ecc-notify-test-tab-line-mode-installs-and-removes ()
  "The mode puts the tab line in the session buffers and takes it out."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (unwind-protect
        (progn
          (ecc-tab-line-mode 1)
          (with-current-buffer (ecc-session-buffer session)
            (should (equal tab-line-format ecc-tab-line--construct)))
          (ecc-tab-line-mode -1)
          (with-current-buffer (ecc-session-buffer session)
            (should-not tab-line-format)))
      (ecc-tab-line-mode -1))))

(ert-deftest ecc-notify-test-tab-bar-name ()
  "The tab bar carries the state only when it is asked to (FR-NOTIFY-2)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (cl-letf (((default-value 'tab-bar-tab-name-function) (lambda () "work"))
              ((symbol-function #'get-buffer-window) (lambda (&rest _) t)))
      (ecc-test-add-request session)
      (let ((ecc-tab-bar-state nil))
        (should (equal (ecc-tab-bar-tab-name) "work")))
      (let ((ecc-tab-bar-state t))
        (should (equal (ecc-tab-bar-tab-name) "⚠ work"))))))

(provide 'ecc-notify-test)

;;; ecc-notify-test.el ends here
