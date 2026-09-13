;;; bench-stream.el --- What a streaming session costs the rest of Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Replays a synthetic turn -- thinking, a long markdown reply, a Write
;; whose input streams in, its result, and a second reply -- into a
;; session at the pace the CLI streams, in a GUI Emacs, and measures what
;; the rest of Emacs pays for it: how long each timer of the package
;; runs, how long the redisplay after a flush takes, how many garbage
;; collections there are, and -- the number that matters to a person
;; typing in another buffer -- how late a 10 ms heartbeat timer fires.
;; A heartbeat that fires 60 ms late is a keystroke that waited 60 ms.
;;
;; `bench-render.el' measures a redraw without redisplay; this is the
;; other half, and it needs a frame.  It runs the same stream twice, with
;; the session in a window and with it hidden, since the redisplay of a
;; window that is on screen is the one cost a hidden session does not
;; pay.  Run it from the root of the checkout:
;;
;;     $EMACS -Q --chdir . --eval '(setq bench-stream-output "/tmp/bench-stream.txt")' \
;;            -l scripts/bench-stream.el -f bench-stream-boot
;;
;; The Emacs shows a frame for a minute or so, writes its report to
;; `bench-stream-output' and exits.  A `-Q' Emacs has the default
;; `gc-cons-threshold' of 800 KB; pass a larger one in the --eval to see
;; what an init file that raises it changes.
;;
;; A -Q Emacs measures the package alone.  What a person feels is the
;; package inside their own Emacs -- its heap, its mode line, its theme
;; -- so the same run can be made there: `M-x load-file' this script in
;; a running Emacs that has ecc loaded, then `M-x bench-stream-run'.  It
;; borrows the frame for the scenarios, puts the windows back, and
;; writes the report to the same file instead of leaving.

;;; Code:

(defvar bench-stream-output "/tmp/ecc-bench-stream.txt"
  "Where the report is written.")

(defvar bench-stream-rate 40
  "Events fed per second.  The CLI streams a delta every 20 to 40 ms.")

(defvar bench-stream-scenarios '(visible hidden)
  "Which scenarios to run, in order.")

(defvar bench-stream-history 0
  "How many finished turns the session holds before the stream starts.
Zero streams into an empty session.  A session that has been running
for an hour has a long transcript, many fold overlays and a log at its
limit; 40 is about that.")

(defvar bench-stream-exit nil
  "Non-nil leaves Emacs once the scenarios are done.
`bench-stream-boot' sets it for an Emacs started for the run; a script
loaded into a running Emacs puts the windows back and stays.")

(defconst bench-stream--root
  (file-name-directory (directory-file-name (file-name-directory load-file-name)))
  "The checkout the script is in.")

