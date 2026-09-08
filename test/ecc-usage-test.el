;;; ecc-usage-test.el --- Tests for ecc-usage  -*- lexical-binding: t; -*-

;;; Commentary:

;; Reading the answer to the `get_usage' control request and drawing it:
;; the rate limit windows, the usage credits, the cost of the session
;; and the scan saying what has been spending the limits.  The fixture
;; is one recorded control_response, with the numbers rounded.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-usage)

(defun ecc-usage-test--data ()
  "Return the usage answer of the fixture."
  (let ((message (car (ecc-test-fixture-messages "usage"))))
    (alist-get 'response (alist-get 'response message))))

(defmacro ecc-usage-test--fixed-zone (&rest body)
  "Run BODY with the clock and the zone of the reset times pinned.
A snapshot may not depend on where the machine running it is, nor on
when it ran: the windows of the fixture reset 17 minutes and just
under 4 days after the instant fixed here."
  (declare (indent 0) (debug t))
  `(let ((ecc-usage--time-zone t)
         (ecc-usage--now (encode-time (iso8601-parse "2026-09-08T13:43:00+00:00"))))
     ,@body))

(ert-deftest ecc-usage-test-reset-says-how-long-there-is-to-go ()
  "The reset is written the way the web client writes it."
  (ecc-usage-test--fixed-zone
    (should (equal (ecc-usage--reset-string "2026-09-08T14:00:00+00:00")
                   "in 17m"))
    (should (equal (ecc-usage--reset-string "2026-09-12T12:00:00+00:00")
                   "in 3d 22h"))
    ;; A window whose moment has passed is not counted backwards.
    (should (equal (ecc-usage--reset-string "2026-09-08T13:00:00+00:00")
                   "any moment now"))
    (let ((ecc-usage-reset-format 'absolute))
      (should (equal (ecc-usage--reset-string "2026-09-08T14:00:00+00:00")
                     "09/08 14:00")))
    (let ((ecc-usage-reset-format 'both))
      (should (equal (ecc-usage--reset-string "2026-09-08T14:00:00+00:00")
                     "in 17m (09/08 14:00)")))))

(ert-deftest ecc-usage-test-the-bar-is-coloured-for-how-full-it-is ()
  "The used part of a bar carries a face, and the free part is dim."
  (let ((bar (ecc-usage--bar 50)))
    (should (eq (get-text-property 0 'face bar) 'ecc-usage-bar-face))
    (should (eq (get-text-property (1- (length bar)) 'face bar)
                'ecc-usage-bar-empty-face)))
  (should (eq (get-text-property 0 'face (ecc-usage--bar 95))
              'ecc-usage-bar-critical-face))
  (should (eq (get-text-property 0 'face (ecc-usage--bar 75))
              'ecc-usage-bar-warning-face))
  ;; A grade the CLI made itself wins over the thresholds here.
  (should (eq (get-text-property 0 'face (ecc-usage--bar 10 "critical"))
              'ecc-usage-bar-critical-face)))

(ert-deftest ecc-usage-test-fetch-asks-for-get-usage ()
  "The request goes out as a control request of subtype get_usage."
  (ecc-test-with-fake-session session
    (let ((ecc-usage-skip-behaviors nil))
      (ecc-usage-fetch session #'ignore))
    (let ((sent (car (ecc-test-sent-messages))))
      (should (equal (alist-get 'type sent) "control_request"))
      (should (equal (alist-get 'subtype (alist-get 'request sent)) "get_usage"))
      ;; Without the option the CLI does the transcript scan.
      (should-not (assq 'skip_behaviors (alist-get 'request sent))))))

(ert-deftest ecc-usage-test-fetch-can-skip-the-scan ()
  "`ecc-usage-skip-behaviors' leaves out the slow part of the answer."
  (ecc-test-with-fake-session session
    (let ((ecc-usage-skip-behaviors t))
      (ecc-usage-fetch session #'ignore))
    (should (eq (alist-get 'skip_behaviors
                           (alist-get 'request (car (ecc-test-sent-messages))))
                t))))

(ert-deftest ecc-usage-test-windows-come-from-the-limits-array ()
  "The windows are read from `limits', which the CLI already sorted out.
The object beside it carries a window per code name, and new ones keep
arriving, so reading those by name would lose them."
  (let ((windows (ecc-usage-windows (ecc-usage-test--data))))
    (should (equal (mapcar (lambda (w) (plist-get w :title)) windows)
                   '("Current session"
                     "Current week (all models)"
                     "Current week (Fable)")))
    (should (equal (mapcar (lambda (w) (plist-get w :percent)) windows)
                   '(20 25 15)))))

(ert-deftest ecc-usage-test-windows-fall-back-to-the-named-ones ()
  "An answer without `limits' is still read, window by window."
  (let* ((data (ecc-usage-test--data))
         (limits (alist-get 'rate_limits data)))
    (setf (alist-get 'limits limits) nil)
    (let ((windows (ecc-usage-windows data)))
      (should (equal (mapcar (lambda (w) (plist-get w :title)) windows)
                     '("Current session" "Current week (all models)")))
      (should (equal (mapcar (lambda (w) (plist-get w :percent)) windows)
                     '(20 25))))))

(ert-deftest ecc-usage-test-an-unknown-window-is-titled-not-dropped ()
  "A kind the plan grows later shows up under a title made from its name."
  (should (equal (ecc-usage--limit-title '((kind . "monthly_cowork")))
                 "Monthly cowork"))
  (should (equal (ecc-usage--limit-title
                  '((kind . "weekly_scoped")
                    (scope . ((model . ((display_name . "Opus")))))))
                 "Current week (Opus)")))

(ert-deftest ecc-usage-test-credits-are-read-from-spend ()
  "The credits come from `spend', which names its own currency and scale."
  (let ((credits (ecc-usage-credits (ecc-usage-test--data))))
    (should (equal (plist-get credits :limit) "$50.00"))
    (should (equal (plist-get credits :used) "$0.00"))))

(ert-deftest ecc-usage-test-render-snapshot ()
  "The whole answer draws as the snapshot."
  (ecc-usage-test--fixed-zone
    (should (ecc-test-snapshot
             "usage"
             (substring-no-properties (ecc-usage-render (ecc-usage-test--data)))))))

(ert-deftest ecc-usage-test-no-plan-limits ()
  "An API key session is told the plan windows do not apply to it."
  (let ((data (ecc-usage-test--data)))
    (setf (alist-get 'rate_limits_available data) :false)
    (let ((text (substring-no-properties (ecc-usage-render data))))
      (should (string-match-p "Plan limits do not apply" text))
      (should-not (string-match-p "Current week" text))
      ;; The cost of the session is not a plan matter and stays.
      (should (string-match-p "This session" text)))))

(ert-deftest ecc-usage-test-behaviors-null-is-left-out ()
  "The scan is optional; without it the section is not drawn at all."
  (let ((data (ecc-usage-test--data)))
    (setf (alist-get 'behaviors data) nil)
    (let ((text (substring-no-properties (ecc-usage-render data))))
      (should-not (string-match-p "spending the limits" text))
      (should (string-match-p "Current session" text)))))

(ert-deftest ecc-usage-test-a-refusal-is-not-swallowed ()
  "A control request the CLI refuses is drawn, and logged."
  (ecc-test-with-fake-session session
    (unwind-protect
        (progn
          (get-buffer-create ecc-usage-buffer-name)
          (ecc-usage--receive session '((error . "get_usage is not supported")))
          (with-current-buffer ecc-usage-buffer-name
            (should (string-match-p "get_usage is not supported"
                                    (buffer-string))))
          (should (string-match-p
                   "get_usage failed"
                   (ecc-test-log-string
                    (get-buffer (ecc-log-buffer-name
                                 (ecc-session-name session)))))))
      (when (get-buffer ecc-usage-buffer-name)
        (kill-buffer ecc-usage-buffer-name)))))

(ert-deftest ecc-usage-test-a-probe-has-no-session-to-report ()
  "A CLI started only to be asked has a cost of zero, which says nothing."
  (let ((text (substring-no-properties
               (ecc-usage-render (ecc-usage-test--data) t))))
    (should-not (string-match-p "This session" text))
    (should (string-match-p "started for this question alone" text))
    (should (string-match-p "Current session" text))))

(provide 'ecc-usage-test)

;;; ecc-usage-test.el ends here
