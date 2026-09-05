;;; ecc-model-test.el --- Tests for ecc-model  -*- lexical-binding: t; -*-

;;; Commentary:

;; The transcript tree, the pending queue and the input queue of section
;; 3 of IMPLEMENTATION_PLAN.md.

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
      ;; A turn wide approval lasts exactly one turn (FR-PERM-7).
      (should-not (ecc-session-auto-approve-turn session))
      (should (= (ecc-session-total-cost session) 0.5))
      (should (= (ecc-model-turn-duration turn) 1.5))
      (should (equal (ecc-turn-id (ecc-model-begin-turn session "again")) "turn-2")))))

(ert-deftest ecc-model-test-implicit-turn ()
  "Output that arrives without a prompt still lands in a turn (FR-OUT-1)."
  (ecc-test-with-fake-session session
    (let ((turn (ecc-model-ensure-turn session)))
      (should turn)
      (should-not (ecc-turn-prompt turn))
      (should (eq turn (ecc-model-ensure-turn session))))))

(ert-deftest ecc-model-test-step-splitting ()
  "Consecutive tool calls share a step; text starts a new one (FR-OUT-2)."
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
  "A node keeps the id a later message will look it up by (FR-OUT-5)."
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
  "What Claude read and wrote is counted per file (FR-OUT-12, 13)."
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
  "Prompts wait in order while a turn runs (FR-INP-6)."
  (ecc-test-with-fake-session session
    (should (= (ecc-model-queue-input session "one") 1))
    (should (= (ecc-model-queue-input session "two") 2))
    (should (equal (ecc-model-pop-input session) "one"))
    (should (equal (ecc-model-pop-input session) "two"))
    (should-not (ecc-model-pop-input session))))

(ert-deftest ecc-model-test-hooks-fire ()
  "Every change the renderer needs is announced (plan section 4.3)."
  (ecc-test-with-fake-session session
    (let (seen)
      (cl-letf* ((watch (lambda (&rest _) (push 'x seen)))
                 (ecc-node-added-hook (list watch))
                 (ecc-turn-started-hook (list watch))
                 (ecc-session-state-changed-hook (list watch)))
        (ecc-model-begin-turn session "hi")   ; started + state changed
        (ecc-model-add-node session :type 'text)
        (should (= (length seen) 3))))))

(provide 'ecc-model-test)

;;; ecc-model-test.el ends here
