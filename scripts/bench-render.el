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

(defun ecc-bench--turn (session n &optional images)
  "Open a turn of SESSION with N finished Read calls and a text every fifth.
With IMAGES every fifth Read answers with an image block beside its
text and names a .png, which is the shape a screenshot arrives in."
  (ecc-model-begin-turn session (format "prompt of %d" n))
  (dotimes (i n)
    (let* ((picture (and images (zerop (% i 5))))
           (text (mapconcat (lambda (k) (format "line %d of result %d" k i))
                            (number-sequence 1 12) "\n")))
      (ecc-model-node-changed
       session
       (ecc-model-add-node
        session :type 'tool :status 'done
        :data `((name . "Read")
                (input . ((file_path . ,(format (if picture "~/src/shot-%d.png"
                                                  "~/src/file-%d.el")
                                                i))))
                (result . ,(if picture
                               (vector `((type . "text") (text . ,text))
                                       `((type . "image")
                                         (path . ,(format "/nonexistent/%d.png" i))
                                         (bytes . 4096)))
                             text))))))
    (when (zerop (% i 5))
      (ecc-model-node-changed
       session
       (ecc-model-add-node
        session :type 'text :status 'done
        :data `((text . ,(format "## Heading %d\n\nSome **bold** and `code`.\n\n```elisp\n(defun f%d (x)\n  (+ x 1))\n```\n\n- one\n- two\n" i i))))))))

(defun ecc-bench--ms (thunk &optional times)
  "Return the milliseconds one call of THUNK takes, averaged over TIMES."
  (let* ((times (or times 5))
         ;; What ran before leaves the heap where it leaves it, and a
         ;; collection in the middle of a measurement is most of the
         ;; measurement.  Sweeping first is what makes two runs of this
         ;; file comparable when one of them has more cases than the
         ;; other (2026-09-16: adding a case moved an untouched
         ;; number from 1.7 ms to 4.3).
         (_ (garbage-collect))
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
             (ecc-bench--ms (lambda () (ecc-render-flush session)))))
  ;; Last, so that the numbers above stay comparable with the runs
  ;; recorded before there was anything to say about an image: every
  ;; session left behind shifts what the one after it measures.
  (dolist (n '(200 800))
    (ecc-test-with-fake-session session
      (ecc-session-ensure-buffer session)
      (ecc-bench--turn session n t)
      (ecc-render-flush session)
      (message "live turn of %4d tools, a fifth with images: %6.1f ms per redraw"
               n (ecc-bench--ms (lambda () (ecc-render-flush session)))))))

(ecc-bench-render)

;;; bench-render.el ends here
