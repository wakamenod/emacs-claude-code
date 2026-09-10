;;; ecc-core-test.el --- Tests for ecc-core  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the JSON wrappers, the UUID generator and the session
;; log buffer.

;;; Code:

(require 'ert)
(require 'ecc-core)
(require 'ecc-test-helpers)

(ert-deftest ecc-core-test-uuid-shape ()
  "UUIDs look like RFC 4122 version 4 and do not repeat."
  (let ((ids (mapcar (lambda (_) (ecc--uuid)) (number-sequence 1 200))))
    (dolist (id ids)
      (should (= (length id) 36))
      (should (string-match-p
               "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'"
               id)))
    (should (= (length ids) (length (delete-dups (copy-sequence ids)))))))

(ert-deftest ecc-core-test-json-round-trip ()
  "Reading and writing a JSON object is lossless apart from null."
  (let ((json (concat "{\"s\":\"x\",\"n\":1,\"arr\":[1,{\"k\":[]}],"
                      "\"t\":true,\"f\":false,\"obj\":{}}")))
    (should (equal json (ecc--json-write (ecc--json-read json))))))

(ert-deftest ecc-core-test-json-null-needs-the-verbatim-reader ()
  "The plain reader folds null into an empty object; the other one does not."
  (let ((json "{\"a\":null,\"b\":{}}"))
    (should (equal (ecc--json-write (ecc--json-read json)) "{\"a\":{},\"b\":{}}"))
    (should (equal (ecc--json-write (ecc--json-read-verbatim json)) json))))

(ert-deftest ecc-core-test-json-write-empty-object ()
  "Nil serializes to an empty object, as the initialize hooks field needs."
  (should (equal (ecc--json-write nil) "{}"))
  (should (equal (ecc--json-write '((a . :null))) "{\"a\":null}"))
  (should (equal (ecc--json-write '((a . :false))) "{\"a\":false}"))
  (should (equal (ecc--json-write '((a . t))) "{\"a\":true}"))
  (should (equal (ecc--json-write '((a . [1 2]))) "{\"a\":[1,2]}")))

(ert-deftest ecc-core-test-json-read-large-line ()
  "A multi-megabyte line parses, as a long Write content produces one."
  (let* ((content (make-string (* 5 1024 1024) ?x))
         (line (ecc--json-write `((type . "assistant") (content . ,content))))
         (parsed (ecc--json-read line)))
    (should (= (length (alist-get 'content parsed)) (* 5 1024 1024)))))

(ert-deftest ecc-core-test-log-buffer ()
  "Raw and diagnostic lines land in the session log buffer, newest last."
  (let* ((name (format "test-%s" (ecc--uuid)))
         (buffer (ecc--log-buffer name)))
    (unwind-protect
        (progn
          (ecc-log-raw name 'recv "{\"type\":\"system\"}")
          (ecc-log-raw name 'send "{\"type\":\"user\"}")
          (ecc-log name "started with %s" "haiku")
          (should (equal (ecc-test-log-string buffer)
                         (concat "<< {\"type\":\"system\"}\n"
                                 ">> {\"type\":\"user\"}\n"
                                 "-- started with haiku\n"))))
      (kill-buffer buffer))))

(ert-deftest ecc-core-test-log-trims ()
  "The log buffer is trimmed to `ecc-log-max-lines' from the end."
  (let* ((name (format "test-%s" (ecc--uuid)))
         (buffer (ecc--log-buffer name))
         (ecc-log-max-lines 10))
    (unwind-protect
        (progn
          (dotimes (i 50) (ecc-log name "line %d" i))
          (let ((text (ecc-test-log-string buffer)))
            (should (= (length (split-string text "\n" t)) 10))
            (should (string-prefix-p "-- line 40" text))
            (should (string-suffix-p "-- line 49\n" text))))
      (kill-buffer buffer))))

(ert-deftest ecc-core-test-truncate ()
  "Truncation flattens whitespace and marks a cut."
  (should (equal (ecc--truncate "one\ntwo" 20) "one two"))
  (should (equal (ecc--truncate "abcdef" 4) "abc…"))
  (should (equal (ecc--truncate nil 4) ""))
  (should (equal (ecc--truncate "abcd" 4) "abcd")))

(ert-deftest ecc-core-test-mode-line-escape ()
  "A percent sign written for a person survives a mode line."
  ;; What a mode line makes of these is checked by hand rather than
  ;; here: `format-mode-line' draws nothing in batch.  With a real
  ;; frame, "context 83% left" arrives as "context 83left" and "printf
  ;; %s" as "printf no process", which is what this doubling is for
  ;; (measured on 2026-09-06).
  (should (equal (ecc--mode-line-escape "context 83% left")
                 "context 83%% left"))
  (should (equal (ecc--mode-line-escape "Bash printf %s") "Bash printf %%s"))
  (should (equal (ecc--mode-line-escape "100%%") "100%%%%"))
  ;; Nothing to do, and nothing done.
  (should (equal (ecc--mode-line-escape "plain") "plain"))
  (should-not (ecc--mode-line-escape nil))
  ;; The added character looks like the one it doubles, so a face is not
  ;; cut in half.
  (let* ((text (concat "left " (propertize "83%" 'face 'ecc-error-face)))
         (escaped (ecc--mode-line-escape text)))
    (should (equal (substring-no-properties escaped) "left 83%%"))
    (should (eq (get-text-property 7 'face escaped) 'ecc-error-face))
    (should (eq (get-text-property 8 'face escaped) 'ecc-error-face))))

(provide 'ecc-core-test)

;;; ecc-core-test.el ends here
