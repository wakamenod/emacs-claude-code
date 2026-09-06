;;; ecc-visual-test.el --- Tests for ecc-visual  -*- lexical-binding: t; -*-

;;; Commentary:

;; The visual effects of FR-OUT-11 (plan section 6.17).  Batch has no
;; window, so the timers are not left to run: each tick is called
;; directly and what it left on the overlay is inspected.  What the
;; tests do check is that a timer stops itself when nobody is looking,
;; that no more than `ecc-visual-max-effects' of them exist at once, and
;; that every effect can be turned off by itself.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-visual)
(require 'ecc-render)
(require 'ecc-session)

(defmacro ecc-visual-test-with-buffer (var &rest body)
  "Run BODY with VAR bound to a fresh buffer, with every effect on."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((ecc-visual-enable-spinner t)
         (ecc-visual-enable-pulse t)
         (ecc-visual-enable-blink t)
         (ecc-visual-enable-icons t)
         (ecc-visual-enable-flash t)
         (,var (generate-new-buffer " *ecc-visual-test*")))
     (unwind-protect
         (with-current-buffer ,var
           (insert "one\ntwo\nthree\n")
           ,@body)
       (ecc-visual-clear-effects ,var)
       (ecc-visual-spinner-stop ,var)
       (kill-buffer ,var))))

(defun ecc-visual-test--overlay (buffer)
  "Return a new overlay over the first line of BUFFER."
  (with-current-buffer buffer
    (make-overlay (point-min) (line-end-position))))

;;;; The spinner (FR-OUT-11 a)

(ert-deftest ecc-visual-test-spinner-frames ()
  "The frame follows the tick and wraps around."
  (let ((ecc-visual-enable-spinner t)
        (ecc-visual-spinner-frames ["a" "b" "c"]))
    (let ((ecc-visual--tick 0))
      (should (equal (ecc-visual-spinner-frame) "a")))
    (let ((ecc-visual--tick 4))
      (should (equal (ecc-visual-spinner-frame) "b")))
    ;; No frames at all is not an error.
    (let ((ecc-visual-spinner-frames [])
          (ecc-visual--tick 1))
      (should (equal (ecc-visual-spinner-frame) "")))))

(ert-deftest ecc-visual-test-spinner-string-can-be-turned-off ()
  "`ecc-visual-enable-spinner' nil leaves nothing behind."
  (let ((ecc-visual-enable-spinner nil))
    (should (equal (ecc-visual-spinner-string) "")))
  (let ((ecc-visual-enable-spinner t)
        (ecc-visual--tick 0)
        (ecc-visual-spinner-frames ["a"]))
    (should (equal (substring-no-properties (ecc-visual-spinner-string)) "a"))
    (should (eq (get-text-property 0 'face (ecc-visual-spinner-string))
                'ecc-pending-face))))

(ert-deftest ecc-visual-test-spinner-is-one-per-buffer ()
  "Starting the spinner twice leaves one timer, and stopping it removes it."
  (ecc-visual-test-with-buffer buffer
    (ecc-visual-spinner-start buffer)
    (ecc-visual-spinner-start buffer)
    (should (ecc-visual-spinner-running-p buffer))
    (should (= 1 (hash-table-count ecc-visual--spinner-timers)))
    (ecc-visual-spinner-stop buffer)
    (should-not (ecc-visual-spinner-running-p buffer))))

(ert-deftest ecc-visual-test-spinner-stops-when-nobody-looks ()
  "A tick for a buffer shown in no window cancels the timer (NFR-3)."
  (ecc-visual-test-with-buffer buffer
    (ecc-visual-spinner-start buffer)
    (should (ecc-visual-spinner-running-p buffer))
    ;; Batch shows the buffer in no window, which is exactly the case
    ;; the tick is meant to notice.
    (ecc-visual--spinner-tick buffer)
    (should-not (ecc-visual-spinner-running-p buffer))))

;;;; Pulsing and blinking (FR-OUT-11 b, c)

(ert-deftest ecc-visual-test-blend ()
  "Two colours blend, and an unknown colour blends to nothing."
  (should (equal (ecc-visual-blend "#000000" "#ffffff" 0.0) "#000000"))
  (should (equal (ecc-visual-blend "#000000" "#ffffff" 1.0) "#ffffff"))
  (should (equal (ecc-visual-blend "#000000" "#ffffff" 0.5) "#7f7f7f"))
  (should-not (ecc-visual-blend "not-a-colour" "#ffffff" 0.5)))

(ert-deftest ecc-visual-test-pulse-colour-follows-the-phase ()
  "The pulse leaves the background, goes as far as the depth and returns."
  (let* ((ecc-visual-pulse-period 1.0)
         (ecc-visual-pulse-interval 0.25)   ; four steps to the period
         (ecc-visual-pulse-depth 1.0)
         (ecc-visual-pulse-color "#ffffff")
         (colours (mapcar (lambda (phase)
                            (ecc-visual--pulse-background phase "#000000"))
                          '(0 1 2 3 4))))
    (should (equal (nth 0 colours) "#000000"))
    (should (equal (nth 2 colours) "#ffffff"))
    ;; It comes back to where it started, so the loop has no seam.
    (should (equal (nth 4 colours) (nth 0 colours)))
    (should (equal (nth 1 colours) (nth 3 colours)))
    ;; A display that cannot name its background gets no colour, and the
    ;; overlay falls back to a plain face.
    (should-not (ecc-visual--pulse-background 1 "unspecified-bg"))))

(ert-deftest ecc-visual-test-pulse-puts-a-face-on-every-tick ()
  "A pulsing overlay always carries something, and stopping clears it."
  (ecc-visual-test-with-buffer buffer
    (let ((overlay (ecc-visual-test--overlay buffer)))
      (ecc-visual-pulse-overlay overlay)
      (should (overlay-get overlay 'ecc-visual-timer))
      (dotimes (_ 4)
        (should (overlay-get overlay 'face))
        (overlay-put overlay 'ecc-visual-phase
                     (1+ (overlay-get overlay 'ecc-visual-phase)))
        (ecc-visual--pulse-tick overlay))
      (ecc-visual-stop-overlay overlay)
      (should-not (overlay-get overlay 'ecc-visual-timer))
      (should-not (overlay-get overlay 'face)))))

(ert-deftest ecc-visual-test-blink-alternates ()
  "A blinking overlay is on every other tick."
  (ecc-visual-test-with-buffer buffer
    (let ((overlay (ecc-visual-test--overlay buffer)))
      (ecc-visual-blink-overlay overlay)
      (should-not (overlay-get overlay 'face))
      (overlay-put overlay 'ecc-visual-phase 1)
      (ecc-visual--blink-tick overlay)
      (should (eq (overlay-get overlay 'face) 'ecc-visual-blink-face))
      (overlay-put overlay 'ecc-visual-phase 2)
      (ecc-visual--blink-tick overlay)
      (should-not (overlay-get overlay 'face))
      ;; A buffer nobody is looking at stops the effect rather than
      ;; ticking on (NFR-3).
      (ecc-visual--tick-overlay overlay #'ecc-visual--blink-tick)
      (should-not (overlay-get overlay 'ecc-visual-timer)))))

(ert-deftest ecc-visual-test-effects-are-limited ()
  "No more than `ecc-visual-max-effects' overlays move at a time."
  (ecc-visual-test-with-buffer buffer
    (let ((ecc-visual-max-effects 2)
          (overlays (list (ecc-visual-test--overlay buffer)
                          (ecc-visual-test--overlay buffer)
                          (ecc-visual-test--overlay buffer))))
      (mapc #'ecc-visual-blink-overlay overlays)
      (should (= 2 (length (ecc-visual-effects))))
      ;; The oldest is the one that was dropped.
      (should-not (overlay-get (nth 0 overlays) 'ecc-visual-timer))
      (should (overlay-get (nth 2 overlays) 'ecc-visual-timer))
      (ecc-visual-clear-effects buffer)
      (should-not (ecc-visual-effects)))))

(ert-deftest ecc-visual-test-effects-can-be-turned-off ()
  "Each effect answers to its own setting (FR-OUT-11)."
  (ecc-visual-test-with-buffer buffer
    (let ((ecc-visual-enable-pulse nil)
          (ecc-visual-enable-blink nil)
          (ecc-visual-enable-flash nil))
      (let ((overlay (ecc-visual-test--overlay buffer)))
        (ecc-visual-pulse-overlay overlay)
        (ecc-visual-blink-overlay overlay)
        (should-not (overlay-get overlay 'ecc-visual-timer))
        (should-not (ecc-visual-effects)))
      (should-not (ecc-visual-flash-region (point-min) (point-max))))))

;;;; Icons (FR-OUT-11 d)

(ert-deftest ecc-visual-test-icons ()
  "Every tool gets an icon, and turning icons off gets nothing."
  (let ((ecc-visual-enable-icons t))
    ;; With no nerd font the ASCII stand-in is what comes back, and it is
    ;; what the tests can count on wherever they run.
    (let ((ecc-visual--nerd-icons nil))
      (should (equal (ecc-visual-icon "Bash") "$"))
      (should (equal (ecc-visual-icon "Edit") "✎"))
      ;; A tool nobody listed still gets something.
      (should (equal (ecc-visual-icon "NoSuchTool")
                     (cdr ecc-visual-default-icon)))
      (should (equal (ecc-visual-icon nil) (cdr ecc-visual-default-icon)))))
  (let ((ecc-visual-enable-icons nil))
    (should (equal (ecc-visual-icon "Bash") ""))))

;;;; What the renderer does with them

(ert-deftest ecc-visual-test-render-puts-an-icon-in-a-tool-heading ()
  "The heading of a tool call carries its icon (FR-OUT-11 d)."
  (ecc-test-with-fake-session session
    (let ((ecc-visual-enable-icons t)
          (ecc-visual--nerd-icons nil))
      (ecc-session-ensure-buffer session)
      (ecc-test-dispatch session "tool-use-write" "write a file")
      (ecc-render-flush session)
      (should (string-search "W Write"
                             (ecc-test-buffer-string (ecc-session-buffer session)))))))

(ert-deftest ecc-visual-test-render-notes-a-waiting-request ()
  "A request waiting for an answer is noted for the blink (FR-OUT-11 c)."
  (ecc-test-with-fake-session session
    (let ((ecc-visual-enable-blink t)
          (ecc-visual-enable-pulse t))
      (ecc-session-ensure-buffer session)
      (ecc-test-feed-until-request session "tool-use-write" "write a file")
      (ecc-render-flush session)
      (with-current-buffer (ecc-session-buffer session)
        ;; The redraw notes the line and then animates it; nothing is on
        ;; screen in batch, so what is checked is that an overlay was made
        ;; over the heading of the request.
        (should (seq-find (lambda (overlay)
                            (overlay-get overlay 'ecc-visual-timer))
                          (overlays-in (point-min) (point-max))))))))

(ert-deftest ecc-visual-test-render-turns-the-spinner-with-the-state ()
  "The spinner runs while a turn does and stops when it is over."
  (ecc-test-with-fake-session session
    (let ((ecc-visual-enable-spinner t))
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "hello")
      (ecc-model-set-state session 'running)
      (ecc-render-flush session)
      (should (ecc-visual-spinner-running-p (ecc-session-buffer session)))
      (ecc-model-set-state session 'idle)
      (ecc-render-flush session)
      (should-not (ecc-visual-spinner-running-p (ecc-session-buffer session))))))

(ert-deftest ecc-visual-test-render-asks-for-a-flash-when-a-turn-ends ()
  "A finished turn asks the live region to flash once (FR-OUT-11 e)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-render--on-turn-finished session)
    (with-current-buffer (ecc-session-buffer session)
      (should ecc-render--flash-pending))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (should-not ecc-render--flash-pending))))

(provide 'ecc-visual-test)

;;; ecc-visual-test.el ends here
