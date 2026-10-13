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

(defun ecc-bench--edit-turn (session n)
  "Open a turn of SESSION with N finished Edit calls on a file of 300 lines.
Each call knows what the file looked like before it, which is the case
that costs: the diff is made from it and drawn under the heading."
  (let ((before (ecc-bench--lines 1 300 "x")))
    (ecc-model-begin-turn session (format "edit %d times" n))
    (dotimes (i n)
      (let ((old (format "  (setq x-%d (compute %d))" (1+ (% i 300)) (1+ (% i 300)))))
        (ecc-model-node-changed
         session
         (ecc-model-add-node
          session :type 'tool :status 'done
          :data `((name . "Edit")
                  (before . ,before)
                  (input . ((file_path . "~/src/edited.el")
                            (old_string . ,old)
                            (new_string . ,(concat old " ; edited"))))
                  (result . "The file has been updated."))))))))

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
               n (ecc-bench--ms (lambda () (ecc-render-flush session))))))
  ;; Edits last, for the same reason and with the same rule: a case put
  ;; in the middle would move every number under it.  This is the one
  ;; the diffs are measured on, since an Edit draws its diff where a
  ;; Read draws a path (2026-09-22).
  (dolist (n '(200 800))
    (ecc-test-with-fake-session session
      (ecc-session-ensure-buffer session)
      (ecc-bench--edit-turn session n)
      (ecc-render-flush session)
      (message "live turn of %4d edits: %6.1f ms per redraw"
               n (ecc-bench--ms (lambda () (ecc-render-flush session)))))))

;; After everything else, by the same rule.  Forty replies with a
;; diagram each, drawn whole by `ecc-render-refresh' and as the live
;; region by `ecc-render-flush': the draw path of a ```mermaid block
;; (2026-10-12).  Without `ecc-mermaid' loaded, or with no command, it
;; is a code block like any other; `miss' is a diagram not made yet,
;; and `hit' one waiting on disk.  No process is started -- the job
;; queue starts on a timer, and nothing here lets a timer run.

(defun ecc-bench--mermaid-turn (session n)
  "Open a turn of SESSION with N replies, each holding a diagram of its own."
  (ecc-model-begin-turn session "draw them")
  (dotimes (i n)
    (ecc-model-node-changed
     session
     (ecc-model-add-node
      session :type 'text :status 'done
      :data `((text . ,(format "Step %d goes like this:\n\n```mermaid\ngraph TD\n  A%d[開始] --> B%d{判定}\n  B%d -->|yes| C%d[OK]\n  B%d -->|no| D%d[NG]\n```\n\nThat is all.\n"
                               i i i i i i i)))))))

(defun ecc-bench--mermaid (label)
  "Print the cost of drawing replies with diagrams, under LABEL."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-bench--mermaid-turn session 40)
    (ecc-render-refresh session)
    (message "40 diagrams, %-5s: %6.1f ms per refresh, %5.2f ms per redraw"
             label
             (ecc-bench--ms (lambda () (ecc-render-refresh session)))
             (ecc-bench--ms (lambda () (ecc-render-flush session))))))

(defun ecc-bench-mermaid ()
  "Print the cost of the diagrams: none, not made yet, and made.
The frame is said to draw images in every case, the one without
`ecc-mermaid' included, so that the cases differ by the diagrams alone."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'image-type-available-p) (lambda (&rest _) t)))
    (if (not (featurep 'ecc-mermaid))
        (ecc-bench--mermaid "plain")
      (let ((ecc-mermaid-directory (make-temp-file "ecc-bench-mermaid" t))
            (ecc-mermaid--state (make-hash-table :test #'equal))
            (ecc-mermaid--waiting (make-hash-table :test #'equal))
            (ecc-mermaid--queue nil))
        (unwind-protect
            (cl-letf (((symbol-function 'ecc-mermaid-program)
                       (lambda () (and ecc-mermaid-command "mmdc"))))
              (let ((ecc-mermaid-command nil))
                (ecc-bench--mermaid "plain"))
              (ecc-bench--mermaid "miss")
              ;; Every diagram asked for is put on disk, as a job would.
              (dolist (hash (hash-table-keys ecc-mermaid--state))
                (copy-file (ecc-test-image-file) (ecc-mermaid--file hash) t))
              (clrhash ecc-mermaid--state)
              (setq ecc-mermaid--queue nil)
              (ecc-bench--mermaid "hit"))
          (when (timerp ecc-mermaid--kick) (cancel-timer ecc-mermaid--kick))
          (setq ecc-mermaid--kick nil)
          (delete-directory ecc-mermaid-directory t))))))

(ecc-bench-render)
(ecc-bench-mermaid)

;;; bench-render.el ends here
