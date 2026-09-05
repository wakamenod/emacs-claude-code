;;; ecc-render-test.el --- Tests for ecc-render  -*- lexical-binding: t; -*-

;;; Commentary:

;; Replays a recording into a session buffer and compares the text of the
;; buffer with a snapshot in test/snapshots (plan section 8).  Rewrite a
;; snapshot after an intended change with:
;;
;;     ECC_UPDATE_SNAPSHOTS=1 make test

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-render)
(require 'ecc-session)
(require 'ecc-perm)
(require 'ecc-dispatch)

(defun ecc-render-test--replay (session name prompt &optional answers)
  "Replay fixture NAME into SESSION under PROMPT and draw it.
ANSWERS is a list of `allow' or `(deny . REASON)', used in turn for the
requests the recording makes."
  (ecc-session-ensure-buffer session)
  (ecc-model-begin-turn session prompt)
  (dolist (line (ecc-test-fixture-lines name))
    (let ((message (ecc-protocol-parse-line line)))
      (ecc-dispatch session message)
      (when (and answers (eq (ecc-protocol-control-subtype message) 'can_use_tool))
        (let ((request (car (ecc-session-pending session)))
              (answer (pop answers)))
          (if (eq answer 'allow)
              (ecc-perm-respond request 'allow)
            (ecc-perm-respond request 'deny :message (cdr answer)))))))
  (ecc-render-flush session)
  (ecc-test-buffer-string (ecc-session-buffer session)))

(defun ecc-render-test--check (name text)
  "Fail unless TEXT matches snapshot NAME, saying where to look."
  (unless (ecc-test-snapshot name text)
    (ert-fail (format "%s differs from its snapshot; see %s.new"
                      name (ecc-test-snapshot-file name)))))

;;;; Snapshots

(ert-deftest ecc-render-test-basic-turn ()
  "A plain question and answer draw as one turn with a result line."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "basic-turn" "hello")))
      (ecc-render-test--check "basic-turn" text)
      ;; The header carries what the CLI told us about the session.
      (should (string-prefix-p "test  ·  claude-haiku-4-5-20251001  ·  default  ·  idle"
                               text))
      ;; The prompt is quoted with a margin marker (plan 5.3).
      (should (string-search "\n▌ hello\n" text)))))

(ert-deftest ecc-render-test-tool-use ()
  "A tool call draws as a step, a tool and the permission that allowed it."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "tool-use-write"
                                         "hello.txt を作って" '(allow))))
      (ecc-render-test--check "tool-use-write" text)
      (should (string-search "Write ×1" text))
      (should (string-search "✓ Permission: Write" text)))))

(ert-deftest ecc-render-test-deny-then-allow ()
  "A denied request keeps its reason next to the retry that followed."
  (ecc-test-with-fake-session session
    (let ((text (ecc-render-test--replay session "permission-deny-retry"
                                         "hello.txt を作って"
                                         '((deny . "内容を hi にして") allow))))
      (ecc-render-test--check "permission-deny-retry" text)
      (should (string-search "✗ Permission: Write  denied: 内容を hi にして" text))
      (should (string-search "✓ Permission: Write" text)))))

;;;; Incremental drawing (NFR-9, plan section 5.2)

(ert-deftest ecc-render-test-finished-turns-are-left-alone ()
  "Once a turn is finished it is never drawn again."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-test-dispatch session "basic-turn" "hello")
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (should (= ecc-render--frozen 1))
      (let* ((section (ecc-render--turn-section "turn-1"))
             (text (buffer-substring-no-properties (oref section start)
                                                   (oref section end))))
        (should section)
        ;; A second turn arrives; the first one keeps its very object and
        ;; its text, so nothing above the live region was redrawn.
        (ecc-model-begin-turn session "again")
        (ecc-render-flush session)
        (should (eq section (ecc-render--turn-section "turn-1")))
        (should (= ecc-render--frozen 1))
        (should (equal text (buffer-substring-no-properties (oref section start)
                                                            (oref section end))))
        (should (string-search "Turn 2  again" (buffer-string)))))))

(ert-deftest ecc-render-test-folding-survives-a-redraw ()
  "Collapsing a section sticks, because node ids are stable (plan 9.6)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "hello.txt を作って")
    (dolist (line (ecc-test-fixture-lines "tool-use-write"))
      (ecc-dispatch session (ecc-protocol-parse-line line)))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (let* ((id "toolu_01Hcu5xtMTxBqGiZ6MfT3XyZ")
             (section (ecc-render-test--find-section id)))
        (should section)
        ;; Tool bodies start collapsed (FR-OUT-3).
        (should (oref section hidden))
        (magit-section-show section)
        (should-not (oref section hidden))
        (ecc-render-flush session)
        (should-not (oref (ecc-render-test--find-section id) hidden))))))

(defun ecc-render-test--find-section (value)
  "Return the section whose value is VALUE, searching the whole buffer."
  (let (found)
    (magit-map-sections
     (lambda (section)
       (when (equal (oref section value) value)
         (setq found section))))
    found))

(ert-deftest ecc-render-test-refresh-rebuilds-the-same-text ()
  "Drawing everything again gives exactly what growing it gave (FR-OUT-10)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-test-dispatch session "tool-use-write" "hello.txt を作って")
    (ecc-render-flush session)
    (let ((incremental (ecc-test-buffer-string (ecc-session-buffer session))))
      (ecc-render-refresh session)
      (should (equal incremental
                     (ecc-test-buffer-string (ecc-session-buffer session)))))))

(ert-deftest ecc-render-test-unknown-is-visible ()
  "A message the client does not understand still reaches the buffer."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-dispatch session '((type . "brand_new_thing") (detail . "hello")))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "unknown: brand_new_thing" text))
      (should (string-search "hello" text)))))

;;;; Cost of drawing (NFR-1)

(ert-deftest ecc-render-test-streaming-recording-is-fast ()
  "Replaying the streaming recording with a redraw per message stays quick."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "長いファイルを書いて")
    (let* ((lines (ecc-test-fixture-lines "partial-messages"))
           (elapsed
            (car (benchmark-run 1
                   (dolist (line lines)
                     (ecc-dispatch session (ecc-protocol-parse-line line))
                     (ecc-render-flush session))))))
      ;; The threshold is loose on purpose; it catches a redraw that grew
      ;; with the length of the conversation, not a slow machine.
      (should (< elapsed 10)))))

(provide 'ecc-render-test)

;;; ecc-render-test.el ends here
