;;; ecc-mermaid-test.el --- Tests for ecc-mermaid  -*- lexical-binding: t; -*-

;;; Commentary:

;; A ```mermaid block drawn as code, then as the diagram once a job has
;; made it, without a redraw.  No test needs mmdc: the command is a
;; shell script that copies the image fixture where mmdc would write,
;; fails the way mmdc fails, or hangs.  A batch Emacs draws no image,
;; so the frame is said to be graphic and PNG to be drawable.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'ecc-test-helpers)
(require 'ecc-session)
(require 'ecc-mermaid)

(defconst ecc-mermaid-test--diagram "graph TD\n  A[開始] --> B{判定}\n  B --> C[OK]"
  "The source of a diagram.  The Japanese labels are input data.")

(defun ecc-mermaid-test--reply (&optional source)
  "Return a reply holding a diagram of SOURCE between two lines of prose."
  (format "Here it is:\n\n```mermaid\n%s\n```\n\nThat is all.\n"
          (or source ecc-mermaid-test--diagram)))

(defun ecc-mermaid-test--script (dir kind)
  "Write a stand-in for mmdc of KIND into DIR and return its path.
`ok' copies the image fixture to the file after -o, `fail' says what
mmdc says of a parse error, and `hang' never finishes.  Each run is a
line of DIR/runs, and a run that starts while another is going says so."
  (let ((file (expand-file-name (format "mmdc-%s" kind) dir))
        (runs (expand-file-name "runs" dir))
        (busy (expand-file-name "busy" dir)))
    (with-temp-file file
      (insert "#!/bin/sh\n"
              (format "[ -e '%s' ] && echo overlap >> '%s'\n" busy runs)
              (format "touch '%s'\n" busy)
              (format "echo \"$@\" >> '%s'\n" runs)
              "out=''\n"
              "while [ $# -gt 0 ]; do\n"
              "  [ \"$1\" = -o ] && out=\"$2\"\n"
              "  shift\n"
              "done\n"
              (pcase kind
                ('ok (format "sleep 0.1\ncp '%s' \"$out\"\nrm -f '%s'\n"
                             (ecc-test-image-file) busy))
                ('fail (format "rm -f '%s'\n%s\nexit 1\n" busy
                               (concat "echo 'Error: Parse error on line 2:' >&2\n"
                                       "echo 'Expecting NODE_STRING' >&2\n"
                                       "echo 'Parser.parseError (https://x.invalid/a.mjs:1:2)' >&2\n"
                                       "echo '    at async renderMermaid (file:///a/index.js:689:22)' >&2")))
                ('hang "exec sleep 30\n"))))
    (set-file-modes file #o755)
    file))

(defmacro ecc-mermaid-test--with (kind &rest body)
  "Run BODY with a stand-in mmdc of KIND and a cache of its own.
`dir' is bound to the directory the stand-in keeps its runs in."
  (declare (indent 1) (debug t))
  `(let* ((dir (make-temp-file "ecc-mermaid-test" t))
          (ecc-mermaid-directory (expand-file-name "cache" dir))
          (ecc-mermaid-command (ecc-mermaid-test--script dir ,kind))
          (ecc-mermaid--program nil)
          (ecc-mermaid--state (make-hash-table :test #'equal))
          (ecc-mermaid--waiting (make-hash-table :test #'equal))
          (ecc-mermaid--queue nil)
          (ecc-mermaid--process nil)
          (ecc-mermaid--kick nil)
          (ecc-image-inline t))
     (ignore dir)
     (unwind-protect
         (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                   ((symbol-function 'image-type-available-p) (lambda (&rest _) t)))
           ,@body)
       (when (process-live-p ecc-mermaid--process)
         (delete-process ecc-mermaid--process))
       (when (timerp ecc-mermaid--kick) (cancel-timer ecc-mermaid--kick))
       (delete-directory dir t))))

(defun ecc-mermaid-test--wait (predicate)
  "Let the jobs run until PREDICATE holds, for ten seconds at most."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun ecc-mermaid-test--idle ()
  "Return non-nil once no job runs or waits.
The process is asked after rather than whether it lives: it is dead a
moment before its sentinel has put the picture in, and the sentinel is
what lets go of it."
  (and (null ecc-mermaid--queue)
       (null ecc-mermaid--kick)
       (null ecc-mermaid--process)))

(defun ecc-mermaid-test--runs (dir)
  "Return the lines the stand-in left in DIR/runs."
  (let ((file (expand-file-name "runs" dir)))
    (and (file-exists-p file)
         (with-temp-buffer
           (insert-file-contents file)
           (split-string (buffer-string) "\n" t)))))

(defun ecc-mermaid-test--add-reply (session text)
  "Add a finished reply of TEXT to SESSION and draw it."
  (ecc-model-node-changed
   session
   (ecc-model-add-node session :type 'text :status 'done :data `((text . ,text))))
  (ecc-render-flush session))

