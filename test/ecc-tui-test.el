;;; ecc-tui-test.el --- Tests for ecc-tui  -*- lexical-binding: t; -*-

;;; Commentary:

;; The hand-off to the terminal client: the command it is opened with,
;; the transcript following the recording while it is there, the session
;; coming back afterwards and the rule that only one process may have a
;; session at a time.  No terminal is started here;
;; `ecc-tui--open-ghostel' is replaced by one that makes a buffer and a
;; process of its own, which is all the hand-off asks of a terminal.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-tui)
(require 'ecc-session)
(require 'ecc-render)

(defvar ecc-tui-test--opened nil
  "What the fake terminal was asked to open.")

(defun ecc-tui-test--fake-terminal (session)
  "Stand in for a terminal: a buffer with a process that outlives it.
Returns (BUFFER . PROCESS) the way the real backends do."
  (setq ecc-tui-test--opened (ecc-tui-arguments session))
  (let ((buffer (get-buffer-create (ecc-tui-buffer-name session))))
    (cons buffer (start-process "ecc-tui-test" buffer "sleep" "60"))))

(defmacro ecc-tui-test--with-session (var &rest body)
  "Run BODY with VAR bound to a session whose terminal is a fake one.
The process the session would run is pretended to be alive until
`ecc-proc-stop' is called, so that the hand-off has something to stop."
  (declare (indent 1) (debug (symbolp body)))
  `(ecc-test-with-fake-session ,var
     (let ((ecc-tui-test--opened nil)
           (ecc-tui--handoffs (make-hash-table :test #'equal))
           ;; Nothing here answers an interrupt on its own, so the wait
           ;; for the turn to end is kept short.
           (ecc-tui-interrupt-timeout 0.3)
           (alive t)
           (stopped nil)
           (interrupted nil))
       (ignore stopped interrupted)
       (ignore alive)
       (cl-letf* ((real-process-live-p (symbol-function 'process-live-p))
                  ;; The session has no process of its own, so a nil
                  ;; process is the one being pretended to be alive; a
                  ;; real one (the fake terminal) answers for itself.
                  ((symbol-function 'process-live-p)
                   (lambda (object) (if (processp object)
                                        (funcall real-process-live-p object)
                                      alive)))
                  ((symbol-function 'ecc-proc-interrupt)
                   (lambda (session)
                     (setq interrupted t)
                     ;; The CLI answers an interrupt with a result, which
                     ;; is what takes the session out of `running'.
                     (ecc-model-set-state session 'idle)))
                  ((symbol-function 'ecc-proc-stop)
                   (lambda (_session) (setq stopped t alive nil)))
                  ((symbol-function 'ecc-registry-session) (lambda (_id) nil))
                  ((symbol-function 'ecc-tui--open-ghostel)
                   #'ecc-tui-test--fake-terminal))
         (unwind-protect (progn ,@body)
           (ecc-tui-follow-stop ,var)
           (when-let* ((buffer (get-buffer (ecc-tui-buffer-name ,var))))
             (when-let* ((process (get-buffer-process buffer)))
               (set-process-sentinel process #'ignore)
               (delete-process process))
             (kill-buffer buffer)))))))

;;;; The command the terminal is opened with

(ert-deftest ecc-tui-test-command ()
  "The terminal resumes the same session with the interactive CLI."
  (ecc-test-with-fake-session session
    (setf (ecc-session-options session) '(:model "haiku"))
    (should (equal (ecc-tui-arguments session)
                   (list ecc-executable "--resume" (ecc-session-id session)
                         "--model" "haiku")))
    ;; None of the headless flags belong in a terminal.
    (should-not (member "--output-format" (ecc-tui-arguments session)))
    (should-not (member "-p" (ecc-tui-arguments session)))
    (let ((ecc-tui-extra-args '("--effort" "high")))
      (should (equal (last (ecc-tui-arguments session) 2) '("--effort" "high"))))
    ;; ghostel takes argv, so nothing has to survive a shell.
    (should (member "--resume" (ecc-tui-arguments session)))))

(ert-deftest ecc-tui-test-command-leaves-the-model-alone ()
  "The hand-off does not name a model the session was not given.
A resume keeps the model its recording ends on, so naming a model here
would undo a `/model' made in Emacs on the way in, and one made in the
terminal on the way out."
  (ecc-test-with-fake-session session
    (should-not (member "--model" (ecc-tui-arguments session)))
    ;; A model put in the options of this session is somebody's doing
    ;; and is still passed.
    (setf (ecc-session-options session) '(:model "opus"))
    (should (equal (cadr (member "--model" (ecc-tui-arguments session)))
                   "opus"))))

;;;; Only one process at a time

(ert-deftest ecc-tui-test-stops-the-process-first ()
  "The session is interrupted and stopped before the terminal opens."
  (ecc-tui-test--with-session session
    (ecc-model-set-state session 'running)
    (ecc-tui-open session)
    (should interrupted)
    (should stopped)
    (should (eq (ecc-session-state session) 'idle))
    (should (member "--resume" ecc-tui-test--opened))
    (should (eq (ecc-session-kind session) 'handoff))
    (should (ecc-tui-handoff-p session))
    ;; It cannot be handed over twice.
    (should-error (ecc-tui-open session) :type 'user-error)))

(ert-deftest ecc-tui-test-a-turn-that-ignores-the-interrupt-is-waited-out ()
  "The wait for a running turn has an end, and the process goes anyway."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-proc-interrupt)
               (lambda (_session) (setq interrupted t))))
      (ecc-model-set-state session 'running)
      (let ((start (float-time)))
        (ecc-tui-open session)
        (should (>= (- (float-time) start) ecc-tui-interrupt-timeout)))
      (should interrupted)
      (should stopped)
      (should (ecc-tui-handoff-p session)))))

(ert-deftest ecc-tui-test-refuses-when-the-process-will-not-stop ()
  "A process that will not die keeps the session: two of them branch it."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-proc-stop) (lambda (_session) nil)))
      (should-error (ecc-tui-open session) :type 'user-error))
    (should-not ecc-tui-test--opened)
    (should-not (ecc-tui-handoff-p session))
    (should-not (eq (ecc-session-kind session) 'handoff))))

(ert-deftest ecc-tui-test-refuses-when-another-process-has-it ()
  "A session already running elsewhere is named rather than resumed."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-registry-session)
               (lambda (_id) '((pid . 4242) (name . "elsewhere")))))
      (should-error (ecc-tui-open session) :type 'user-error))
    (should-not ecc-tui-test--opened)))

;;;; Following the recording while the terminal has it

(defun ecc-tui-test--write (file lines)
  "Write LINES to FILE, each followed by a newline."
  (with-temp-file file
    (let ((coding-system-for-write 'utf-8-unix))
      (dolist (line lines) (insert line "\n")))))

(defun ecc-tui-test--append (file text)
  "Append TEXT to FILE as it stands."
  (with-temp-buffer
    (let ((coding-system-for-write 'utf-8-unix))
      (insert text)
      (write-region (point-min) (point-max) file t 'quiet))))

(ert-deftest ecc-tui-test-a-recording-found-later-is-not-replayed-whole ()
  "A recording that appears after the follow began is joined at its end.
A session writes its recording only once it has something to record,
so the file is often missing when the follow starts.  What it holds
when it turns up is what the transcript already shows, and reading it
from the top would say the whole conversation a second time."
  (let* ((file (make-temp-file "ecc-tui-" nil ".jsonl"))
         (lines (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents (ecc-test-history-fixture "session")))
                  (split-string (buffer-string) "\n" t))))
    (unwind-protect
        (ecc-tui-test--with-session session
          (cl-letf (((symbol-function 'ecc-history-file)
                     (lambda (_id) (and (file-exists-p file) file)))
                    ((symbol-function 'file-notify-add-watch) (lambda (&rest _) nil)))
            ;; There is no recording yet when the follow begins.
            (delete-file file)
            (ecc-tui-open session)
            ;; The CLI writes one, and it is found on the next read.
            (ecc-tui-test--write file lines)
            (should (= (ecc-tui-read-new-lines session) 0))
            (should (= (length (ecc-session-turns session)) 0))
            ;; From there on what is appended is followed as usual.
            (ecc-tui-test--write file (append lines lines))
            (should (> (ecc-tui-read-new-lines session) 0))))
      (ignore-errors (delete-file file)))))

(ert-deftest ecc-tui-test-following-does-not-open-a-turn-per-batch ()
  "Reading the recording a batch at a time makes no turns of its own.
A batch of appended lines is the middle of a turn, not a turn: opening
one for each would fill the transcript with empty turns timed from the
moment they were read to a moment in the past."
  (let* ((file (make-temp-file "ecc-tui-" nil ".jsonl"))
         (lines (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents (ecc-test-history-fixture "session")))
                  (split-string (buffer-string) "\n" t))))
    (unwind-protect
        (ecc-tui-test--with-session session
          (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) file))
                    ((symbol-function 'file-notify-add-watch) (lambda (&rest _) nil)))
            (ecc-tui-test--write file nil)
            (ecc-tui-open session)
            ;; The recording arrives a few lines at a time, the way it
            ;; does while a terminal is writing it.
            (let ((n 0))
              (while (< n (length lines))
                (setq n (min (length lines) (+ n 3)))
                (ecc-tui-test--write file (seq-take lines n))
                (ecc-tui-read-new-lines session)))
            (let ((turns (ecc-session-turns session)))
              (should (> (length turns) 0))
              ;; Every turn came from a prompt in the recording, and
              ;; none of them ran for a negative length of time.
              (dolist (turn turns)
                (should (ecc-turn-prompt turn))
                (when-let* ((duration (ecc-model-turn-duration turn)))
                  (should (>= duration 0)))))))
      (delete-file file))))

(ert-deftest ecc-tui-test-follow-reads-what-the-terminal-appends ()
  "The transcript keeps up with the recording the terminal writes."
  (let* ((file (make-temp-file "ecc-tui-" nil ".jsonl"))
         (lines (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents (ecc-test-history-fixture "session")))
                  (split-string (buffer-string) "\n" t)))
         (half (/ (length lines) 2)))
    (unwind-protect
        (ecc-tui-test--with-session session
          (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) file))
                    ;; Nothing may be watched in batch; the timer and the
                    ;; explicit read are what the test drives.
                    ((symbol-function 'file-notify-add-watch)
                     (lambda (&rest _) nil)))
            (ecc-tui-test--write file (seq-take lines half))
            (ecc-tui-open session)
            ;; What the recording already held is not replayed: the
            ;; transcript on screen already has it.
            (should (= (length (ecc-session-turns session)) 0))
            (should (= (ecc-tui-read-new-lines session) 0))
            ;; The terminal appends; the buffer follows.
            (ecc-tui-test--write file lines)
            (should (> (ecc-tui-read-new-lines session) 0))
            (let ((turns (length (ecc-session-turns session))))
              (should (> turns 0))
              ;; A line that is only half written is left for next time.
              (ecc-tui-test--append file "{\"type\":\"user\",\"mess")
              (should (= (ecc-tui-read-new-lines session) 0))
              (should (= (length (ecc-session-turns session)) turns))
              (ecc-tui-test--append
               file (concat "age\":{\"role\":\"user\",\"content\":\"and now?\"},"
                            "\"uuid\":\"z\",\"parentUuid\":null,"
                            "\"timestamp\":\"2026-09-06T00:00:00.000Z\"}\n"))
              (should (= (ecc-tui-read-new-lines session) 1))
              (should (= (length (ecc-session-turns session)) (1+ turns)))
              (should (equal (ecc-turn-prompt
                              (car (last (ecc-session-turns session))))
                             "and now?")))
            ;; A recording replaced under us is picked up from its end
            ;; rather than replayed from the top.
            (let ((turns (length (ecc-session-turns session))))
              (ecc-tui-test--write file (seq-take lines 2))
              (should (= (ecc-tui-read-new-lines session) 0))
              (should (= (length (ecc-session-turns session)) turns)))))
      (delete-file file))))

(ert-deftest ecc-tui-test-buffer-says-where-the-session-is ()
  "The transcript says the session is in a terminal."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil)))
      (ecc-session-ensure-buffer session)
      (ecc-tui-open session)
      (ecc-render-flush session)
      (should (string-search "open in the terminal"
                             (ecc-test-buffer-string (ecc-session-buffer session))))
      (with-current-buffer (ecc-session-buffer session)
        (should (string-search "⇄ terminal" (ecc-render-mode-line-process)))
        (should (string-search "handed over to the terminal"
                               (substring-no-properties (ecc-render-header-line))))))))

;;;; Coming back

(ert-deftest ecc-tui-test-returns-when-the-terminal-ends ()
  "The session is resumed headless as soon as the terminal process dies."
  (ecc-tui-test--with-session session
    (let ((resumed nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
                ((symbol-function 'ecc-proc-start)
                 (lambda (_session &optional resume _fork) (setq resumed resume))))
        (ecc-tui-open session)
        (should-not (ecc-tui-finished-p session))
        ;; While the terminal is there, nothing is resumed.
        (ecc-tui--tick session)
        (should-not resumed)
        (should (ecc-tui-handoff-p session))
        ;; The terminal is left: the sentinel takes the session back
        ;; without waiting for the next poll.
        (delete-process (plist-get (ecc-tui-state session) :process))
        (with-timeout (5 (ert-fail "the terminal ended and nothing came back"))
          (while (not resumed) (sit-for 0.05)))
        (should (eq resumed t))
        (should (eq (ecc-session-kind session) 'own))
        (should-not (ecc-tui-handoff-p session))))))

(ert-deftest ecc-tui-test-a-dead-terminal-is-noticed-by-the-poll ()
  "A terminal that dies unseen is still noticed on the next check."
  (ecc-tui-test--with-session session
    (let ((resumed nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
                ((symbol-function 'ecc-proc-start)
                 (lambda (_session &optional resume _fork) (setq resumed resume))))
        (ecc-tui-open session)
        ;; The sentinel is taken away, as a terminal of its own could do.
        (let ((process (plist-get (ecc-tui-state session) :process)))
          (set-process-sentinel process #'ignore)
          (delete-process process))
        (should (ecc-tui-finished-p session))
        (ecc-tui--tick session)
        (should (eq resumed t))
        (should-not (ecc-tui-handoff-p session))))))

(ert-deftest ecc-tui-test-the-terminals-own-sentinel-still-runs ()
  "Watching the terminal does not take its own teardown away from it."
  (ecc-tui-test--with-session session
    (let ((torn-down nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
                ((symbol-function 'ecc-proc-start) (lambda (&rest _) nil))
                ((symbol-function 'ecc-tui--open-ghostel)
                 (lambda (session)
                   (let* ((buffer (get-buffer-create (ecc-tui-buffer-name session)))
                          (process (start-process "ecc-tui-test" buffer "sleep" "60")))
                     (set-process-sentinel process
                                           (lambda (&rest _) (setq torn-down t)))
                     (cons buffer process)))))
        (ecc-tui-open session)
        (delete-process (plist-get (ecc-tui-state session) :process))
        (with-timeout (5 (ert-fail "the terminal's own sentinel never ran"))
          (while (not torn-down) (sit-for 0.05)))
        (should torn-down)))))

(ert-deftest ecc-tui-test-ghostel-really-runs-and-really-comes-back ()
  "The ghostel backend is driven for real, with a stand-in for the CLI.
Nothing here is replaced but the CLI itself and the resume: the buffer,
the process, the sentinel and the teardown are ghostel's own."
  (skip-unless (and (require 'ghostel nil t) (fboundp 'ghostel-exec)))
  (ecc-test-with-fake-session session
    (let ((script (make-temp-file "ecc-tui-cli" nil ".sh"
                                  "#!/bin/sh\nsleep 30\n"))
          (resumed nil))
      (set-file-modes script #o755)
      (unwind-protect
          (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                    ((symbol-function 'ecc-registry-session) (lambda (_id) nil))
                    ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
                    ((symbol-function 'ecc-proc-start)
                     (lambda (_session &optional resume _fork) (setq resumed resume))))
            (let ((ecc-executable script)
                  (ecc-tui-terminal 'ghostel)
                  (ecc-tui--handoffs (make-hash-table :test #'equal)))
              (ecc-tui-open session)
              (let* ((state (ecc-tui-state session))
                     (buffer (plist-get state :buffer))
                     (process (plist-get state :process)))
                (should (process-live-p process))
                (should (buffer-live-p buffer))
                ;; The terminal is on screen: it is what the user asked for.
                (should (get-buffer-window buffer))
                (should (eq (ecc-session-kind session) 'handoff))
                ;; Leaving the terminal takes the session back, and
                ;; ghostel still gets to clean up after itself: its own
                ;; sentinel is called before ours (it kills the buffer).
                (delete-process process)
                (with-timeout (5 (ert-fail "the hand-off never came back"))
                  (while (not resumed) (sit-for 0.05)))
                (should (eq resumed t))
                (should (eq (ecc-session-kind session) 'own))
                (should-not (ecc-tui-handoff-p session))
                (should-not (buffer-live-p buffer)))))
        (delete-file script)
        (when-let* ((buffer (get-buffer (ecc-tui-buffer-name session))))
          (kill-buffer buffer))))))

(ert-deftest ecc-tui-test-does-not-resume-behind-a-live-terminal ()
  "A terminal that is still running keeps the session."
  (ecc-tui-test--with-session session
    (let ((resumed nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) t))
                ((symbol-function 'ecc-proc-start)
                 (lambda (_session &optional resume _fork) (setq resumed resume))))
        (ecc-tui-open session)
        (should-not (ecc-tui-return session))
        (should-not resumed)
        ;; The hand-off is kept, so the watch can take it back later.
        (should (ecc-tui-handoff-p session))))))

(ert-deftest ecc-tui-test-does-not-resume-behind-a-terminal-it-started ()
  "A terminal of this hand-off keeps the session, registry or no registry.
The registry is the CLI's own book: a CLI that has not written itself
into it yet, or one whose entry went missing, would let a second
process onto the session and branch the conversation."
  (ecc-tui-test--with-session session
    (let ((resumed nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
                ((symbol-function 'ecc-proc-start)
                 (lambda (_session &optional resume _fork) (setq resumed resume))))
        (ecc-tui-open session)
        (should (process-live-p (plist-get (ecc-tui-state session) :process)))
        (should-not (ecc-tui-return session))
        (should-not resumed)
        (should (ecc-tui-handoff-p session))))))

(ert-deftest ecc-tui-test-a-terminal-that-will-not-open-undoes-the-handoff ()
  "A hand-off whose terminal never opened is taken back off the session.
The process was stopped to make room for it, and what takes a session
back is the terminal ending: a hand-off left on a session that has no
terminal is one nothing would ever end."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
              ((symbol-function 'ecc-tui--open-ghostel)
               (lambda (_session) (user-error "ghostel is not installed"))))
      (should-error (ecc-tui-open session) :type 'user-error)
      (should-not (ecc-tui-handoff-p session))
      (should-not (eq (ecc-session-kind session) 'handoff))
      (should-not (ecc-tui-state session)))))

(ert-deftest ecc-tui-test-the-turn-the-follow-left-open-is-closed-on-the-way-back ()
  "The turn the follow leaves open ends when the hand-off does.
A batch of appended lines is the middle of a turn, so the follow keeps
it open; left open past the hand-off it would hold every prompt sent
afterwards in the queue, and the session would take nothing said to it
ever again."
  (let* ((file (make-temp-file "ecc-tui-" nil ".jsonl"))
         (lines (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents (ecc-test-history-fixture "session")))
                  (split-string (buffer-string) "\n" t))))
    (unwind-protect
        (ecc-tui-test--with-session session
          (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) file))
                    ((symbol-function 'file-notify-add-watch) (lambda (&rest _) nil))
                    ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
                    ((symbol-function 'ecc-proc-start)
                     (lambda (session &optional _resume _fork)
                       (ecc-model-set-state session 'idle) nil)))
            (ecc-tui-test--write file (seq-take lines 2))
            (ecc-tui-open session)
            (ecc-tui-test--write file lines)
            (should (> (ecc-tui-read-new-lines session) 0))
            ;; While the terminal has it, the turn stays open.
            (should (ecc-session-current-turn session))
            (let ((process (plist-get (ecc-tui-state session) :process)))
              (set-process-sentinel process #'ignore)
              (delete-process process))
            (ecc-tui-return session)
            (should-not (ecc-session-current-turn session))
            ;; The turn ended when the recording says it did, not when
            ;; the terminal happened to be left.
            (let ((turn (car (last (ecc-session-turns session)))))
              (should (ecc-turn-end-time turn))
              (should (time-less-p (ecc-turn-end-time turn) (current-time))))
            ;; So a prompt sent now goes out instead of joining a queue
            ;; nothing will ever drain.
            (should (eq (ecc-proc-send-prompt session "and now?") 'sent))
            (should-not (ecc-session-input-queue session))))
      (delete-file file))))

(ert-deftest ecc-tui-test-what-was-queued-before-the-handoff-goes-out-after-it ()
  "A prompt queued behind the interrupted turn is sent when it comes back.
What usually sends it is a turn coming to an end, and that happened in
the terminal."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
              ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
              ((symbol-function 'ecc-proc-start) (lambda (&rest _) nil)))
      (ecc-model-set-state session 'running)
      (ecc-model-begin-turn session "first")
      (ecc-model-queue-input session "queued while busy")
      (ecc-tui-open session)
      (let ((process (plist-get (ecc-tui-state session) :process)))
        (set-process-sentinel process #'ignore)
        (delete-process process))
      (ecc-tui-return session)
      (should-not (ecc-session-input-queue session))
      (should (equal (ecc-turn-prompt (car (last (ecc-session-turns session))))
                     "queued while busy")))))

(ert-deftest ecc-tui-test-a-recording-joined-mid-character-does-not-drift ()
  "The follow counts bytes, so joining a half-written character is survived.
The position is an offset into the file.  A character the CLI was
halfway through writing is read back as the raw bytes Emacs keeps two
bytes apiece, and counting those would push the position past the line
end and lose the head of a line in every batch after it."
  (let* ((file (make-temp-file "ecc-tui-" nil ".jsonl"))
         (line (lambda (uuid text)
                 (format (concat "{\"parentUuid\":null,\"isSidechain\":false,"
                                 "\"type\":\"user\",\"message\":{\"role\":\"user\","
                                 "\"content\":\"%s\"},\"uuid\":\"%s\","
                                 "\"timestamp\":\"2026-09-06T00:00:00.000Z\"}")
                         text uuid))))
    (unwind-protect
        (ecc-tui-test--with-session session
          (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) file))
                    ((symbol-function 'file-notify-add-watch) (lambda (&rest _) nil)))
            (ecc-tui-test--write file (list (funcall line "a" "ひとつめ")))
            ;; The CLI is halfway through a multibyte character when the
            ;; follow joins the recording.
            (ecc-tui-test--append
             file (substring (encode-coding-string "{\"content\":\"あ" 'utf-8) 0 -1))
            (ecc-tui-open session)
            ;; It finishes that character and that line, and writes
            ;; another line.  The byte the character was missing is the
            ;; first thing the next read sees, and it is read back as a
            ;; raw byte because there is nothing in front of it.
            (ecc-tui-test--append
             file (concat (substring (encode-coding-string "あ" 'utf-8) -1) "\"}\n"))
            (ecc-tui-test--append file (concat (funcall line "b" "ふたつめ") "\n"))
            (ecc-tui-read-new-lines session)
            (ecc-tui-test--append file (concat (funcall line "c" "みっつめ") "\n"))
            (ecc-tui-read-new-lines session)
            ;; The half-written line is not a message and is dropped;
            ;; the two after it are read whole.
            (should (equal (mapcar #'ecc-turn-prompt (ecc-session-turns session))
                           '("ふたつめ" "みっつめ")))
            (should (= (plist-get (ecc-tui-state session) :position)
                       (file-attribute-size (file-attributes file))))))
      (delete-file file))))

(provide 'ecc-tui-test)

;;; ecc-tui-test.el ends here
