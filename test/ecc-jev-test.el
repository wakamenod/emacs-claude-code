;;; ecc-jev-test.el --- Tests for ecc-jev  -*- lexical-binding: t; -*-

;;; Commentary:

;; What a verdict draws, and what it is not allowed to draw: a verdict
;; nobody is sure of, one that says the turn is done, and one that
;; arrived about a turn the session has already moved past.
;;
;; Nothing here needs jev.el, which is not installed on every machine:
;; the verdicts go in through `ecc-jev-note-verdict' rather than through
;; `jev-ask'.  The one test of the round trip itself skips when jev.el
;; is absent, and stubs its transport when it is there, so no test ever
;; reaches the network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-jev)
(require 'ecc-sidebar)

(defmacro ecc-jev-test--with-session (var &rest body)
  "Run BODY with VAR an idle session, Jev on and nothing recorded."
  (declare (indent 1) (debug (symbolp body)))
  `(ecc-test-with-fake-session ,var
     (let ((ecc-jev-enabled t)
           (ecc-jev--verdicts (make-hash-table :test #'equal))
           (ecc-jev--requests (make-hash-table :test #'equal))
           (ecc-jev-confidence-threshold 0.6))
       (ecc-model-set-state ,var 'idle)
       ,@body)))

(defun ecc-jev-test--turn (session text)
  "Finish a turn of SESSION whose last assistant message is TEXT."
  (let ((turn (ecc-model-begin-turn session "do it")))
    (ecc-model-add-node session :type 'text :parent turn
                        :data (list (cons 'text text)))
    (ecc-model-finish-turn session '((total_cost_usd . 0.01)))
    (ecc-model-set-state session 'idle)
    turn))

;;;; The mark a verdict draws

(ert-deftest ecc-jev-test-a-verdict-marks-the-row ()
  "Each verdict that means something has a mark of its own."
  (should (equal (ecc-jev-mark-of 'needs-decision 0.9) "?"))
  (should (equal (ecc-jev-mark-of 'blocked 0.9) "!"))
  (should (equal (ecc-jev-mark-of 'partial 0.9) "…")))

(ert-deftest ecc-jev-test-done-says-nothing ()
  "A mark on every finished turn would say nothing, so `done' draws none."
  (should-not (ecc-jev-mark-of 'done 0.99))
  (should-not (ecc-jev-mark-of nil 0.99)))

(ert-deftest ecc-jev-test-an-unknown-verdict-says-nothing ()
  "A verdict this Emacs has no mark for leaves the row as it was."
  (should-not (ecc-jev-mark-of 'reticulating 0.99)))

(ert-deftest ecc-jev-test-below-the-threshold-says-nothing ()
  "A verdict nobody is sure of draws the ordinary mark."
  (let ((ecc-jev-confidence-threshold 0.6))
    (should-not (ecc-jev-mark-of 'blocked 0.4))
    (should (equal (ecc-jev-mark-of 'blocked 0.6) "!"))
    ;; A provider that sends no confidence at all is not a confident one.
    (should-not (ecc-jev-mark-of 'blocked nil))))

(ert-deftest ecc-jev-test-a-question-outranks-the-choice ()
  "A turn that calls itself done and ends in a question waits on the user."
  (should (eq (ecc-jev--verdict-of "done" t) 'needs-decision))
  (should (eq (ecc-jev--verdict-of "partial" t) 'needs-decision))
  (should (eq (ecc-jev--verdict-of "done" nil) 'done))
  ;; Blocked is blocked: what it asks for is not a decision it can take.
  (should (eq (ecc-jev--verdict-of "blocked" t) 'blocked)))

;;;; What is recorded, and when it is dropped

(ert-deftest ecc-jev-test-a-verdict-is-kept-for-the-session ()
  "A verdict about the session's last turn is recorded and drawn."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two do you want?")))
      (should (ecc-jev-note-verdict session turn 'needs-decision 0.9))
      (should (equal (ecc-jev-verdict session) '(needs-decision . 0.9)))
      (should (equal (ecc-jev-sidebar-mark session "·") "?")))))

(ert-deftest ecc-jev-test-a-stale-verdict-is-dropped ()
  "An answer about a turn the session has moved past changes nothing."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two?")))
      (ecc-jev-test--turn session "Done.")
      (should-not (ecc-jev-note-verdict session turn 'needs-decision 0.9))
      (should-not (ecc-jev-verdict session))
      (should (equal (ecc-jev-sidebar-mark session "·") "·")))))

(ert-deftest ecc-jev-test-a-verdict-about-a-running-session-is-dropped ()
  "The session started saying something else while the answer was in flight."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two?")))
      (ecc-model-set-state session 'running)
      (should-not (ecc-jev-note-verdict session turn 'needs-decision 0.9))
      (should-not (ecc-jev-verdict session)))))

(ert-deftest ecc-jev-test-a-verdict-about-a-gone-session-is-dropped ()
  "A session that was forgotten takes its verdict with it."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two?")))
      (ecc-model-remove-session session)
      (should-not (ecc-jev-note-verdict session turn 'needs-decision 0.9)))))

(ert-deftest ecc-jev-test-a-new-turn-forgets-the-verdict ()
  "What the last turn meant says nothing about the one now running."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two?")))
      (ecc-jev-note-verdict session turn 'blocked 0.9)
      (ecc-model-begin-turn session "the left one")
      (should-not (ecc-jev-verdict session)))))

(ert-deftest ecc-jev-test-off-draws-nothing ()
  "With the setting off a recorded verdict still changes no row."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two?")))
      (ecc-jev-note-verdict session turn 'blocked 0.9)
      (let ((ecc-jev-enabled nil))
        (should (equal (ecc-jev-sidebar-mark session "·") "·"))))))

(ert-deftest ecc-jev-test-a-running-session-keeps-its-spinner ()
  "The mark of a running session is the animation, whatever Jev said."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two?")))
      (ecc-jev-note-verdict session turn 'needs-decision 0.9)
      (ecc-model-set-state session 'running)
      (should (equal (ecc-jev-sidebar-mark session "▶") "▶")))))

;;;; What is sent

(ert-deftest ecc-jev-test-the-last-message-is-what-is-sent ()
  "The last assistant text of the turn, trimmed, and the tail of a long one."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-model-begin-turn session "do it")))
      (ecc-model-add-node session :type 'text :parent turn
                          :data (list (cons 'text "first")))
      (ecc-model-add-node session :type 'text :parent turn
                          :data (list (cons 'text "  last  ")))
      (should (equal (ecc-jev--turn-text turn) "last"))
      (let ((ecc-jev-text-limit 4))
        (should (equal (ecc-jev--turn-text turn) "last"))))
    (let ((turn (ecc-model-begin-turn session "again"))
          (ecc-jev-text-limit 3))
      (ecc-model-add-node session :type 'text :parent turn
                          :data (list (cons 'text "abcdef")))
      (should (equal (ecc-jev--turn-text turn) "def")))))

(ert-deftest ecc-jev-test-a-turn-that-said-nothing-is-not-sent ()
  "There is nothing to ask about a turn with no assistant text in it."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-model-begin-turn session "do it")))
      (should-not (ecc-jev--turn-text turn))
      (ecc-model-add-node session :type 'text :parent turn
                          :data (list (cons 'text "   ")))
      (should-not (ecc-jev--turn-text turn)))))

(ert-deftest ecc-jev-test-a-failure-leaves-the-row-alone ()
  "A Jev that is down logs and changes nothing."
  (ecc-jev-test--with-session session
    (ecc-jev--failed "rate limited" session)
    (should-not (ecc-jev-verdict session))
    (should (equal (ecc-jev-sidebar-mark session "·") "·"))
    (should (string-match-p
             "jev: rate limited"
             (ecc-test-log-string (ecc-log-buffer-name (ecc-session-name session)))))))

;;;; The seam in the sidebar

(ert-deftest ecc-jev-test-the-sidebar-honours-the-seam ()
  "`ecc-sidebar-mark-functions' decides the mark a row opens with."
  (ecc-test-with-fake-session session
    (let ((ecc-sidebar-mark-functions
           (list (lambda (_session _mark) "!"))))
      (should (equal (ecc-sidebar--mark-of session "·") "!")))
    ;; One with nothing to say hands back what it was given.
    (let ((ecc-sidebar-mark-functions
           (list (lambda (_session mark) mark)
                 (lambda (_session _mark) nil))))
      (should (equal (ecc-sidebar--mark-of session "·") "·")))))

(ert-deftest ecc-jev-test-the-row-carries-the-verdict ()
  "The drawn row of an idle session opens with the mark of its verdict."
  (ecc-jev-test--with-session session
    (let ((turn (ecc-jev-test--turn session "Which of the two?"))
          (ecc-sidebar-mark-functions (list #'ecc-jev-sidebar-mark)))
      (ecc-jev-note-verdict session turn 'needs-decision 0.9)
      (with-temp-buffer
        (ecc-sidebar--session-row session)
        (should (string-match-p "^? test" (buffer-substring-no-properties
                                           (point-min) (point-max))))))))

;;;; The round trip, only where jev.el is installed

(ert-deftest ecc-jev-test-the-round-trip ()
  "A stubbed reply becomes the mark of the row.
Skipped where jev.el is absent -- it is not a dependency of this
package -- and its transport is replaced where it is there, so this
makes no request either way."
  (unless (require 'jev nil t)
    (ert-skip "jev.el is not installed"))
  (ecc-jev-test--with-session session
    (let* ((redrawn 0)
           (sent nil)
           (jev-api-key "test-key")
           ;; jev.el's own suite stubs its transport here; it is called
           ;; with (URL HEADERS BODY TIMEOUT SYNC CALLBACK) and answers
           ;; with a plist (confirmed against jev.el 2026-09-19).
           (jev-http-function
            (lambda (_url _headers body _timeout sync callback)
              (setq sent (json-parse-string body :object-type 'alist))
              (let ((result
                     (list :status 200 :headers nil
                           :body (json-serialize
                                  '((model . "jev-1")
                                    (answers
                                     (verdict (type . "choice")
                                              (choice . "needs-decision")
                                              (confidence . 0.91))
                                     (asking (type . "noul") (noul . 0.95))))))))
                (if sync result (progn (funcall callback result) nil))))))
      (cl-letf (((symbol-function 'ecc-sidebar-redraw)
                 (lambda (&rest _) (setq redrawn (1+ redrawn)))))
        (ecc-jev-turn-finished session (ecc-jev-test--turn session "Which of the two?"))
        ;; What was sent is the last message, and the two questions.
        (should (string-match-p "Which of the two?"
                                (format "%s" (alist-get 'state sent))))
        (should (equal (car (ecc-jev-verdict session)) 'needs-decision))
        (should (equal (ecc-jev-sidebar-mark session "·") "?"))
        (should (= redrawn 1))))))

(provide 'ecc-jev-test)

;;; ecc-jev-test.el ends here