(defun ecc-mermaid-test--block-start (&optional buffer)
  "Return where the first line of the diagram starts in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (search-forward "graph TD")
      (match-beginning 0))))

(defun ecc-mermaid-test--picture (&optional buffer)
  "Return the picture over the diagram in BUFFER, or nil."
  (with-current-buffer (or buffer (current-buffer))
    (let ((display (get-text-property (ecc-mermaid-test--block-start) 'display)))
      (and (eq (car-safe display) 'image) display))))

;;;; Marking

(ert-deftest ecc-mermaid-test-a-closed-block-is-marked ()
  "The body of a closed block carries its source; an open one carries nothing."
  (let* ((text (ecc-markdown-fontify (ecc-mermaid-test--reply)))
         (value (get-text-property (string-search "graph" text) 'ecc-mermaid text)))
    (should (equal (nth 1 value) (concat ecc-mermaid-test--diagram "\n")))
    (should (stringp (car value)))
    ;; The fences and the prose around it are not the diagram.
    (should-not (get-text-property 0 'ecc-mermaid text))
    (should-not (get-text-property (string-search "That" text) 'ecc-mermaid text)))
  (let ((open (ecc-markdown-fontify "```mermaid\ngraph TD\n  A --> B\n")))
    (should-not (text-property-not-all 0 (length open) 'ecc-mermaid nil open)))
  (let ((other (ecc-markdown-fontify "```elisp\n(+ 1 2)\n```\n")))
    (should-not (text-property-not-all 0 (length other) 'ecc-mermaid nil other))))

(ert-deftest ecc-mermaid-test-the-hash-follows-source-and-theme ()
  "Two equal sources share a picture; a dark frame draws another one."
  (cl-flet ((hash (source mode)
              (cl-letf (((symbol-function 'frame-parameter)
                         (lambda (_frame parameter)
                           (and (eq parameter 'background-mode) mode))))
                (let ((text (ecc-markdown-fontify (ecc-mermaid-test--reply source))))
                  (car (get-text-property (string-search "graph" text)
                                          'ecc-mermaid text))))))
    (should (equal (hash "graph TD\n A" 'light) (hash "graph TD\n A" 'light)))
    (should-not (equal (hash "graph TD\n A" 'light) (hash "graph TD\n B" 'light)))
    (should-not (equal (hash "graph TD\n A" 'light) (hash "graph TD\n A" 'dark)))))

(ert-deftest ecc-mermaid-test-an-indented-block-is-one-block ()
  "Lines split and indented apart are found again as one block."
  (with-temp-buffer
    (let* ((text (ecc-markdown-fontify (ecc-mermaid-test--reply)))
           (start (point)))
      (insert "before\n")
      (dolist (line (split-string text "\n"))
        (insert "    " line "\n"))
      (let ((blocks (ecc-mermaid--blocks start (point-max))))
        (should (= (length blocks) 1))
        (pcase-let ((`(,_ ,from ,to) (car blocks)))
          (should (equal (buffer-substring-no-properties from to)
                         "graph TD\n      A[開始] --> B{判定}\n      B --> C[OK]"))
          ;; From the indentation of a line, and from the end of the
          ;; last one, it is the same block.
          (should (equal (cdr (ecc-mermaid-block-at (+ from 13))) (list from to)))
          (should (equal (cdr (ecc-mermaid-block-at to)) (list from to)))
          (goto-char from)
          (forward-line 1)
          (should (equal (cdr (ecc-mermaid-block-at (point))) (list from to)))
          (should-not (ecc-mermaid-block-at (point-min))))))))

;;;; Drawing

(ert-deftest ecc-mermaid-test-the-picture-arrives-without-a-redraw ()
  "The block is drawn as code, and the picture is put on it later.
No character of the buffer changes when it is, and the renderer is not
asked for anything."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session session
      (let ((buffer (ecc-session-ensure-buffer session)))
        (ecc-model-begin-turn session "draw")
        (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
        (with-current-buffer buffer
          (should (string-search "A[開始] --> B{判定}" (ecc-test-buffer-string)))
          (should-not (ecc-mermaid-test--picture))
          (let ((text (ecc-test-buffer-string))
                (tick (buffer-chars-modified-tick))
                (draws 0))
            (cl-letf* ((refresh (symbol-function 'ecc-render-refresh))
                       (update (symbol-function 'ecc-render-update))
                       ((symbol-function 'ecc-render-refresh)
                        (lambda (&rest args) (cl-incf draws) (apply refresh args)))
                       ((symbol-function 'ecc-render-update)
                        (lambda (&rest args) (cl-incf draws) (apply update args))))
              (should (ecc-mermaid-test--wait #'ecc-mermaid-test--picture)))
            (should (= draws 0))
            (should (= tick (buffer-chars-modified-tick)))
            (should (equal text (ecc-test-buffer-string)))
            ;; The picture lies over the source, all of it.
            (pcase-let ((`(,_ ,from ,to) (ecc-mermaid-block-at
                                          (ecc-mermaid-test--block-start))))
              (should-not (text-property-not-all from to 'display
                                                 (ecc-mermaid-test--picture))))
            (should (equal (plist-get (cdr (ecc-mermaid-test--picture)) :scale)
                           ecc-mermaid-scale))))
        ;; The live region drawn again finds the picture on disk.
        (ecc-render-refresh session)
        (should (ecc-mermaid-test--picture buffer))
        (should (= (length (ecc-mermaid-test--runs dir)) 1))))))

(ert-deftest ecc-mermaid-test-a-frozen-turn-gets-its-picture ()
  "A turn that finished while the job ran gets the picture as well."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session session
      (let ((buffer (ecc-session-ensure-buffer session)))
        (ecc-model-begin-turn session "draw")
        (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
        (ecc-model-finish-turn session '((subtype . "success")))
        (ecc-render-flush session)
        (with-current-buffer buffer
          (should (= ecc-render--frozen 1))
          (should-not (ecc-mermaid-test--picture)))
        (should (ecc-mermaid-test--wait
                 (lambda () (ecc-mermaid-test--picture buffer))))))))

(ert-deftest ecc-mermaid-test-the-cache-is-used-at-draw-time ()
  "A picture on disk already is put on as the text goes in, and no job runs."
  (ecc-mermaid-test--with 'ok
    (let* ((text (ecc-markdown-fontify (ecc-mermaid-test--reply)))
           (hash (car (get-text-property (string-search "graph" text) 'ecc-mermaid text))))
      (make-directory ecc-mermaid-directory t)
      (copy-file (ecc-test-image-file) (ecc-mermaid--file hash))
      (ecc-test-with-fake-session session
        (let ((buffer (ecc-session-ensure-buffer session)))
          (ecc-model-begin-turn session "draw")
          (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
          (should (ecc-mermaid-test--picture buffer))
          (should (ecc-mermaid-test--idle))
          (should-not (ecc-mermaid-test--runs dir)))))))

(ert-deftest ecc-mermaid-test-an-open-block-starts-nothing ()
  "A block the model has not closed is code, and nothing is drawn for it."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session session
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "draw")
      (ecc-mermaid-test--add-reply session "Here:\n\n```mermaid\ngraph TD\n  A --> B\n")
      (should (ecc-mermaid-test--idle))
      (accept-process-output nil 0.2)
      (should-not (ecc-mermaid-test--runs dir))
      (should (zerop (hash-table-count ecc-mermaid--state))))))

(ert-deftest ecc-mermaid-test-one-source-is-one-job ()
  "Two replies with one diagram, drawn and redrawn, run mmdc once."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session session
      (let ((buffer (ecc-session-ensure-buffer session)))
        (ecc-model-begin-turn session "draw")
        (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
        (ecc-mermaid-test--add-reply session (concat "Again.\n" (ecc-mermaid-test--reply)))
        (ecc-render-refresh session)
        (should (ecc-mermaid-test--wait #'ecc-mermaid-test--idle))
        (should (= (length (ecc-mermaid-test--runs dir)) 1))
        ;; Both blocks have it.
        (with-current-buffer buffer
          (should (= (length (seq-filter
                              (lambda (block)
                                (get-text-property (nth 1 block) 'display))
                              (ecc-mermaid--blocks (point-min) (point-max))))
                     2)))))))

(ert-deftest ecc-mermaid-test-the-jobs-run-one-at-a-time ()
  "Three diagrams are three jobs, and none starts before the last one ended."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session session
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "draw")
      (dolist (n '(1 2 3))
        (ecc-mermaid-test--add-reply
         session (ecc-mermaid-test--reply (format "graph TD\n  A%d --> B" n))))
      (should (ecc-mermaid-test--wait
               (lambda () (and (ecc-mermaid-test--idle)
                               (= (length (ecc-mermaid-test--runs dir)) 3)))))
      (should-not (member "overlap" (ecc-mermaid-test--runs dir)))
      (should (= (length (directory-files ecc-mermaid-directory nil "\\.png\\'")) 3))
      ;; What was asked of mmdc: quiet, a file in and a file out, and
      ;; the arguments of the hash.
      (should (string-match-p
               "\\`-q -i .*\\.mmd -o .*-part\\.png \\(-t dark \\)?-s 2 -b transparent\\'"
               (car (ecc-mermaid-test--runs dir)))))))

(ert-deftest ecc-mermaid-test-a-hang-is-killed ()
  "A job past `ecc-mermaid-timeout' is killed, and the block says so."
  (ecc-mermaid-test--with 'hang
    (let ((ecc-mermaid-timeout 0.3))
      (ecc-test-with-fake-session session
        (let ((buffer (ecc-session-ensure-buffer session)))
          (ecc-model-begin-turn session "draw")
          (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
          (should (ecc-mermaid-test--wait
                   (lambda () (eq (car-safe (car (hash-table-values ecc-mermaid--state)))
                                  'failed))))
          (should (ecc-mermaid-test--idle))
          (with-current-buffer buffer
            (should (equal (get-text-property (ecc-mermaid-test--block-start) 'help-echo)
                           "mermaid: no diagram after 0.3 seconds")))
          (should (string-search "no diagram after"
                                 (ecc-test-log-string
                                  (get-buffer (ecc-log-buffer-name "test"))))))))))

(ert-deftest ecc-mermaid-test-a-failure-is-shown-and-not-tried-again ()
  "mmdc's error is logged and put on the block, and the source is not run again."
  (ecc-mermaid-test--with 'fail
    (ecc-test-with-fake-session session
      (let ((buffer (ecc-session-ensure-buffer session)))
        (ecc-model-begin-turn session "draw")
        (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
        (should (ecc-mermaid-test--wait
                 (lambda () (with-current-buffer buffer
                              (get-text-property (ecc-mermaid-test--block-start)
                                                 'help-echo)))))
        (with-current-buffer buffer
          (let ((start (ecc-mermaid-test--block-start)))
            ;; The error without the stack it came through.
            (should (equal (get-text-property start 'help-echo)
                           "mermaid: Error: Parse error on line 2:\nExpecting NODE_STRING"))
            (should (memq 'ecc-mermaid-error-face
                          (ensure-list (get-text-property start 'face))))
            (should-not (ecc-mermaid-test--picture))))
        (should (string-search "mermaid: Error: Parse error on line 2:"
                               (ecc-test-log-string
                                (get-buffer (ecc-log-buffer-name "test")))))
        ;; Drawn again, it is still the error, and mmdc ran once.
        (ecc-render-refresh session)
        (accept-process-output nil 0.2)
        (should (ecc-mermaid-test--idle))
        (should (= (length (ecc-mermaid-test--runs dir)) 1))
        (with-current-buffer buffer
          (should (get-text-property (ecc-mermaid-test--block-start) 'help-echo)))))))

(ert-deftest ecc-mermaid-test-a-failure-before-mmdc-starts ()
  "A source that cannot be written fails its block, and the queue goes on."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session session
      (let ((buffer (ecc-session-ensure-buffer session))
            (writes 0))
        (cl-letf* ((write (symbol-function 'write-region))
                   ((symbol-function 'write-region)
                    (lambda (&rest args)
                      (if (= (cl-incf writes) 1)
                          (signal 'file-error '("Opening output file" "Disk full"))
                        (apply write args)))))
          (ecc-model-begin-turn session "draw")
          (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
          (ecc-mermaid-test--add-reply
           session (ecc-mermaid-test--reply "graph LR\n  X --> Y"))
          (should (ecc-mermaid-test--wait
                   (lambda () (and (ecc-mermaid-test--idle)
                                   (= (length (ecc-mermaid-test--runs dir)) 1))))))
        (with-current-buffer buffer
          (let ((start (ecc-mermaid-test--block-start)))
            (should (string-prefix-p "mermaid: could not start"
                                     (get-text-property start 'help-echo)))
            (should (string-search "Disk full" (get-text-property start 'help-echo)))
            (should-not (ecc-mermaid-test--picture)))
          ;; The second diagram was drawn all the same.
          (goto-char (point-min))
          (search-forward "graph LR")
          (should (eq (car-safe (get-text-property (match-beginning 0) 'display))
                      'image)))
        (should (string-search "Disk full"
                               (ecc-test-log-string
                                (get-buffer (ecc-log-buffer-name "test")))))
        (should (null (directory-files ecc-mermaid-directory nil "\\.mmd\\'")))))))

(ert-deftest ecc-mermaid-test-off-draws-nothing ()
  "No command, a command not found, or images off: the block stays code."
  (dolist (setup (list (lambda () (setq ecc-mermaid-command nil))
                       (lambda () (setq ecc-mermaid-command "ecc-no-such-mmdc"))
                       (lambda () (setq ecc-image-inline nil))))
    (ecc-mermaid-test--with 'ok
      (funcall setup)
      (ecc-test-with-fake-session session
        (let ((buffer (ecc-session-ensure-buffer session)))
          (ecc-model-begin-turn session "draw")
          (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
          (accept-process-output nil 0.2)
          (should (ecc-mermaid-test--idle))
          (should (zerop (hash-table-count ecc-mermaid--state)))
          (should-not (ecc-mermaid-test--picture buffer))
          (with-current-buffer buffer
            (should-not (get-text-property (ecc-mermaid-test--block-start) 'help-echo))))))))

(ert-deftest ecc-mermaid-test-toggle-between-picture-and-source ()
  "`I' on a diagram shows its source, keeps showing it after a redraw,
and shows the picture again when pressed again."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session session
      (let ((buffer (ecc-session-ensure-buffer session)))
        (ecc-model-begin-turn session "draw")
        (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply))
        (should (ecc-mermaid-test--wait (lambda () (ecc-mermaid-test--picture buffer))))
        (with-current-buffer buffer
          (let ((text (ecc-test-buffer-string)))
            (goto-char (ecc-mermaid-test--block-start))
            (should (eq (key-binding (kbd "I")) #'ecc-chat-toggle-picture))
            (ecc-chat-toggle-picture)
            (should-not (ecc-mermaid-test--picture))
            (should (equal text (ecc-test-buffer-string)))
            (ecc-render-refresh session)
            (should-not (ecc-mermaid-test--picture))
            (goto-char (ecc-mermaid-test--block-start))
            (ecc-chat-toggle-picture)
            (should (ecc-mermaid-test--picture))
            (should (equal text (ecc-test-buffer-string)))))))))

(ert-deftest ecc-mermaid-test-two-sessions-both-get-it ()
  "One diagram in two sessions is one job, and both buffers get the picture."
  (ecc-mermaid-test--with 'ok
    (ecc-test-with-fake-session one
      (let ((two (ecc-model-create-session :name "other"
                                           :project-root temporary-file-directory)))
        (unwind-protect
            (let ((buffer-one (ecc-session-ensure-buffer one))
                  (buffer-two (ecc-session-ensure-buffer two)))
              (dolist (session (list one two))
                (ecc-model-begin-turn session "draw")
                (ecc-mermaid-test--add-reply session (ecc-mermaid-test--reply)))
              (should (ecc-mermaid-test--wait
                       (lambda () (and (ecc-mermaid-test--picture buffer-one)
                                       (ecc-mermaid-test--picture buffer-two)))))
              (should (= (length (ecc-mermaid-test--runs dir)) 1)))
          (ecc-test-cleanup-session two))))))

(provide 'ecc-mermaid-test)

;;; ecc-mermaid-test.el ends here
