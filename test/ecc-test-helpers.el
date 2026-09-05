;;; ecc-test-helpers.el --- Shared helpers for the ecc test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Fixture loading, snapshot comparison and buffer inspection used by the
;; ERT suites.  Fixtures are whole recordings of the CLI stream-json
;; output, one JSON object per line; see scripts/record-fixture.sh.
;;
;; Phase 0 has no session or dispatch layer yet, so `ecc-test-feed-fixture'
;; takes the handler to run on each parsed message.  Phase 1 passes the
;; dispatch entry point.

;;; Code:

(require 'ert)
(require 'ecc-core)
(require 'ecc-protocol)

(defconst ecc-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding the ecc test suite.")

(defun ecc-test-fixture-file (name)
  "Return the absolute path of fixture NAME.
NAME may be given with or without the .jsonl extension."
  (expand-file-name (if (string-suffix-p ".jsonl" name) name (concat name ".jsonl"))
                    (expand-file-name "fixtures" ecc-test-directory)))

(defun ecc-test-fixture-lines (name)
  "Return the non-empty lines of fixture NAME as a list of strings."
  (let ((file (ecc-test-fixture-file name)))
    (unless (file-exists-p file)
      (error "No such fixture: %s" file))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (seq-remove #'string-empty-p
                  (split-string (buffer-string) "\n" t "[ \t\r]+")))))

(defun ecc-test-fixture-messages (name)
  "Return the parsed messages of fixture NAME as a list of alists."
  (mapcar #'ecc-protocol-parse-line (ecc-test-fixture-lines name)))

(defun ecc-test-fixture-names ()
  "Return the names of every recorded fixture, sorted."
  (sort (mapcar #'file-name-nondirectory
                (directory-files (expand-file-name "fixtures" ecc-test-directory)
                                 t "\\.jsonl\\'"))
        #'string<))

(defun ecc-test-feed-fixture (name handler)
  "Call HANDLER with each parsed message of fixture NAME, in order.
Returns the list of HANDLER return values."
  (mapcar handler (ecc-test-fixture-messages name)))

(defun ecc-test-find-message (name predicate)
  "Return the first message of fixture NAME satisfying PREDICATE."
  (seq-find predicate (ecc-test-fixture-messages name)))

(defun ecc-test-buffer-string (&optional buffer)
  "Return the text of BUFFER, or the current buffer, without properties."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring-no-properties (point-min) (point-max))))

;;;; Snapshots (plan section 8)

(defun ecc-test-snapshot-file (name)
  "Return the absolute path of snapshot NAME."
  (expand-file-name (concat name ".txt")
                    (expand-file-name "snapshots" ecc-test-directory)))

(defun ecc-test-snapshot (name actual)
  "Compare ACTUAL against snapshot NAME and return non-nil when equal.
Setting the environment variable ECC_UPDATE_SNAPSHOTS to a non-empty
value rewrites the snapshot instead of comparing, and a missing snapshot
is always written.  A mismatch also leaves the new text in NAME.new for
inspection."
  (let ((file (ecc-test-snapshot-file name))
        (update (not (string-empty-p (or (getenv "ECC_UPDATE_SNAPSHOTS") "")))))
    (make-directory (file-name-directory file) t)
    (cond
     ((or update (not (file-exists-p file)))
      (with-temp-file file (insert actual))
      t)
     (t
      (let ((expected (with-temp-buffer
                        (let ((coding-system-for-read 'utf-8-unix))
                          (insert-file-contents file))
                        (buffer-string))))
        (or (equal expected actual)
            (progn (with-temp-file (concat file ".new") (insert actual))
                   nil)))))))

(provide 'ecc-test-helpers)

;;; ecc-test-helpers.el ends here
