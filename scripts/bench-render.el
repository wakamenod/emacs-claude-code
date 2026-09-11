;;; bench-render.el --- How long a redraw of the live region takes  -*- lexical-binding: t; -*-

;;; Commentary:

;; Times `ecc-render-update' on synthetic turns of growing length, and
;; the Files summary of a session that touched many files, without a
;; process and without redisplay.  The numbers are what the caches and
;; the block-level live region were measured against on 2026-09-12; run
;; it again before and after a change to the renderer:
;;
;;     $(BATCH) -l test/ecc-test-helpers.el -l scripts/bench-render.el
;;
;; with BATCH as the Makefile defines it.  What is drawn is the same
;; every run, so two runs on one machine compare; what a redraw costs
;; on screen comes on top and is not measured here.

;;; Code:

(require 'ecc)
(require 'ecc-session)
(require 'ecc-test-helpers)

(defun ecc-bench--lines (from n tag)
  "Return N lines of made-up code from line FROM, marked with TAG."
  (mapconcat (lambda (k) (format "  (setq %s-%d (compute %d))" tag k k))
             (number-sequence from (+ from n -1)) "\n"))

(defun ecc-bench--turn (session n)
  "Open a turn of SESSION with N finished Read calls and a text every fifth."
  (ecc-model-begin-turn session (format "prompt of %d" n))
  (dotimes (i n)
    (ecc-model-node-changed
     session
     (ecc-model-add-node
      session :type 'tool :status 'done
      :data `((name . "Read")
              (input . ((file_path . ,(format "~/src/file-%d.el" i))))
              (result . ,(mapconcat (lambda (k) (format "line %d of result %d" k i))
                                    (number-sequence 1 12) "\n")))))
    (when (zerop (% i 5))
      (ecc-model-node-changed
       session
       (ecc-model-add-node
        session :type 'text :status 'done
        :data `((text . ,(format "## Heading %d\n\nSome **bold** and `code`.\n\n```elisp\n(defun f%d (x)\n  (+ x 1))\n```\n\n- one\n- two\n" i i))))))))

(defun ecc-bench--ms (thunk &optional times)
  "Return the milliseconds one call of THUNK takes, averaged over TIMES."
  (let* ((times (or times 5))
         (run (benchmark-call thunk times)))
    (/ (* 1000 (car run)) times)))

(defun ecc-bench-render ()
  "Print the cost of a redraw for turns of growing length."
  (dolist (n '(50 200 800))
    (ecc-test-with-fake-session session
      (ecc-session-ensure-buffer session)
      (ecc-bench--turn session n)
      (ecc-render-flush session)
      (message "live turn of %4d tools: %6.1f ms per redraw"
               n (ecc-bench--ms (lambda () (ecc-render-flush session))))))
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "edit sixty files")
    (dotimes (i 60)
      (let ((path (format "~/src/edited-%d.el" i)))
        (ecc-model-note-file session path 'edit)
        (dotimes (h 3)
          (ecc-model-note-hunk
           session path
           (ecc-bench--lines (* h 50) 20 "x")
           (concat (ecc-bench--lines (* h 50) 10 "x") "\n  (changed)\n"
                   (ecc-bench--lines (+ (* h 50) 11) 9 "x"))
           nil (ecc-bench--lines 1 300 "x")))))
    (ecc-model-node-changed
     session (ecc-model-add-node session :type 'text :status 'done
                                 :data '((text . "done"))))
    (ecc-render-flush session)
    (message "Files summary, 60 files x 3 hunks: %6.1f ms per redraw"
             (ecc-bench--ms (lambda () (ecc-render-flush session))))))

(ecc-bench-render)

;;; bench-render.el ends here
