;;; ecc-notify-test.el --- Tests for ecc-notify  -*- lexical-binding: t; -*-

;;; Commentary:

;; The three events worth an interruption, the levels they are announced
;; at, and the rule that a desktop notification is pointless while the
;; user is looking at Emacs.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)
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

(defun ecc-notify-test--dark-spec (face)
  "Return the attributes FACE puts on a colour display with a dark background.
`face-attribute' answers with nothing in batch, where there is no such
display, so the `defface' spec is read instead."
  (cdr (seq-find (lambda (entry)
                   (let ((display (car entry)))
                     (or (eq display t)
                         (and (consp display)
                              (member '(background dark) display)))))
                 (get face 'face-defface-spec))))

(ert-deftest ecc-notify-test-a-turn-that-went-well-is-not-an-error ()
  "Only a turn whose result says so is announced as an error.
The CLI sends `is_error\\=' false on every turn that went well, and JSON
false is read as `:false\\=', which is a symbol and therefore true to
Emacs: asking for the value itself called every finished turn an error."
  (ecc-test-with-fake-session session
    (let ((turn (ecc-model-begin-turn session "hello")))
      (ecc-model-finish-turn session '((duration_ms . 1500) (is_error . :false)))
      (should (equal (ecc-notify-turn-text session turn)
                     (format "%s: done (1.5s)" (ecc-session-name session)))))
    (let ((turn (ecc-model-begin-turn session "again")))
      (ecc-model-finish-turn session '((duration_ms . 2000) (is_error . t)))
      (should (equal (ecc-notify-turn-text session turn)
                     (format "%s: done (2.0s, error)" (ecc-session-name session)))))))

(ert-deftest ecc-notify-test-events-can-be-turned-off ()
  "Only the events that were asked for are announced."
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
  "A finished turn and a new request reach the notifier."
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
  "A session the user stopped is not worth a notification."
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


;;;; The tab line of the sessions

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
  "Every session is a tab, coloured by what it is doing."
  (ecc-test-with-fake-session first
    (let ((second (ecc-model-create-session
                   :name "other" :project-root temporary-file-directory)))
      (unwind-protect
          (progn
            (ecc-session-ensure-buffer first)
            (ecc-session-ensure-buffer second)
            (ecc-model-set-state first 'idle)
            (ecc-model-set-state second 'running)
            (let ((tabs (ecc-tab-line-tabs)))
              (should (equal (mapcar #'buffer-name tabs)
                             (list (buffer-name (ecc-session-buffer first))
                                   (buffer-name (ecc-session-buffer second)))))
              ;; A session with nothing to say carries no mark; a running
              ;; one does.
              (should (equal (ecc-tab-line-tab-name (car tabs)) " test "))
              (should (equal (ecc-tab-line-tab-name (cadr tabs)) " ▶ other "))
              ;; The state is put on top of whatever face the tab line
              ;; settled on, so the theme still shapes the tab.
              ;; A working session the window is not showing takes the
              ;; quieter green: the full one read as the current tab.
              (should (equal (ecc-tab-line-tab-face
                              (cadr tabs) tabs 'tab-line-tab-inactive t nil)
                             '(:inherit (ecc-tab-running-dim-face
                                         tab-line-tab-inactive))))
              ;; The tab the window shows keeps its state colour, the
              ;; current face being laid under it rather than over it.
              ;; An idle one is dimmed by neither.
              (should (equal (ecc-tab-line-tab-face
                              (car tabs) tabs 'tab-line-tab-current t t)
                             '(:inherit (ecc-tab-current-face
                                         tab-line-tab-current))))
              (ecc-model-set-state first 'running)
              (should (equal (ecc-tab-line-tab-face
                              (car tabs) tabs 'tab-line-tab-current t t)
                             '(:inherit (ecc-tab-running-face
                                         ecc-tab-current-face
                                         tab-line-tab-current))))
              (ecc-model-set-state first 'idle)))
        (ecc-test-cleanup-session second)
        (ecc-model-remove-session second)))))

(ert-deftest ecc-notify-test-tab-line-keeps-the-order-sessions-were-made-in ()
  "Using a session does not move its tab.
The registry is most recently used first, which would shuffle the tabs
about as one works."
  (ecc-test-with-fake-session first
    (let ((second (ecc-model-create-session
                   :name "other" :project-root temporary-file-directory)))
      (unwind-protect
          (progn
            (ecc-session-ensure-buffer first)
            (ecc-session-ensure-buffer second)
            (let ((before (ecc-tab-line-tabs)))
              ;; The second session is used, so it heads the registry.
              (ecc-model-touch second)
              (should (eq (car (ecc-model-sessions)) second))
              (should (equal (ecc-tab-line-tabs) before))))
        (ecc-test-cleanup-session second)
        (ecc-model-remove-session second)))))

(ert-deftest ecc-notify-test-tab-line-mode-installs-and-removes ()
  "The mode turns `tab-line-mode' on in the session buffers, and off again."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (unwind-protect
        (progn
          (ecc-tab-line-mode 1)
          (with-current-buffer (ecc-session-buffer session)
            (should tab-line-mode)
            (should (eq tab-line-tabs-function #'ecc-tab-line-tabs))
            (should (eq tab-line-tab-name-function #'ecc-tab-line-tab-name))
            (should (equal tab-line-tab-face-functions
                           '(ecc-tab-line-tab-face)))
            ;; The x of a tab has to end the session: burying the buffer,
            ;; which is what the tab line does by itself, leaves the tab
            ;; where it was.
            (should (eq tab-line-close-tab-function #'ecc-tab-close)))
          (ecc-tab-line-mode -1)
          (with-current-buffer (ecc-session-buffer session)
            (should-not tab-line-mode)
            (should-not (local-variable-p 'tab-line-tabs-function))
            (should-not (local-variable-p 'tab-line-close-tab-function))))
      (ecc-tab-line-mode -1))))

(ert-deftest ecc-notify-test-a-working-tab-elsewhere-is-quieter ()
  "The green of a working session is the full one only on the current tab.
Two sessions, because the whole point is the difference between the tab
in front of you and the one beside it."
  (ecc-test-with-fake-session first
    (let ((second (ecc-model-create-session
                   :name "other" :project-root temporary-file-directory)))
      (unwind-protect
          (progn
            (ecc-model-set-state first 'running)
            (ecc-model-set-state second 'running)
            (should (equal (ecc-tab-faces first t)
                           '(ecc-tab-running-face ecc-tab-current-face)))
            (should (equal (ecc-tab-faces second nil)
                           '(ecc-tab-running-dim-face)))
            ;; The quieter green is a green of its own, and it carries
            ;; no weight: bold was half of what made it read as the
            ;; current tab.  Batch has no colour display, so the specs
            ;; are read rather than the faces resolved.
            (let ((dim (ecc-notify-test--dark-spec 'ecc-tab-running-dim-face))
                  (full (ecc-notify-test--dark-spec 'ecc-running-face)))
              (should (plist-get dim :foreground))
              (should-not (equal (plist-get dim :foreground)
                                 (plist-get full :foreground)))
              (should-not (plist-get dim :inherit))
              (should-not (plist-get dim :weight))))
        (ecc-test-cleanup-session second)
        (ecc-model-remove-session second)))))

(ert-deftest ecc-notify-test-the-x-of-a-tab-stops-the-session ()
  "The close button ends the session, and asks before it does."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let ((buffer (ecc-session-buffer session))
          (killed nil))
      (cl-letf (((symbol-function #'ecc-kill)
                 (lambda (s) (setq killed s))))
        ;; Answering no leaves the session alone.
        (let ((ecc-tab-close-confirm t))
          (cl-letf (((symbol-function #'y-or-n-p) (lambda (&rest _) nil)))
            (ecc-tab-close buffer))
          (should-not killed)
          (cl-letf (((symbol-function #'y-or-n-p) (lambda (&rest _) t)))
            (ecc-tab-close buffer))
          (should (eq killed session)))
        (setq killed nil)
        (let ((ecc-tab-close-confirm nil))
          (ecc-tab-close buffer)
          (should (eq killed session)))))))

(ert-deftest ecc-notify-test-the-x-of-a-buffer-with-no-session-kills-it ()
  "A tab that is not a session is closed the plain way."
  (let ((buffer (generate-new-buffer " *ecc-test-plain*")))
    (ecc-tab-close buffer)
    (should-not (buffer-live-p buffer))
    ;; A buffer that is gone already is not an error.
    (ecc-tab-close buffer)))

(ert-deftest ecc-notify-test-a-waiting-tab-blinks ()
  "The tab of a session waiting for an answer is lit on every other beat.
Two sessions, so that the one that wants nothing is seen to stay put."
  (ecc-test-with-fake-session first
    (let ((second (ecc-model-create-session
                   :name "other" :project-root temporary-file-directory)))
      (unwind-protect
          (progn
            (ecc-model-set-state first 'idle)
            (ecc-model-set-state second 'idle)
            (ecc-test-add-request first)
            (should (eq (ecc-tab-state first) 'attention))
            (let ((ecc-tab--blink-phase nil))
              (should (equal (ecc-tab-faces first nil)
                             '(ecc-tab-attention-face)))
              (should (equal (ecc-tab-faces second nil)
                             '(ecc-tab-idle-face))))
            (let ((ecc-tab--blink-phase t))
              (should (equal (ecc-tab-faces first nil)
                             '(ecc-tab-attention-blink-face)))
              ;; Being the tab the window shows does not hold the blink
              ;; off, and it does not cost the tab its colour either:
              ;; the current face is laid under the state, not over it.
              (should (equal (ecc-tab-faces first t)
                             '(ecc-tab-attention-blink-face
                               ecc-tab-current-face)))
              ;; A session that wants nothing is left alone.
              (should (equal (ecc-tab-faces second nil)
                             '(ecc-tab-idle-face)))
              ;; Idle is the one state the current tab does not wear:
              ;; the tab being read is not one to sink into the
              ;; background.
              (should (equal (ecc-tab-faces second t)
                             '(ecc-tab-current-face)))))
        (ecc-test-cleanup-session second)
        (ecc-model-remove-session second)))))

(ert-deftest ecc-notify-test-the-blink-runs-only-while-something-waits ()
  "The timer starts with a request and is gone once it is answered."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (unwind-protect
        (let ((ecc-tab-blink t))
          (ecc-tab-line-mode 1)
          ;; Nothing is waiting yet.
          (should-not ecc-tab--blink-timer)
          (let ((request (ecc-test-add-request session)))
            (ecc-tab-blink-update)
            (should ecc-tab--blink-timer)
            ;; A tick turns the tabs over without stopping.
            (ecc-tab--blink-tick)
            (should ecc-tab--blink-phase)
            (should ecc-tab--blink-timer)
            (ecc-model-resolve-request session request 'allowed))
          (ecc-tab-blink-update)
          (should-not ecc-tab--blink-timer)
          (should-not ecc-tab--blink-phase))
      (ecc-tab-blink-stop)
      (ecc-tab-line-mode -1))))

(ert-deftest ecc-notify-test-the-blink-can-be-turned-off ()
  "`ecc-tab-blink' nil leaves the tab coloured but still."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (unwind-protect
        (let ((ecc-tab-blink nil))
          (ecc-tab-line-mode 1)
          (ecc-test-add-request session)
          (ecc-tab-blink-update)
          (should-not ecc-tab--blink-timer)
          (should (equal (ecc-tab-faces session nil)
                         '(ecc-tab-attention-face))))
      (ecc-tab-blink-stop)
      (ecc-tab-line-mode -1))))

(ert-deftest ecc-notify-test-tab-bar-name ()
  "The tab bar carries the state only when it is asked to."
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
