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
  "The log buffer is cut back to `ecc-log-max-lines' once it grows past them.
The cut waits until the buffer is a fifth over, so what is kept is the
newest lines, never fewer than the limit and never much more."
  (let* ((name (format "test-%s" (ecc--uuid)))
         (buffer (ecc--log-buffer name))
         (ecc-log-max-lines 10))
    (unwind-protect
        (let (counts)
          (dotimes (i 50)
            (ecc-log name "line %d" i)
            (push (length (split-string (ecc-test-log-string buffer) "\n" t)) counts))
          (should (<= 10 (apply #'max counts) 12))
          ;; 50 lines went in; the cut at 13 lines leaves 10, so the
          ;; buffer holds the newest 10 to 12 lines, in order.
          (let* ((text (ecc-test-log-string buffer))
                 (lines (split-string text "\n" t)))
            (should (<= 10 (length lines) 12))
            (should (string-prefix-p "-- line 3" (car lines)))
            (should (equal (car (last lines)) "-- line 49"))
            (should (equal lines (seq-sort-by (lambda (l) (string-to-number (substring l 8)))
                                              #'< lines)))))
      (kill-buffer buffer))))

(ert-deftest ecc-core-test-log-trim-is-not-paid-per-line ()
  "Past the limit, most lines go in without a cut.
Trimming on every line walked back over every kept line and moved the
whole buffer down by one, which was most of what a delta cost."
  (let* ((name (format "test-%s" (ecc--uuid)))
         (buffer (ecc--log-buffer name))
         (ecc-log-max-lines 100)
         (cuts 0))
    (unwind-protect
        (cl-letf* ((delete-region (symbol-function #'delete-region))
                   ((symbol-function #'delete-region)
                    (lambda (start end) (cl-incf cuts) (funcall delete-region start end))))
          (dotimes (i 1000) (ecc-log name "line %d" i))
          ;; 1000 lines over a limit of 100 with a slack of 20 is 45 cuts.
          (should (< cuts 60))
          (should (<= 100 (length (split-string (ecc-test-log-string buffer) "\n" t)) 120)))
      (kill-buffer buffer))))

(ert-deftest ecc-core-test-flatten-is-what-replacing-the-blanks-was ()
  "Every run of blanks is one space, the ends of the string included."
  (dolist (string '("a \n\t b" " a" "a\n" "  " "" "a\r\nb  c"))
    (should (equal (ecc--flatten string)
                   (replace-regexp-in-string "[ \t\n\r]+" " " string))))
  (should (equal (ecc--flatten nil) ""))
  (should (equal (ecc--fit "one\ntwo" 20) "one two")))

(ert-deftest ecc-core-test-truncate-leaves-no-marker-behind ()
  "Shortening a string saves no match data, so no marker is made of a search.
Saving the match data after a search in a buffer makes a marker per
group in that buffer, and a list drawn five times a second was leaving
seven of them at every redraw."
  (let ((calls 0))
    (advice-add 'match-data :before (lambda (&rest _) (cl-incf calls))
                '((name . ecc-core-test-count)))
    ;; Advising a primitive compiles a trampoline for it, and the
    ;; compiler saves match data of its own: only what comes after counts.
    (setq calls 0)
    (unwind-protect
        (progn
          (with-temp-buffer (insert "abc") (goto-char (point-min))
                            (re-search-forward "b"))
          (ecc--truncate "one\ntwo three" 8)
          (ecc--fit "one\ntwo three" 8))
      (advice-remove 'match-data 'ecc-core-test-count))
    (should (zerop calls))))

(ert-deftest ecc-core-test-truncate ()
  "Truncation flattens whitespace and marks a cut."
  (should (equal (ecc--truncate "one\ntwo" 20) "one two"))
  (should (equal (ecc--truncate "abcdef" 4) "abc…"))
  (should (equal (ecc--truncate nil 4) ""))
  (should (equal (ecc--truncate "abcd" 4) "abcd")))

(ert-deftest ecc-core-test-truncate-left ()
  "A path keeps its end, where the name of the file is."
  (should (equal (ecc--truncate-left "/a/very/long/path/to/file.py" 12)
                 "…/to/file.py"))
  (should (equal (ecc--truncate-left "abcdef" 4) "…def"))
  (should (equal (ecc--truncate-left "abcd" 4) "abcd"))
  (should (equal (ecc--truncate-left nil 4) ""))
  (should (equal (ecc--truncate-left "one\ntwo" 20) "one two")))

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

(ert-deftest ecc-core-test-aside-splits-what-emacs-added ()
  "A prompt is parted into what the user wrote and what Emacs added."
  (let* ((added (ecc-aside "\n(a line from Emacs)"))
         (sent (concat "worktree を切って" added))
         (split (ecc-aside-split sent)))
    (should (equal (car split) "worktree を切って"))
    (should (equal (cdr split) "(a line from Emacs)"))
    ;; The mark is a property, so what goes to the CLI is the two
    ;; together and nothing else.
    (should (equal (substring-no-properties sent)
                   "worktree を切って\n(a line from Emacs)")))
  ;; A prompt nobody added to comes back whole, and so does text from a
  ;; recording, which carries no properties at all.
  (should (equal (ecc-aside-split "hello") (cons "hello" nil)))
  (should (equal (ecc-aside-split "") (cons "" nil)))
  (should (equal (ecc-aside-split nil) (cons nil nil))))

(ert-deftest ecc-core-test-config-directory-default ()
  "With nothing in the environment the CLI\='s state is under ~/.claude."
  (let ((process-environment (list "PATH=/usr/bin"))
        (ecc-extra-environment nil))
    (should (equal (ecc-config-directory)
                   (file-name-as-directory (expand-file-name "~/.claude"))))
    ;; The .claude.json sits beside that directory, not inside it.
    (should (equal (ecc-config-json-file) (expand-file-name "~/.claude.json")))))

(ert-deftest ecc-core-test-config-directory-follows-the-environment ()
  "CLAUDE_CONFIG_DIR moves the directory, and the .claude.json into it.
The CLI reads the directory this Emacs names, because this Emacs is
what starts it; reading ~/.claude anyway would report on a machine the
session never touches."
  (let ((process-environment (list "CLAUDE_CONFIG_DIR=/tmp/elsewhere"))
        (ecc-extra-environment nil))
    (should (equal (ecc-config-directory) "/tmp/elsewhere/"))
    (should (equal (ecc-config-json-file) "/tmp/elsewhere/.claude.json"))))

(ert-deftest ecc-core-test-config-directory-reads-extra-environment-first ()
  "`ecc-extra-environment\=' wins, because the CLI is started with it in front."
  (let ((process-environment (list "CLAUDE_CONFIG_DIR=/tmp/inherited"))
        (ecc-extra-environment '("CLAUDE_CODE_ARTIFACT=1"
                                 "CLAUDE_CONFIG_DIR=/tmp/ours")))
    (should (equal (ecc-config-directory) "/tmp/ours/")))
  ;; An entry for another variable is not mistaken for this one.
  (let ((process-environment (list "PATH=/usr/bin"))
        (ecc-extra-environment '("NOT_CLAUDE_CONFIG_DIR=/tmp/no")))
    (should (equal (ecc-config-directory)
                   (file-name-as-directory (expand-file-name "~/.claude"))))))

(provide 'ecc-core-test)

;;; ecc-core-test.el ends here
