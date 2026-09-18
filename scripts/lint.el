;;; lint.el --- Run package-lint over the package and gate on its errors  -*- lexical-binding: t; -*-

;;; Commentary:

;; What `make lint' runs package-lint through.  It prints everything the
;; checker finds and fails on the errors alone:
;;
;;     $(BATCH) -l scripts/lint.el -f ecc-lint-batch-and-exit ecc*.el
;;
;; with BATCH as the Makefile defines it.  The two kinds are not the same
;; kind of thing.  An error is a defect in the package -- a header nothing
;; reads, a global mode a user's init cannot turn on, a function that was
;; removed from Emacs before the version we claim -- and no release should
;; carry one.  A warning is a judgement, and several of this package's are
;; deliberate: `with-eval-after-load' between two files of this package is
;; how a module registers with the prompt region without requiring the
;; whole user interface back up the load order.  Failing on those would
;; mean either undoing that or turning the check off, and a check that is
;; off is how forty-two stale `Package-Requires' headers and five global
;; modes with no autoload cookie went unnoticed until 2026-09-18.
;;
;; `package-lint-batch-and-exit' cannot be told this: it fails on warnings
;; too unless `package-lint-batch-fail-on-warnings' is nil, and with that
;; nil it prints nothing at all for a file whose findings are only
;; warnings.  Printed and not fatal is the combination this needs.
;;
;; The package is spread over many files, so `package-lint-main-file' says
;; which one declares it; `.dir-locals.el' says the same thing to an
;; editor checking a buffer as it is written.

;;; Code:

(require 'package-lint nil t)

(defvar ecc-lint-main-file "ecc.el"
  "The file of this package that carries its headers.")

(declare-function package-lint-buffer "package-lint" (&optional buffer))

(defun ecc-lint-file (file)
  "Return the findings of package-lint for FILE, newest checker rules and all.
Each is (LINE COLUMN TYPE MESSAGE), as `package-lint-buffer' returns them."
  (with-temp-buffer
    ;; VISIT, so that the buffer is visiting the file: the checker asks
    ;; whether the file it is looking at is the main one, and answers
    ;; that by comparing file names.
    (insert-file-contents file t)
    (emacs-lisp-mode)
    (package-lint-buffer)))

(defun ecc-lint-batch-and-exit ()
  "Check every file named on the command line and exit 1 if any has an error.
Warnings are printed and are not fatal; the Commentary above says why."
  (unless noninteractive
    (error "`ecc-lint-batch-and-exit' is for batch use only"))
  (if (not (featurep 'package-lint))
      (progn
        (message "package-lint is not installed; skipping (make lint-deps)")
        (kill-emacs 0))
    (let ((package-lint-main-file ecc-lint-main-file)
          (text-quoting-style 'grave)
          (errors 0)
          (warnings 0))
      (dolist (file command-line-args-left)
        (pcase-dolist (`(,line ,column ,type ,message) (ecc-lint-file file))
          (if (eq type 'error) (setq errors (1+ errors)) (setq warnings (1+ warnings)))
          (message "%s:%d:%d: %s: %s" file line column type message)))
      (message "package-lint: %d error(s), %d warning(s)" errors warnings)
      (kill-emacs (if (> errors 0) 1 0)))))

(provide 'lint)

;;; lint.el ends here
