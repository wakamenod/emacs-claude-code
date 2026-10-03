;;; bench-review-ediff.el --- How long an ediff review takes to open  -*- lexical-binding: t; -*-

;;; Commentary:

;; Opens an ediff review of two commits of this repository in batch and
;; times its steps one by one: reading both sides from git, fontifying
;; every file, writing the two buffers, and ediff's own diff and
;; regions; then the whole of `ecc-review-ediff-range-buffer', which
;; is what the user waits for.  The numbers of Phase 5 of the review
;; work were measured with it on 2026-10-01; run it again before and
;; after a change to `ecc-review-ediff.el':
;;
;;     $(BATCH) -l test/ecc-test-helpers.el -l scripts/bench-review-ediff.el
;;
;; with BATCH as the Makefile defines it, from the top of the checkout.
;; The range is two fixed commits, so two runs on one machine compare;
;; ECC_BENCH_RANGE in the environment names another.  What drawing costs
;; on screen comes on top and is not measured here.

;;; Code:

(require 'ecc)
(require 'ecc-review-ediff)
(require 'ecc-test-helpers)

(defvar ecc-bench-review-range
  (or (getenv "ECC_BENCH_RANGE") "37ff885..06a899f")
  "The range the review compares: 57 files, 24,752 lines against 36,010.")

(defmacro ecc-bench-review--time (label &rest body)
  "Run BODY, print how long it took under LABEL, and return its value."
  (declare (indent 1))
  (let ((start (make-symbol "start")))
    `(let ((,start (float-time)))
       (prog1 (progn ,@body)
         (message "%-46s %6.3f s" ,label (- (float-time) ,start))))))

(defun ecc-bench-review--lines (pairs index)
  "Return how many lines the side INDEX of PAIRS holds in all."
  (apply #'+ (mapcar (lambda (pair)
                       (with-temp-buffer
                         (insert (nth index pair))
                         (count-lines (point-min) (point-max))))
                     pairs)))

(defun ecc-bench-review-run ()
  "Time the steps of opening an ediff review of `ecc-bench-review-range'."
  (let* ((root (ecc-review-git-root default-directory))
         (trees (ecc-review-ediff--trees root ecc-bench-review-range))
         (cache (make-hash-table :test #'equal))
         (ediff-window-setup-function #'ediff-setup-windows-plain)
         pairs)
    (message "%s in %s" ecc-bench-review-range (abbreviate-file-name root))
    ;; Once untimed, so that git and the file system are warm for both
    ;; runs alike.
    (ecc-review-ediff-pairs root (car trees) (cdr trees))
    (setq pairs (ecc-bench-review--time "read both sides (ecc-review-ediff-pairs)"
                  (ecc-review-ediff-pairs root (car trees) (cdr trees) nil cache)))
    (message "%d files, %d lines on the left, %d on the right" (length pairs)
             (ecc-bench-review--lines pairs 1) (ecc-bench-review--lines pairs 2))
    (ecc-bench-review--time "fontify every file"
      (pcase-dolist (`(,path ,before ,after ,_ ,before-blob ,after-blob) pairs)
        (ecc-review-ediff--coloured before path before-blob cache)
        (ecc-review-ediff--coloured after path after-blob cache)))
    (let ((base (generate-new-buffer "*bench-base*"))
          (now (generate-new-buffer "*bench-now*"))
          (plain (make-hash-table :test #'equal)))
      ;; Once with the colours read already, which is what writing
      ;; costs by itself, and once with the texts alone, which is what
      ;; a review that has never been coloured costs to write.
      (maphash (lambda (key value) (when (eq (car key) 'raw) (puthash key value plain)))
               cache)
      (ecc-bench-review--time "write the two buffers, colours known"
        (ecc-review-ediff--write base now pairs "Nothing" cache))
      (ecc-bench-review--time "write the two buffers (ecc-review-ediff--write)"
        (ecc-review-ediff--write base now pairs "Nothing" plain))
      (ecc-bench-review--time "ediff's diff and regions (ediff-buffers)"
        (ediff-buffers base now))
      (when (and (boundp 'ediff-control-buffer) (buffer-live-p ediff-control-buffer))
        (with-current-buffer ediff-control-buffer
          (ediff-really-quit nil)))
      (dolist (buffer (list base now))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) root)
      (let ((control (ecc-bench-review--time "open the review, all of it"
                       (ecc-review-ediff-range-buffer
                        session ecc-bench-review-range root))))
        (ecc-review-ediff-quit control)))))

(ecc-bench-review-run)

;;; bench-review-ediff.el ends here