(unless (featurep 'ecc)
  (setq package-user-dir (expand-file-name "~/.emacs.d/elpa"))
  (package-initialize)
  (add-to-list 'load-path bench-stream--root))
(add-to-list 'load-path (expand-file-name "test" bench-stream--root))
(require 'ecc)
(require 'ecc-session)
(require 'ecc-test-helpers)


;;;; The stream

(defun bench-stream--json (object)
  "Return OBJECT as one line of stream-json."
  (concat (json-serialize object) "\n"))

(defun bench-stream--event (event &optional parent)
  "Return the stream_event line carrying EVENT under PARENT."
  (bench-stream--json `((type . "stream_event")
                        (event . ,event)
                        (session_id . "bench")
                        (uuid . ,(format "u%d" (random 1000000)))
                        (parent_tool_use_id . ,(or parent :null)))))

(defun bench-stream--split (text size)
  "Cut TEXT into deltas of about SIZE characters."
  (let (pieces (from 0) (n (length text)))
    (while (< from n)
      (let ((to (min n (+ from size (random 5)))))
        (push (substring text from to) pieces)
        (setq from to)))
    (nreverse pieces)))

(defconst bench-stream--paragraphs
  '("Here is what I found in the renderer.  The live region is redrawn on a debounce of a tenth of a second, and each redraw deletes the region and draws it again from the model."
    "## What changes\n\n- `ecc-render--on-delta` queues the text and flushes it on a timer.\n- `ecc-render-update` redraws the live region when a block starts or stops.\n- `ecc-visual--spinner-tick` turns the spinner while the session runs."
    "```elisp\n(defun ecc-render--flush-deltas ()\n  \"Draw the streamed text that is waiting in the current buffer.\"\n  (let ((pending (nreverse ecc-render--pending-deltas)))\n    (setq ecc-render--pending-deltas nil)\n    (with-silent-modifications\n      (dolist (pair pending)\n        (ecc-render--append-delta (car pair) (cdr pair))))))\n```"
    "The cost that matters is not the redraw itself but how often the main thread is woken: every timer that fires between two keystrokes is a pause the person typing feels, and a redisplay of a wrapped buffer with many intervals is the largest of them."
    "1. Measure the heartbeat with the session on screen.\n2. Measure it again with the session hidden.\n3. Compare the two: the difference is the redisplay of the window.\n\nThat is what this script does, and nothing else.")
  "The prose of one reply; repeated to make it long.")

(defun bench-stream--text (n)
  "Return a reply of N paragraphs."
  (mapconcat (lambda (i) (nth (% i (length bench-stream--paragraphs))
                              bench-stream--paragraphs))
             (number-sequence 0 (1- n)) "\n\n"))

(defun bench-stream--text-block (index text &optional parent)
  "Return the lines that stream TEXT as block INDEX under PARENT."
  (append
   (list (bench-stream--event `((type . "content_block_start") (index . ,index)
                                (content_block . ((type . "text") (text . ""))))
                              parent))
   (mapcar (lambda (piece)
             (bench-stream--event `((type . "content_block_delta") (index . ,index)
                                    (delta . ((type . "text_delta") (text . ,piece))))
                                  parent))
           (bench-stream--split text 10))
   (list (bench-stream--json `((type . "assistant")
                               (message . ((role . "assistant")
                                           (content . [((type . "text") (text . ,text))])))
                               (uuid . ,(format "a%d" index))
                               (session_id . "bench")
                               (parent_tool_use_id . ,(or parent :null))))
         (bench-stream--event `((type . "content_block_stop") (index . ,index)) parent))))

(defun bench-stream--thinking-block (index)
  "Return the lines that stream a short thought as block INDEX."
  (let ((thought "The renderer appends each delta; the live region is redrawn when a block opens or closes.  Let me write the file and then say what changed."))
    (append
     (list (bench-stream--event `((type . "content_block_start") (index . ,index)
                                  (content_block . ((type . "thinking") (thinking . "") (signature . ""))))))
     (mapcar (lambda (piece)
               (bench-stream--event `((type . "content_block_delta") (index . ,index)
                                      (delta . ((type . "thinking_delta") (thinking . ,piece))))))
             (bench-stream--split thought 12))
     (list (bench-stream--json `((type . "assistant")
                                 (message . ((role . "assistant")
                                             (content . [((type . "thinking") (thinking . ,thought) (signature . "sig"))])))
                                 (uuid . ,(format "a%d" index))
                                 (session_id . "bench")
                                 (parent_tool_use_id . :null)))
           (bench-stream--event `((type . "content_block_stop") (index . ,index)))))))

(defun bench-stream--write-block (index path content)
  "Return the lines that stream a Write of CONTENT to PATH as block INDEX."
  (let* ((id (format "toolu_bench%d" index))
         (input `((file_path . ,path) (content . ,content)))
         (json (json-serialize input)))
    (append
     (list (bench-stream--event `((type . "content_block_start") (index . ,index)
                                  (content_block . ((type . "tool_use") (id . ,id) (name . "Write") (input . ,(make-hash-table)))))))
     (mapcar (lambda (piece)
               (bench-stream--event `((type . "content_block_delta") (index . ,index)
                                      (delta . ((type . "input_json_delta") (partial_json . ,piece))))))
             (bench-stream--split json 15))
     (list (bench-stream--json `((type . "assistant")
                                 (message . ((role . "assistant")
                                             (content . [((type . "tool_use") (id . ,id) (name . "Write") (input . ,input))])))
                                 (uuid . ,(format "a%d" index))
                                 (session_id . "bench")
                                 (parent_tool_use_id . :null)))
           (bench-stream--event `((type . "content_block_stop") (index . ,index)))
           (bench-stream--event '((type . "message_delta")
                                  (delta . ((stop_reason . "tool_use")))
                                  (usage . ((output_tokens . 900)))))
           (bench-stream--event '((type . "message_stop")))
           (bench-stream--json `((type . "user")
                                 (message . ((role . "user")
                                             (content . [((type . "tool_result") (tool_use_id . ,id)
                                                          (content . "File created successfully."))])))
                                 (uuid . ,(format "r%d" index))
                                 (session_id . "bench")
                                 (parent_tool_use_id . :null)))))))

(defun bench-stream--turn ()
  "Return the lines of the synthetic turn, in order."
  (let ((code (mapconcat (lambda (k) (format "def f%d():\n    \"\"\"Return %d.\"\"\"\n    return %d\n" k k k))
                         (number-sequence 0 39) "\n")))
    (append
     (list (bench-stream--event '((type . "message_start")
                                  (message . ((id . "m1") (role . "assistant") (content . []))))))
     (bench-stream--thinking-block 0)
     (bench-stream--text-block 1 (bench-stream--text 12))
     (bench-stream--write-block 2 "/nonexistent/bench/long.py" code)
     (list (bench-stream--event '((type . "message_start")
                                  (message . ((id . "m2") (role . "assistant") (content . []))))))
     (bench-stream--text-block 0 (bench-stream--text 12))
     (list (bench-stream--event '((type . "message_delta")
                                  (delta . ((stop_reason . "end_turn")))
                                  (usage . ((output_tokens . 2400)))))
           (bench-stream--event '((type . "message_stop")))
           (bench-stream--json '((type . "result") (subtype . "success")
                                 (duration_api_ms . 20000) (total_cost_usd . 0.01)
                                 (session_id . "bench")))))))

;;;; Timing

(defvar bench-stream--busy (make-hash-table :test #'eq)
  "Name -> (calls total-ms max-ms) for what was timed this scenario.")

(defun bench-stream--add (name ms &optional before)
  "Charge MS milliseconds to NAME, and what was allocated since BEFORE.
BEFORE is what `memory-use-counts' returned when the work started; the
conses and the string characters it made since are counted, which is
where the garbage that a collection later stops for comes from."
  (let ((cell (or (gethash name bench-stream--busy)
                  (puthash name (list 0 0.0 0.0 0 0) bench-stream--busy)))
        (now (and before (memory-use-counts))))
    (cl-incf (nth 0 cell))
    (cl-incf (nth 1 cell) ms)
    (setf (nth 2 cell) (max (nth 2 cell) ms))
    (when now
      (cl-incf (nth 3 cell) (- (nth 0 now) (nth 0 before)))
      (cl-incf (nth 4 cell) (- (nth 4 now) (nth 4 before))))))

(defun bench-stream--timed (name)
  "Return an around advice that charges what it wraps to NAME."
  (lambda (fn &rest args)
    (let ((t0 (float-time))
          (before (memory-use-counts)))
      (unwind-protect (apply fn args)
        (bench-stream--add name (* 1000 (- (float-time) t0)) before)))))

(defconst bench-stream--timers
  '((ecc-proc-feed . feed)
    (ecc-render--delta-timer-fired . delta-flush)
    (ecc-render--timer-fired . live-redraw)
    (ecc-visual--spinner-tick . spinner)
    (ecc-visual--tick-overlay . pulse/blink)
    (ecc-tab--blink-tick . tab-blink)
    (ecc-dashboard--spinner-tick . dashboard))
  "The functions timed, and what they are called in the report.")

(defun bench-stream--redisplay-after (&rest _)
  "Redisplay now, as Emacs would once the timer returns, and time it."
  (let ((t0 (float-time))
        (before (memory-use-counts)))
    (redisplay)
    (bench-stream--add 'redisplay (* 1000 (- (float-time) t0)) before)))

(defvar bench-stream--instrumented nil)

(defun bench-stream--instrument ()
  "Put the timing advice on, once."
  (unless bench-stream--instrumented
    (setq bench-stream--instrumented t)
    (pcase-dolist (`(,fn . ,name) bench-stream--timers)
      (advice-add fn :around (bench-stream--timed name) `((name . ,name))))
    (advice-add 'ecc-render--delta-timer-fired :after #'bench-stream--redisplay-after)
    (advice-add 'ecc-render--timer-fired :after #'bench-stream--redisplay-after)))

;;;; The heartbeat

(defvar bench-stream--beat-timer nil)
(defvar bench-stream--started nil "When the scenario started, as a float time.")
(defvar bench-stream--fed 0 "How many lines have been fed so far.")
(defvar bench-stream--beat-last nil)
(defvar bench-stream--beat-gaps nil "Milliseconds between beats, most recent first.")
(defvar bench-stream--stalls nil
  "The gaps over 30 ms as (SECONDS-INTO-SCENARIO LINE-FED MS), most recent first.")

(defun bench-stream--beat ()
  "Note how long it has been since the last beat."
  (let ((now (float-time)))
    (when bench-stream--beat-last
      (let ((gap (* 1000 (- now bench-stream--beat-last))))
        (push gap bench-stream--beat-gaps)
        (when (> gap 30)
          (push (list (- now bench-stream--started) bench-stream--fed gap)
                bench-stream--stalls))))
    (setq bench-stream--beat-last now)))

(defun bench-stream--percentile (values p)
  "Return the P-th percentile of VALUES."
  (let* ((sorted (sort (copy-sequence values) #'<))
         (k (min (1- (length sorted)) (floor (* p (length sorted))))))
    (nth k sorted)))

;;;; A scenario

(defvar bench-stream--session nil)
(defvar bench-stream--lines nil)
(defvar bench-stream--feed-timer nil)
(defvar bench-stream--count 0 "How many lines the scenario feeds.")
(defvar bench-stream--gcs nil)
(defvar bench-stream--gc-ms nil)
(defvar bench-stream--queue nil "The scenarios still to run.")
(defvar bench-stream--windows nil "The window configuration to put back.")

(defun bench-stream--feed ()
  "Feed the next line, or wind the scenario up."
  (if bench-stream--lines
      (progn
        (cl-incf bench-stream--fed)
        (ecc-proc-feed bench-stream--session (pop bench-stream--lines)))
    (cancel-timer bench-stream--feed-timer)
    ;; Let the trailing timers fire before the numbers are read.
    (run-at-time 1 nil #'bench-stream--finish)))

(defun bench-stream--report (scenario)
  "Return the report of SCENARIO as text."
  (let* ((wall (* 1000 (- (float-time) bench-stream--started)))
         (busy 0.0)
         (rows nil))
    (maphash (lambda (name cell)
               (cl-incf busy (nth 1 cell))
               (push (format "    %-14s %5d calls %7.0f ms  %5.2f ms/call  max %5.1f   %6dk conses %6dk string chars\n"
                             name (nth 0 cell) (nth 1 cell)
                             (/ (nth 1 cell) (max 1 (nth 0 cell))) (nth 2 cell)
                             (/ (nth 3 cell) 1000) (/ (nth 4 cell) 1000))
                     rows))
             bench-stream--busy)
    (let* ((gaps (or bench-stream--beat-gaps '(0)))
           (over (lambda (ms) (seq-count (lambda (g) (> g ms)) gaps))))
      (concat
       (format "scenario %s: %d lines at %d/s, %.1f s, history %d turns, transcript %d KB, gc-cons-threshold %d\n"
               scenario bench-stream--count bench-stream-rate (/ wall 1000) bench-stream-history
               (/ (buffer-size (ecc-session-buffer bench-stream--session)) 1024)
               gc-cons-threshold)
       (format "  busy %.0f ms = %.1f%% of the wall clock\n" busy (/ (* 100 busy) wall))
       (apply #'concat (sort rows #'string<))
       (format "  GC: %d collections, %.0f ms\n"
               (- gcs-done bench-stream--gcs) (* 1000 (- gc-elapsed bench-stream--gc-ms)))
       (format "  heartbeat (10 ms timer, %d beats): p50 %.0f ms, p95 %.0f ms, p99 %.0f ms, max %.0f ms; %d gaps over 30 ms, %d over 100 ms\n"
               (length gaps)
               (bench-stream--percentile gaps 0.5) (bench-stream--percentile gaps 0.95)
               (bench-stream--percentile gaps 0.99) (apply #'max gaps)
               (funcall over 30) (funcall over 100))
       (mapconcat (lambda (stall)
                    (format "    at %5.1f s, line %3d: %4.0f ms\n"
                            (nth 0 stall) (nth 1 stall) (nth 2 stall)))
                  (seq-take (reverse bench-stream--stalls) 25) "")))))

(defun bench-stream--finish ()
  "Write the report of the scenario that just ran and go on."
  (cancel-timer bench-stream--beat-timer)
  (let ((report (bench-stream--report (car bench-stream--queue))))
    (with-temp-buffer
      (insert report "\n")
      (append-to-file (point-min) (point-max) bench-stream-output))
    (message "%s" report))
  (ecc-test-cleanup-session bench-stream--session)
  (pop bench-stream--queue)
  (bench-stream--next))

(defun bench-stream--history (session turns)
  "Give SESSION TURNS finished turns and a log at its limit."
  (dotimes (i turns)
    (ecc-model-begin-turn session (format "step %d of the history" i))
    (dotimes (k 8)
      (ecc-model-node-changed
       session
       (ecc-model-add-node
        session :type 'tool :status 'done
        :data `((name . "Read")
                (input . ((file_path . ,(format "~/src/file-%d-%d.el" i k))))
                (result . ,(mapconcat (lambda (n) (format "line %d of result %d/%d" n i k))
                                      (number-sequence 1 12) "\n"))))))
    (ecc-model-node-changed
     session (ecc-model-add-node session :type 'text :status 'done
                                 :data `((text . ,(bench-stream--text 3)))))
    (ecc-model-finish-turn session (list (cons (quote subtype) "success") (cons (quote total_cost_usd) 0.01))))
  (ecc-render-flush session)
  (let ((line (make-string 300 ?x)))
    (dotimes (_ (or ecc-log-max-lines 0))
      (ecc-log-raw (ecc-session-name session) 'recv line))))

(defun bench-stream--start (scenario)
  "Start SCENARIO: a fresh session, shown or hidden, fed on a timer."
  (setq ecc--sessions (make-hash-table :test #'equal)
        ecc--session-order nil)
  (setq bench-stream--session
        (ecc-model-create-session :name (format "bench-%s" scenario)
                                  :project-root temporary-file-directory))
  (ecc-session-ensure-buffer bench-stream--session)
  (when (> bench-stream-history 0)
    (bench-stream--history bench-stream--session bench-stream-history))
  (delete-other-windows)
  (switch-to-buffer "*scratch*")
  (pcase scenario
    ('visible
     ;; The session on the right, the person typing on the left.
     (let ((right (split-window-right)))
       (set-window-buffer right (ecc-session-buffer bench-stream--session))))
    ('hidden nil))
  (redisplay t)
  (clrhash bench-stream--busy)
  (setq bench-stream--beat-gaps nil
        bench-stream--stalls nil
        bench-stream--fed 0
        bench-stream--beat-last nil
        bench-stream--lines (progn (random "bench") (bench-stream--turn))
        bench-stream--count (length bench-stream--lines))
  (garbage-collect)
  (ecc-model-begin-turn bench-stream--session "make the file")
  (setq bench-stream--started (float-time)
        bench-stream--gcs gcs-done
        bench-stream--gc-ms gc-elapsed
        bench-stream--beat-timer (run-at-time 0.01 0.01 #'bench-stream--beat)
        bench-stream--feed-timer (run-at-time 0 (/ 1.0 bench-stream-rate) #'bench-stream--feed)))

(defun bench-stream--next ()
  "Run the next scenario, or wind up."
  (cond (bench-stream--queue
         (bench-stream--start (car bench-stream--queue)))
        (bench-stream-exit (kill-emacs 0))
        (t (set-window-configuration bench-stream--windows)
           (message "bench-stream: done; the report is in %s" bench-stream-output))))

(defun bench-stream-run ()
  "Run every scenario of `bench-stream-scenarios' in turn."
  (interactive)
  (condition-case err
      (progn
        (advice-add 'ecc-proc-send-json :override (lambda (&rest _) nil))
        (advice-add 'ecc-diff-file-content :override (lambda (&rest _) nil))
        (bench-stream--instrument)
        (with-temp-buffer
          (insert (format "%s\n%s\ngc-cons-threshold %d, %s\n\n"
                          (emacs-version) (format-time-string "%F %T")
                          gc-cons-threshold
                          (if bench-stream-exit "emacs -Q" "a running Emacs")))
          (append-to-file (point-min) (point-max) bench-stream-output))
        (setq bench-stream--queue (copy-sequence bench-stream-scenarios)
              bench-stream--windows (current-window-configuration))
        (when bench-stream-exit
          (set-frame-size (selected-frame) 160 45))
        ;; The resize and the first drawing of a frame on macOS take a
        ;; moment of their own; they are not what is being measured.
        (redisplay t)
        (run-at-time 2 nil #'bench-stream--next))
    (error
     (with-temp-buffer
       (insert (format "error: %S\n" err))
       (append-to-file (point-min) (point-max) bench-stream-output))
     (when bench-stream-exit (kill-emacs 1)))))

(defun bench-stream-boot ()
  "Run the scenarios once this Emacs is up, and leave when they are done.
For the command line: on macOS the frame exists only once startup is
over, so the run waits for that.  In a running Emacs the person says
when, with `bench-stream-run'."
  (setq bench-stream-exit t
        inhibit-startup-screen t
        inhibit-startup-echo-area-message (user-login-name))
  (add-hook 'emacs-startup-hook #'bench-stream-run))

;;; bench-stream.el ends here
