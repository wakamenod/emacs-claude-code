;;; ecc-model-test.el --- Tests for ecc-model  -*- lexical-binding: t; -*-

;;; Commentary:

;; The transcript tree, the pending queue and the input queue.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-model)

(ert-deftest ecc-model-test-registry ()
  "Sessions are registered, ordered by use and given unique names."
  (ecc-test-with-fake-session session
    (should (eq (ecc-model-session (ecc-session-id session)) session))
    (let ((other (ecc-model-create-session
                  :name "test" :project-root temporary-file-directory)))
      ;; The second session asking for a taken name gets a suffix.
      (should (equal (ecc-session-name other) "test<2>"))
      (should (equal (mapcar #'ecc-session-name (ecc-model-sessions))
                     '("test<2>" "test")))
      (ecc-model-touch session)
      (should (eq (car (ecc-model-sessions)) session))
      (ecc-model-remove-session other)
      (should (equal (ecc-model-sessions) (list session))))))

(ert-deftest ecc-model-test-unique-name-excepts-one-session ()
  "A session is not what its own name collides with."
  (ecc-test-with-fake-session session
    (should (equal (ecc-model-unique-name "test") "test<2>"))
    (should (equal (ecc-model-unique-name "test" session) "test"))
    (should (equal (ecc-model-unique-name "other" session) "other"))))

(ert-deftest ecc-model-test-session-id-moves ()
  "A forked session keeps its place in the registry under the new id."
  (ecc-test-with-fake-session session
    (ecc-model-set-session-id session "new-id")
    (should (eq (ecc-model-session "new-id") session))
    (should-not (ecc-model-session "old-id"))
    (should (equal (ecc-model-sessions) (list session)))))

(ert-deftest ecc-model-test-turn-lifecycle ()
  "A turn is opened by Emacs and closed by the result."
  (ecc-test-with-fake-session session
    (let ((turn (ecc-model-begin-turn session "hello")))
      (should (eq (ecc-session-current-turn session) turn))
      (should (equal (ecc-turn-id turn) "turn-1"))
      (should (eq (ecc-session-state session) 'running))
      (setf (ecc-session-auto-approve-turn session) t)
      (ecc-model-finish-turn session '((total_cost_usd . 0.5) (duration_ms . 1500)))
      (should-not (ecc-session-current-turn session))
      ;; A turn wide approval lasts exactly one turn.
      (should-not (ecc-session-auto-approve-turn session))
      (should (= (ecc-session-total-cost session) 0.5))
      (should (= (ecc-model-turn-duration turn) 1.5))
      (should (equal (ecc-turn-id (ecc-model-begin-turn session "again")) "turn-2")))))

(ert-deftest ecc-model-test-turn-cost-is-the-step-of-the-running-total ()
  "A result carries the CLI's running total; a turn costs what it added.
A result that called no model repeats the total and costs nothing, and
the session's total is the last one rather than the sum of them all."
  (ecc-test-with-fake-session session
    (let ((costs nil))
      (dolist (total '(0.5 0.5 0.8))
        (ecc-model-begin-turn session "go")
        (push (ecc-turn-cost (ecc-model-finish-turn
                              session `((total_cost_usd . ,total))))
              costs))
      (should (equal '(0.5 0.0 0.3)
                     (mapcar (lambda (cost) (/ (round (* cost 1000)) 1000.0))
                             (nreverse costs))))
      (should (< (abs (- (ecc-session-total-cost session) 0.8)) 1e-9))
      (should (= (ecc-session-cost-base session) 0.8)))))

(ert-deftest ecc-model-test-turn-cost-unknown-base ()
  "Without a base to count from, what a turn cost is not known.
It is neither guessed nor added to the session, and the next result
counts from this one.  A total below the base is the same case: the CLI
started from a total that was not the one expected."
  (ecc-test-with-fake-session session
    (setf (ecc-session-total-cost session) 1.0)
    (ecc-model-set-cost-base session nil)
    (ecc-model-begin-turn session "first")
    (should-not (ecc-turn-cost (ecc-model-finish-turn
                                session '((total_cost_usd . 2.0)))))
    (should (= (ecc-session-total-cost session) 1.0))
    (ecc-model-begin-turn session "second")
    (should (= 0.25 (ecc-turn-cost (ecc-model-finish-turn
                                    session '((total_cost_usd . 2.25))))))
    (should (= (ecc-session-total-cost session) 1.25))
    ;; Below the base.
    (ecc-model-begin-turn session "third")
    (should-not (ecc-turn-cost (ecc-model-finish-turn
                                session '((total_cost_usd . 0.1)))))
    (should (= (ecc-session-total-cost session) 1.25))
    (should (= (ecc-session-cost-base session) 0.1))
    ;; A result without a total leaves the base where it was.
    (ecc-model-begin-turn session "fourth")
    (should-not (ecc-turn-cost (ecc-model-finish-turn session '((subtype . "success")))))
    (should (= (ecc-session-cost-base session) 0.1))))

(ert-deftest ecc-model-test-implicit-turn ()
  "Output that arrives without a prompt still lands in a turn."
  (ecc-test-with-fake-session session
    (let ((turn (ecc-model-ensure-turn session)))
      (should turn)
      (should-not (ecc-turn-prompt turn))
      (should (eq turn (ecc-model-ensure-turn session))))))

(ert-deftest ecc-model-test-step-splitting ()
  "Consecutive tool calls share a step; text starts a new one."
  (ecc-test-with-fake-session session
    (let ((turn (ecc-model-begin-turn session "hello")))
      (let ((step (ecc-model-step-for-tool session turn)))
        (ecc-model-add-node session :id "t1" :type 'tool :parent step
                            :data '((name . "Read")))
        (ecc-model-add-node session :id "t2" :type 'tool :parent step
                            :data '((name . "Read"))))
      (should (eq (ecc-model-step-for-tool session turn)
                  (car (ecc-turn-children turn))))
      (ecc-model-add-node session :type 'text :parent turn :data '((text . "hi")))
      (let ((step (ecc-model-step-for-tool session turn)))
        (ecc-model-add-node session :id "t3" :type 'tool :parent step
                            :data '((name . "Bash"))))
      (should (equal (ecc-test-turn-shape turn)
                     '((step tool tool) text (step tool))))
      ;; The step heading counts the tools it holds.
      (should (equal (ecc-model-tool-counts (car (ecc-turn-children turn)))
                     '(("Read" . 2)))))))

(ert-deftest ecc-model-test-nodes-are-addressable ()
  "A node keeps the id a later message will look it up by."
  (ecc-test-with-fake-session session
    (let ((node (ecc-model-add-node session :id "toolu_1" :type 'tool
                                    :data '((name . "Write")))))
      (should (eq (ecc-model-node session "toolu_1") node))
      (ecc-model-node-put node 'result "done")
      (should (equal (ecc-model-node-get node 'result) "done"))
      (should (ecc-turn-p (ecc-model-turn-of node))))))

(ert-deftest ecc-model-test-pending-queue ()
  "Requests queue up, move the state and are answered oldest first."
  (ecc-test-with-fake-session session
    (let* ((node (ecc-model-add-node session :type 'permission :status 'pending))
           (first (make-ecc-request :request-id "r1" :session session
                                    :kind 'permission :tool-name "Write"
                                    :created-at '(1 1) :node node))
           (second (make-ecc-request :request-id "r2" :session session
                                     :kind 'question :tool-name "AskUserQuestion"
                                     :created-at '(2 2))))
      (ecc-model-add-request session first)
      (should (eq (ecc-session-state session) 'waiting-permission))
      (ecc-model-add-request session second)
      (should (eq (ecc-session-state session) 'waiting-question))
      (should (eq (ecc-model-request session "r1") first))
      (should (equal (ecc-model-pending-all) (list first second)))
      (ecc-model-resolve-request session first 'denied)
      (should (eq (ecc-node-status node) 'denied))
      (should (equal (ecc-session-pending session) (list second)))
      (ecc-model-resolve-request session second 'done)
      (should-not (ecc-session-pending session))
      ;; Adding the node above opened an implicit turn, so the session
      ;; goes back to running rather than to idle.
      (should (eq (ecc-session-state session) 'running))
      (ecc-model-finish-turn session nil)
      (ecc-model-add-request session second)
      (ecc-model-resolve-request session second 'done)
      (should (eq (ecc-session-state session) 'idle)))))

(ert-deftest ecc-model-test-files-and-tasks ()
  "What Claude read and wrote is counted per file."
  (ecc-test-with-fake-session session
    (ecc-model-note-file session "/tmp/a.txt" 'read)
    (ecc-model-note-file session "/tmp/a.txt" 'write)
    (ecc-model-note-file session "/tmp/a.txt" 'edit)
    (let ((entry (gethash "/tmp/a.txt" (ecc-session-files session))))
      (should (= (ecc-file-entry-reads entry) 1))
      (should (= (ecc-file-entry-writes entry) 1))
      (should (= (ecc-file-entry-edits entry) 1)))
    (ecc-model-note-task session "task-1" "explore" "in_progress")
    (ecc-model-note-task session "task-1" nil "completed")
    (let ((task (gethash "task-1" (ecc-session-tasks session))))
      (should (equal (ecc-task-subject task) "explore"))
      (should (equal (ecc-task-status task) "completed")))))

(ert-deftest ecc-model-test-usage ()
  "The context estimate adds the three input side counters (12.9)."
  (ecc-test-with-fake-session session
    (ecc-model-update-usage session '((input_tokens . 10)
                                      (cache_read_input_tokens . 100)
                                      (cache_creation_input_tokens . 5)
                                      (output_tokens . 999)))
    (should (= (ecc-session-context-tokens session) 115))))

(ert-deftest ecc-model-test-input-queue ()
  "Prompts wait in order while a turn runs."
  (ecc-test-with-fake-session session
    (should (= (ecc-model-queue-input session "one") 1))
    (should (= (ecc-model-queue-input session "two") 2))
    (should (equal (ecc-model-pop-input session) "one"))
    (should (equal (ecc-model-pop-input session) "two"))
    (should-not (ecc-model-pop-input session))))

(ert-deftest ecc-model-test-input-queue-keeps-the-draft ()
  "An entry carries what was typed beside what will be sent; FIRST jumps the queue."
  (ecc-test-with-fake-session session
    (ecc-model-queue-input session "typed\n\n```context```" "typed")
    (should (= (ecc-model-queue-input session "a note from Emacs" nil t) 1))
    (should (equal (ecc-model-queued-texts session)
                   '("a note from Emacs" "typed\n\n```context```")))
    (should (equal (mapcar #'ecc-queued-draft (ecc-session-input-queue session))
                   '(nil "typed")))))

(ert-deftest ecc-model-test-input-queue-take-and-move ()
  "Entries are taken and moved by identity, and each change is announced."
  (ecc-test-with-fake-session session
    (let ((changes 0))
      (cl-letf ((ecc-input-queue-changed-hook
                 (list (lambda (changed)
                         (should (eq changed session))
                         (cl-incf changes)))))
        (dolist (text '("one" "two" "three"))
          (ecc-model-queue-input session text text))
        (should (= changes 3))
        (pcase-let ((`(,one ,two ,three) (ecc-session-input-queue session)))
          (should (= (ecc-model-move-input session three -1) 2))
          (should (equal (ecc-model-queued-texts session) '("one" "three" "two")))
          ;; At the head already: no move, no news.
          (should (= (ecc-model-move-input session one -1) 1))
          (should (= changes 4))
          (should (= (ecc-model-move-input session one 5) 3))
          (should (equal (ecc-model-queued-texts session) '("three" "two" "one")))
          (should (eq (ecc-model-take-input session two) two))
          (should (equal (ecc-model-queued-texts session) '("three" "one")))
          (should (= changes 6))
          ;; Gone is gone: nothing else is acted on in its place.
          (should-not (ecc-model-take-input session two))
          (should-not (ecc-model-move-input session two 1))
          (should (equal (ecc-model-pop-input session) "three"))
          (should (= changes 7))
          (should (equal (ecc-model-queued-texts session) '("one"))))))))

(ert-deftest ecc-model-test-hooks-fire ()
  "Every change the renderer needs is announced."
  (ecc-test-with-fake-session session
    (let (seen)
      (cl-letf* ((watch (lambda (&rest _) (push 'x seen)))
                 (ecc-node-added-hook (list watch))
                 (ecc-turn-started-hook (list watch))
                 (ecc-session-state-changed-hook (list watch)))
        (ecc-model-begin-turn session "hi")   ; started + state changed
        (ecc-model-add-node session :type 'text)
        (should (= (length seen) 3))))))

(ert-deftest ecc-model-test-pending-all-leaves-the-queues-alone ()
  "Listing the requests of two sessions must not reorder or share their queues."
  (let ((ecc--sessions (make-hash-table :test #'equal))
        (ecc--session-order nil))
    (let* ((a (ecc-model-create-session :name "a" :project-root temporary-file-directory))
           (b (ecc-model-create-session :name "b" :project-root temporary-file-directory))
           (old (make-ecc-request :request-id "old" :session a :kind 'permission
                                  :tool-name "Bash"
                                  :created-at (time-subtract (current-time) 60)))
           (new (make-ecc-request :request-id "new" :session b :kind 'permission
                                  :tool-name "Write" :created-at (current-time))))
      (ecc-model-add-request a old)
      (ecc-model-add-request b new)
      (should (equal (ecc-model-pending-all) (list old new)))
      (should (equal (ecc-model-pending-all) (list old new)))
      (should (equal (ecc-session-pending a) (list old)))
      (should (equal (ecc-session-pending b) (list new)))
      (should (equal (ecc-model-pending-all temporary-file-directory) (list old new)))
      (should-not (ecc-model-pending-all "/nonexistent/")))))

(ert-deftest ecc-model-test-created-counts-up ()
  "Every session records the order it was made in.
The tab line reads it: the registry is most recently used first, which
would shuffle the tabs about as one works."
  (let ((ecc--sessions (make-hash-table :test #'equal))
        (ecc--session-order nil))
    (let ((a (ecc-model-create-session :name "a"
                                       :project-root temporary-file-directory))
          (b (ecc-model-create-session :name "b"
                                       :project-root temporary-file-directory)))
      (should (< (ecc-session-created a) (ecc-session-created b)))
      ;; Using a session does not change it, though it does move the
      ;; session to the front of the registry.
      (ecc-model-touch a)
      (should (eq (car (ecc-model-sessions)) a))
      (should (< (ecc-session-created a) (ecc-session-created b))))))

;;;; Streaming text

(ert-deftest ecc-model-test-streamed-text-is-joined-on-demand ()
  "Deltas are kept as they come and joined when the text is asked for."
  (ecc-test-with-fake-session session
    (let* ((turn (ecc-model-begin-turn session "x"))
           (node (ecc-model-add-node session :type 'text :parent turn
                                     :status 'running :data (list (cons 'text "")))))
      (ecc-model-open-stream session nil 0 node)
      (should (equal (ecc-model-streaming-text node) ""))
      (should (= (ecc-node-streaming-length node) 0))
      (ecc-model-append-stream session node "Done")
      (ecc-model-append-stream session node ".")
      (should (= (ecc-node-streaming-length node) 5))
      (should (equal (ecc-model-streaming-text node) "Done."))
      ;; Joined once, then grown again: the join is a prefix, not lost.
      (ecc-model-append-stream session node " Created")
      (should (equal (ecc-model-streaming-text node) "Done. Created"))
      (should (= (ecc-node-streaming-length node) 13))
      (ecc-model-forget-stream-text node)
      (should (null (ecc-model-streaming-text node)))
      (should (null (ecc-node-streaming-length node))))))

(ert-deftest ecc-model-test-streamed-text-makes-little-garbage ()
  "A long block streamed in small deltas does not copy itself per delta.
Joining on every delta was quadratic: 8000 deltas of one reply made
ten collections, and a collection stops every buffer, not just this one
(measured 2026-09-13)."
  (ecc-test-with-fake-session session
    (let* ((turn (ecc-model-begin-turn session "x"))
           (node (ecc-model-add-node session :type 'text :parent turn
                                     :status 'running :data (list (cons 'text ""))))
           (delta (make-string 8 ?a)))
      (ecc-model-open-stream session nil 0 node)
      (garbage-collect)
      (let ((before gcs-done))
        (dotimes (_ 8000) (ecc-model-append-stream session node delta))
        (should (<= (- gcs-done before) 1)))
      (should (= (ecc-node-streaming-length node) 64000))
      (should (= (length (ecc-model-streaming-text node)) 64000)))))

(ert-deftest ecc-model-test-reset-conversation ()
  "A session emptied of its conversation is still the user's session.
`ecc-history-take-over' carries a window on with another recording: the
turns, the queue and the costs go, the name, the buffers, the options
and the review baseline stay."
  (ecc-test-with-fake-session session
    (setf (ecc-session-options session) '(:model "opus")
          (ecc-session-baseline session) "deadbeef"
          (ecc-session-init session) '((cwd . "/tmp/"))
          (ecc-session-total-cost session) 1.5
          (ecc-session-cost-base session) 1.5
          (ecc-session-context-tokens session) 4200)
    (let ((turn (ecc-model-begin-turn session "one")))
      (ecc-model-add-node session :type 'text :parent turn :status 'done
                          :data (list (cons 'text "hello")))
      (ecc-model-finish-turn session nil))
    (ecc-model-queue-input session "held back")
    (puthash "x" #'ignore (ecc-session-pending-controls session))
    (let ((id (ecc-session-id session))
          (name (ecc-session-name session))
          (buffer (ecc-session-buffer session)))
      (ecc-model-reset-conversation session)
      (should-not (ecc-session-turns session))
      (should-not (ecc-session-current-turn session))
      (should-not (ecc-session-input-queue session))
      (should-not (ecc-session-init session))
      (should (= 0 (hash-table-count (ecc-session-nodes session))))
      (should (= 0 (hash-table-count (ecc-session-pending-controls session))))
      (should (= 0 (ecc-session-total-cost session)))
      (should (= 0 (ecc-session-cost-base session)))
      (should (= 0 (ecc-session-context-tokens session)))
      ;; What the user has stays.
      (should (equal id (ecc-session-id session)))
      (should (equal name (ecc-session-name session)))
      (should (eq buffer (ecc-session-buffer session)))
      (should (equal '(:model "opus") (ecc-session-options session)))
      (should (equal "deadbeef" (ecc-session-baseline session)))
      ;; And it is still the session that id resolves to.
      (should (eq session (ecc-model-session id))))))

(provide 'ecc-model-test)

;;; ecc-model-test.el ends here
