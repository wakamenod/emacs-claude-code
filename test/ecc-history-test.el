;;; ecc-history-test.el --- Tests for ecc-history  -*- lexical-binding: t; -*-

;;; Commentary:

;; Reading a recorded conversation back: which lines open a turn, which
;; page is read first, what the tree looks like afterwards and what a
;; replay is not allowed to do.
;;
;; test/fixtures/history/session.jsonl was recorded by
;; scripts/record-history.sh: three turns, one Write and one Read.

;;; Code:

(require 'ert)
(require 'benchmark)
(require 'ecc-test-helpers)
(require 'ecc-history)
(require 'ecc)
(require 'ecc-render)
(require 'ecc-session)

(defconst ecc-history-test-file (ecc-test-history-fixture "session")
  "The recorded conversation the tests read.")

(defconst ecc-history-test-prompts
  '("hello とだけ答えて"
    "hi.txt というファイルを作って。中身は hi の 1 行だけ"
    "hi.txt を読んで、中身をそのまま教えて")
  "The three prompts of the recording, oldest first.")

(defun ecc-history-test--prompts (session)
  "Return the prompts of the turns of SESSION, oldest first."
  (mapcar #'ecc-turn-prompt (ecc-session-turns session)))

(defmacro ecc-history-test--with-directory (var &rest body)
  "Run BODY with `ecc-history-directory' pointing at a copy of the fixture.
VAR is bound to the recording inside it, laid out the way the CLI does:
one directory per working directory, the session id as the file name."
  (declare (indent 1))
  `(let* ((root (make-temp-file "ecc-history-dir" t))
          (project (expand-file-name "-tmp-project" root))
          (,var (expand-file-name "24a1aa86-d53f-4457-b09e-4f4caf450f03.jsonl"
                                  project))
          (ecc-history-directory root)
          (ecc-history--files (make-hash-table :test #'equal)))
     (unwind-protect
         (progn
           (make-directory project t)
           (copy-file ecc-history-test-file ,var)
           ;; A session keeps its working files in a subdirectory of the
           ;; same place; those are not conversations.
           (make-directory (expand-file-name "24a1aa86-d53f-4457-b09e-4f4caf450f03"
                                             project)
                           t)
           ,@body)
       (delete-directory root t))))

;;;; Finding the turns

(ert-deftest ecc-history-test-turn-starts ()
  "Only the lines carrying a prompt open a turn."
  (let ((lines (ecc-history-lines ecc-history-test-file)))
    (should (= 40 (length lines)))
    ;; The tool results and the bookkeeping in between open nothing.
    (should (equal '(2 14 26) (ecc-history-turn-starts lines)))))

(ert-deftest ecc-history-test-user-line-prefilter ()
  "The cheap test lets every prompt through and drops the assistant lines."
  (let ((lines (ecc-history-lines ecc-history-test-file)))
    (dolist (index (ecc-history-turn-starts lines))
      (should (ecc-protocol-history-user-line-p (nth index lines))))
    ;; An assistant line names the type of its blocks before its own, so
    ;; a test that stops at the first "type" would misread it.
    (should-not (ecc-protocol-history-user-line-p (nth 10 lines)))
    (should (equal "assistant"
                   (alist-get 'type (ecc-protocol-history-parse (nth 10 lines)))))))

(ert-deftest ecc-history-test-page-start ()
  "The page is the last N turns, and one page back stops before it."
  (let ((starts '(0 10 20 30 40)))
    (should (= 30 (ecc-history-page-start starts 2)))
    (should (= 0 (ecc-history-page-start starts 99)))
    (should (= 10 (ecc-history-page-start starts 2 30)))
    (should (= 0 (ecc-history-page-start starts 2 20)))
    (should-not (ecc-history-page-start starts 2 0))
    (should-not (ecc-history-page-start nil 2))))

(ert-deftest ecc-history-test-bookkeeping-is-not-a-page ()
  "The lines before the first prompt are not offered as an older page."
  (should (= 0 (ecc-history--offset '(2 14 26) 2)))
  (should (= 14 (ecc-history--offset '(2 14 26) 14))))

;;;; Reading a recording back

(ert-deftest ecc-history-test-load-whole-file ()
  "Every turn is read, with its prompt, its tools and its duration."
  (ecc-test-with-fake-session session
    (should (= 3 (ecc-history-load session nil ecc-history-test-file)))
    (should (equal ecc-history-test-prompts (ecc-history-test--prompts session)))
    (should (equal '((thinking text)
                     (thinking (step tool) thinking text)
                     (thinking (step tool) thinking text))
                   (mapcar #'ecc-test-turn-shape (ecc-session-turns session))))
    ;; The timestamps of the recording, not the time of the replay.
    (should (equal '(1.0 6.0 3.0)
                   (mapcar #'ecc-model-turn-duration (ecc-session-turns session))))
    ;; A recording says nothing about what a turn cost.
    (should-not (seq-some #'ecc-turn-cost (ecc-session-turns session)))))

(ert-deftest ecc-history-test-model-comes-from-the-recording ()
  "A session read from history knows its model.
The recording carries no system/init, so the only place the model is
named is the assistant messages.  Without it every session read from
history was taken for the default window and showed no context left."
  (ecc-test-with-fake-session session
    (should-not (ecc-hint-model session))
    (ecc-history-load session nil ecc-history-test-file)
    (should (equal (ecc-hint-model session) "claude-haiku-4-5-20251001"))
    (should (= (ecc-hint-model-window session) 200000))
    ;; A recording of three short turns leaves most of it.
    (should (> (ecc-hint-context-left session) 0.8))))

(ert-deftest ecc-history-test-a-synthetic-answer-keeps-the-model ()
  "The \"<synthetic>\" of a slash command is not the model of the session."
  (ecc-test-with-fake-session session
    (ecc-history-load session nil (ecc-test-history-fixture "local-commands"))
    (should (equal (ecc-hint-model session) "claude-haiku-4-5-20251001"))))

(ert-deftest ecc-history-test-nothing-is-unknown ()
  "No line of a recording falls through the dispatch table."
  (ecc-test-with-fake-session session
    (ecc-history-load session nil ecc-history-test-file)
    (should (equal 0 (length (seq-filter (lambda (node)
                                           (eq (ecc-node-type node) 'unknown))
                                         (hash-table-values
                                          (ecc-session-nodes session))))))))

(ert-deftest ecc-history-test-structured-result ()
  "The structured result of a recording feeds the Files summary.
The recording spells it toolUseResult where the stream says
tool_use_result, so this fails if the two are not brought together."
  (ecc-test-with-fake-session session
    (ecc-history-load session nil ecc-history-test-file)
    (let ((files (ecc-model-files session)))
      (should (= 1 (length files)))
      (should (string-suffix-p "hi.txt" (ecc-file-entry-path (car files))))
      (should (= 1 (ecc-file-entry-writes (car files))))
      (should (= 1 (ecc-file-entry-reads (car files))))
      ;; The patch came with the result, so the diff can be shown.
      (should (ecc-file-entry-patches (car files))))))

(ert-deftest ecc-history-test-paging ()
  "Opening reads the last page; the button puts the older turns in front."
  (ecc-test-with-fake-session session
    (should (= 2 (ecc-history-load session 2 ecc-history-test-file)))
    (should (equal (cdr ecc-history-test-prompts)
                   (ecc-history-test--prompts session)))
    (should (= 14 (ecc-session-history-offset session)))
    (should (ecc-history-more-p session))
    ;; The page before it is read and put in front, in the right order.
    (puthash (ecc-session-id session) ecc-history-test-file ecc-history--files)
    (should (= 1 (ecc-history-load-more session 1)))
    (should (equal ecc-history-test-prompts (ecc-history-test--prompts session)))
    (should (= 0 (ecc-session-history-offset session)))
    (should-not (ecc-history-more-p session))
    ;; Asking again says so rather than reading the file twice.
    (should (= 0 (ecc-history-load-more session 1)))
    (should (equal ecc-history-test-prompts (ecc-history-test--prompts session)))))

(ert-deftest ecc-history-test-recording-only-system-lines ()
  "A system line only a recording holds is a folded note, not an unknown.
The duration the CLI measured closes the turn, since a recording has no
result message to carry it."
  (ecc-test-with-fake-session session
    (let ((lines (list
                  (concat "{\"type\": \"user\", \"uuid\": \"u1\","
                          " \"message\": {\"role\": \"user\","
                          " \"content\": \"go\"}}")
                  (concat "{\"type\": \"system\", \"subtype\": \"away_summary\","
                          " \"content\": \"what happened while you were away\"}")
                  (concat "{\"type\": \"system\", \"subtype\": \"turn_duration\","
                          " \"durationMs\": 22420}"))))
      (ecc-history--replay session lines)
      (let ((turn (car (ecc-session-turns session))))
        (should (equal '(system) (ecc-test-turn-shape turn)))
        (let ((note (car (ecc-turn-children turn))))
          (should (eq 'history (ecc-model-node-get note 'kind)))
          (should (equal "what happened while you were away"
                         (ecc-model-node-get note 'text))))
        (should (equal 22.42 (ecc-model-turn-duration turn))))
      (should (equal 0 (length (seq-filter
                                (lambda (node) (eq (ecc-node-type node) 'unknown))
                                (hash-table-values (ecc-session-nodes session)))))))))

(ert-deftest ecc-history-test-command-output-opens-no-turn ()
  "Neither a slash command nor what it printed is a prompt."
  (ecc-test-with-fake-session session
    (let ((lines (list
                  (concat "{\"type\": \"user\", \"uuid\": \"u1\","
                          " \"message\": {\"role\": \"user\","
                          " \"content\": \"<command-name>/model</command-name>\"}}")
                  (concat "{\"type\": \"user\", \"uuid\": \"u2\","
                          " \"message\": {\"role\": \"user\", \"content\":"
                          " \"<local-command-stdout>Set model</local-command-stdout>\"}}"))))
      (ecc-history--replay session lines)
      ;; The CLI answered the command itself, so nothing was said to the
      ;; model: the turn the node hangs from carries no prompt, and the
      ;; command is one node with what it printed on it.
      (should-not (seq-some #'ecc-turn-prompt (ecc-session-turns session)))
      (let ((nodes (hash-table-values (ecc-session-nodes session))))
        (should (= 1 (length nodes)))
        (should (eq (ecc-node-type (car nodes)) 'command))
        (should (equal (ecc-model-node-get (car nodes) 'name) "/model"))
        (should (equal (ecc-model-node-get (car nodes) 'output) "Set model"))))))

(ert-deftest ecc-history-test-sidechain-is-counted-not-shown ()
  "A subagent line is left out and its number noted."
  (ecc-test-with-fake-session session
    (let* ((line (concat "{\"type\": \"assistant\", \"isSidechain\": true,"
                         " \"uuid\": \"s1\", \"message\": {\"role\": \"assistant\","
                         " \"content\": [{\"type\": \"text\", \"text\": \"hidden\"}]}}"))
           (lines (append (seq-take (ecc-history-lines ecc-history-test-file) 13)
                          (list line))))
      (ecc-history--replay session lines)
      (should (equal '(thinking text system)
                     (ecc-test-turn-shape (car (ecc-session-turns session)))))
      (let ((note (car (last (ecc-turn-children
                              (car (ecc-session-turns session)))))))
        (should (eq 'sidechain (ecc-model-node-get note 'kind)))
        (should (string-search "1 sidechain" (ecc-model-node-get note 'text)))))))

(ert-deftest ecc-history-test-replay-touches-nothing-outside ()
  "A replay does not revert a buffer, queue a request or say a session died."
  (ecc-test-with-fake-session session
    (let ((calls nil))
      (cl-letf (((symbol-function 'ecc-history-test--note)
                 (lambda (&rest args) (push args calls))))
        (let ((ecc-sync-file-changed-hook (list #'ecc-history-test--note))
              (ecc-request-added-hook (list #'ecc-history-test--note))
              (ecc-session-exited-hook (list #'ecc-history-test--note)))
          (ecc-history-load session nil ecc-history-test-file)
          (should-not calls))))
    ;; The session is left as it was found, not looking busy.
    (should-not (ecc-session-current-turn session))
    (should (eq 'starting (ecc-session-state session)))))

(defun ecc-history-test--note (&rest _)
  "Placeholder the replay test replaces; it must never be called."
  (error "The replay ran a hook of the outside world"))

;;;; Drawing

(ert-deftest ecc-history-test-snapshot ()
  "The recording is drawn as an ordinary transcript, with the paging button."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-history-load session 2 ecc-history-test-file)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "Load older messages" text))
      (should (ecc-test-snapshot "history" text)))))

(ert-deftest ecc-history-test-button-is-gone-when-all-is-read ()
  "Nothing offers an older page once the whole recording is in."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-history-load session nil ecc-history-test-file)
    (should-not (string-search "Load older messages"
                               (ecc-test-buffer-string
                                (ecc-session-buffer session))))))

(defun ecc-history-test--big-file (turns)
  "Write a recording of TURNS turns to a temporary file and return it.
The lines have the shape of a real recording, with the bookkeeping the
CLI writes in between; the point is the size, so the content is made up
rather than recorded."
  (let ((file (make-temp-file "ecc-history-big" nil ".jsonl")))
    (with-temp-file file
      (dotimes (n turns)
        (insert (format "{\"type\": \"last-prompt\", \"leafUuid\": \"u%d\"}\n" n))
        (insert (format "{\"parentUuid\": null, \"isSidechain\": false, \"type\": \"user\", \"message\": {\"role\": \"user\", \"content\": \"prompt %d\"}, \"uuid\": \"u%d\", \"timestamp\": \"2026-09-05T21:21:%02d.000Z\"}\n"
                        n n (mod n 60)))
        (insert (format "{\"parentUuid\": \"u%d\", \"isSidechain\": false, \"message\": {\"model\": \"claude-haiku-4-5\", \"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"answer %d\"}], \"usage\": {\"input_tokens\": 1}}, \"type\": \"assistant\", \"uuid\": \"a%d\", \"timestamp\": \"2026-09-05T21:21:%02d.000Z\"}\n"
                        n n n (mod n 60)))
        (insert (format "{\"type\": \"attachment\", \"attachment\": {\"type\": \"x\", \"content\": \"%s\"}}\n"
                        (make-string 200 ?x)))
        (insert (format "{\"type\": \"ai-title\", \"aiTitle\": \"turn %d\"}\n" n))))
    file))

(ert-deftest ecc-history-test-long-recording-reads-one-page ()
  "A recording of 200 turns costs one page, not the whole file.
The threshold is deliberately loose: what matters is that the cost
follows the page and not the file."
  (ecc-test-with-fake-session session
    (let ((file (ecc-history-test--big-file 200)))
      (unwind-protect
          (let ((elapsed (car (benchmark-run 1
                                (ecc-history-load session 50 file)))))
            (should (= 50 (length (ecc-session-turns session))))
            (should (equal "prompt 150"
                           (ecc-turn-prompt (car (ecc-session-turns session)))))
            (should (equal "prompt 199"
                           (ecc-turn-prompt (car (last (ecc-session-turns session))))))
            (should (ecc-history-more-p session))
            (should (< elapsed 5.0)))
        (delete-file file)))))

(defun ecc-history-test--line (uuid parent role text &optional extra)
  "Return a recorded LINE with UUID hanging off PARENT.
ROLE is `user' or `assistant', TEXT what was said, EXTRA more JSON
fields as a string."
  (format "{\"type\": \"%s\", \"uuid\": \"%s\", \"parentUuid\": %s,%s\
 \"message\": {\"role\": \"%s\", \"content\": \"%s\"}}"
          role uuid (if parent (format "\"%s\"" parent) "null")
          (or extra "") role text))

(defun ecc-history-test--last-prompt (leaf)
  "Return the recorded line saying the conversation hangs from LEAF."
  (format "{\"type\": \"last-prompt\", \"leafUuid\": \"%s\"}" leaf))

;;;; Branches

(ert-deftest ecc-history-test-no-branch-shows-everything ()
  "A recording written by one process end to end has nothing to drop."
  (should-not (ecc-history-abandoned
               (ecc-history-lines ecc-history-test-file)))
  ;; Without a last-prompt line there is nothing to follow, so the lines
  ;; are taken in the order they were written.
  (should-not (ecc-history-abandoned
               (list (ecc-history-test--line "u1" nil "user" "one")
                     (ecc-history-test--line "a1" "u1" "assistant" "two")))))

(ert-deftest ecc-history-test-abandoned-branch-is-dropped ()
  "The branch nobody continued is left out.
Two processes resuming the same session, and editing an earlier message
in the interactive CLI, both hang a second reply off one parent; only
the one the recording last pointed at is the conversation."
  (let* ((lines (list (ecc-history-test--line "u1" nil "user" "one")
                      (ecc-history-test--line "a1" "u1" "assistant" "first")
                      ;; two turns hanging off the same answer
                      (ecc-history-test--line "u2" "a1" "user" "left")
                      (ecc-history-test--line "a2" "u2" "assistant" "left reply")
                      (ecc-history-test--line "u3" "a1" "user" "right")
                      (ecc-history-test--line "a3" "u3" "assistant" "right reply")
                      (ecc-history-test--last-prompt "a2")
                      (ecc-history-test--last-prompt "a3")))
         (abandoned (ecc-history-abandoned lines)))
    ;; The last last-prompt names a3, so the left branch is the old one.
    (should abandoned)
    (should (gethash "u2" abandoned))
    (should (gethash "a2" abandoned))
    (should-not (gethash "u3" abandoned))
    (should-not (gethash "u1" abandoned))
    ;; Only the turns of the current branch are counted and replayed.
    (should (equal '(0 4) (ecc-history-turn-starts lines abandoned)))
    (should (equal '(0 2 4) (ecc-history-turn-starts lines)))
    (ecc-test-with-fake-session session
      (ecc-history--replay session lines abandoned)
      (should (equal '("one" "right")
                     (ecc-history-test--prompts session))))))

(ert-deftest ecc-history-test-earlier-tree-is-kept ()
  "History before a compaction is another tree, not an abandoned branch.
A compaction starts a fresh root, so following the current branch back
would otherwise hide everything said before it."
  (let* ((lines (list (ecc-history-test--line "u1" nil "user" "before")
                      (ecc-history-test--line "a1" "u1" "assistant" "before reply")
                      ;; the compaction starts again from no parent
                      (ecc-history-test--line "u2" nil "user" "after")
                      (ecc-history-test--line "a2" "u2" "assistant" "after reply")
                      ;; and one abandoned retry of the new tree
                      (ecc-history-test--line "u3" "a2" "user" "dropped")
                      (ecc-history-test--line "u4" "a2" "user" "kept")
                      (ecc-history-test--last-prompt "u4")))
         (abandoned (ecc-history-abandoned lines)))
    (should abandoned)
    (should (gethash "u3" abandoned))
    (should-not (gethash "u1" abandoned))
    (should-not (gethash "a1" abandoned))
    (ecc-test-with-fake-session session
      (ecc-history--replay session lines abandoned)
      (should (equal '("before" "after" "kept")
                     (ecc-history-test--prompts session))))))

(ert-deftest ecc-history-test-branch-of-a-page ()
  "The branch worked out when the recording is opened is used for every page."
  (let ((lines (list (ecc-history-test--line "u1" nil "user" "one")
                     (ecc-history-test--line "a1" "u1" "assistant" "1")
                     (ecc-history-test--line "u2" "a1" "user" "two")
                     (ecc-history-test--line "a2" "u2" "assistant" "2")
                     (ecc-history-test--line "u3" "a1" "user" "gone")
                     (ecc-history-test--last-prompt "a2"))))
    (ecc-test-with-fake-session session
      (let ((file (make-temp-file "ecc-history-branch" nil ".jsonl"
                                  (concat (string-join lines "\n") "\n"))))
        (unwind-protect
            (progn
              (should (= 1 (ecc-history-load session 1 file)))
              (should (equal '("two") (ecc-history-test--prompts session)))
              (should (ecc-history-more-p session))
              ;; The older page skips the abandoned turn without reading
              ;; the branch again.
              (should (= 1 (ecc-history-load-more session 5)))
              (should (equal '("one" "two") (ecc-history-test--prompts session))))
          (delete-file file))))))

;;;; Describing a recording without reading it

(ert-deftest ecc-history-test-edges-read-both-ends ()
  "Only the two ends of a long recording are read."
  (let* ((middle (make-string 400 ?x))
         (file (make-temp-file "ecc-history-edges" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"type\": \"first\"}\n")
            (dotimes (n 400)
              (insert (format "{\"type\": \"filler\", \"n\": %d, \"pad\": \"%s\"}\n"
                              n middle)))
            (insert "{\"type\": \"last\"}\n"))
          (let* ((ecc-history-scan-head-bytes 200)
                 (ecc-history-scan-tail-bytes 200)
                 (edges (ecc-history--edges file)))
            ;; Both ends are there and whole; the middle is not.
            (should (string-search "\"first\"" (car edges)))
            (should (string-search "\"last\"" (car (last edges))))
            (should (< (length edges) 10))
            (dolist (line edges)
              (should (ecc--json-read line)))))
      (delete-file file))))

(ert-deftest ecc-history-test-edges-of-a-short-file ()
  "A recording smaller than the two ranges is read whole."
  (let ((ecc-history-scan-head-bytes 65536)
        (ecc-history-scan-tail-bytes 65536))
    (should (equal (ecc-history-lines ecc-history-test-file)
                   (ecc-history--edges ecc-history-test-file)))))

;;;; Finding and describing the files

(ert-deftest ecc-history-test-project-directory ()
  "The directory of a recording is the path with slashes and dots dashed."
  (should (equal "-Users-jun-Projects-SideProjects-emacs-claude-code"
                 (ecc-history-project-directory
                  "/Users/jun/Projects/SideProjects/emacs-claude-code/")))
  (should (equal "-Users-jun--emacs-d"
                 (ecc-history-project-directory "/Users/jun/.emacs.d")))
  ;; An underscore is not a letter, a digit or a dash either.
  (should (equal "-Users-jun-my-project-v1-2"
                 (ecc-history-project-directory "/Users/jun/my_project/v1.2")))
  ;; The CLI records the resolved path: on macOS a session started in
  ;; /var/folders is written under /private/var/folders.
  (let* ((directory (make-temp-file "ecc-history-link" t))
         (resolved (directory-file-name (file-truename directory))))
    (unwind-protect
        (progn
          (should (equal (replace-regexp-in-string "[^A-Za-z0-9-]" "-" resolved)
                         (ecc-history-project-directory directory)))
          (should-not (equal (ecc-history-project-directory directory)
                             (replace-regexp-in-string
                              "[^A-Za-z0-9-]" "-"
                              (directory-file-name directory)))))
      (delete-directory directory t))))

(ert-deftest ecc-history-test-recordings-are-newest-first ()
  "The recordings of a project are offered most recently used first."
  (ecc-history-test--with-directory file
    (let ((second (expand-file-name "11111111-1111-1111-1111-111111111111.jsonl"
                                    (file-name-directory file))))
      (copy-file file second)
      ;; The scan reads the time out of the recording, so both carry the
      ;; same one; the older file is made older on disk as well.
      (set-file-times second (time-subtract (current-time) 86400))
      (let* ((cwd (alist-get 'cwd (ecc-history-scan-file file)))
             (infos (ecc-history-recordings cwd)))
        (should (= 2 (length infos)))
        (should (equal cwd (alist-get 'cwd (car infos))))
        ;; A project nothing ran in has none.
        (should-not (ecc-history-recordings
                     (expand-file-name "ecc-no-such-project"
                                       temporary-file-directory)))
        ;; Without a project every recording is offered.
        (should (= 2 (length (ecc-history-recordings))))))))

(ert-deftest ecc-history-test-files-and-lookup ()
  "The recordings are found one level down, and one of them by session id."
  (ecc-history-test--with-directory file
    (should (equal (list file) (ecc-history-files)))
    (should (equal file
                   (ecc-history-file "24a1aa86-d53f-4457-b09e-4f4caf450f03")))
    (should-not (ecc-history-file "no-such-session"))))

(ert-deftest ecc-history-test-scan-file ()
  "A few lines of a recording say where it ran and how it ended.
The id is the name of the file, which is what --resume takes, and not
what the lines call the session: a copied recording keeps the old name
inside it."
  (let ((info (ecc-history-scan-file ecc-history-test-file)))
    (should (equal (file-name-base ecc-history-test-file)
                   (alist-get 'session-id info)))
    (should (string-suffix-p "ecc-history-2m0x5w0z" (alist-get 'cwd info)))
    (should (equal "Hello" (alist-get 'title info)))
    (should (equal (car (last ecc-history-test-prompts))
                   (alist-get 'prompt info)))
    (should (alist-get 'time info))))

(ert-deftest ecc-history-test-open-makes-an-archived-session ()
  "Opening a recording makes a session that shows it and can be resumed."
  (ecc-history-test--with-directory _file
    (let ((ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-render-debounce 0)
          (ecc-window-use-side-window nil))
      (let ((session (cl-letf (((symbol-function 'ecc-display-session) #'ignore))
                       (ecc-history-open "24a1aa86-d53f-4457-b09e-4f4caf450f03"))))
        (unwind-protect
            (progn
              (should (eq 'archived (ecc-session-kind session)))
              (should (eq 'exited (ecc-session-state session)))
              (should (equal ecc-history-test-prompts
                             (ecc-history-test--prompts session)))
              (should (string-search "hi.txt"
                                     (ecc-test-buffer-string
                                      (ecc-session-buffer session))))
              ;; Opening it again shows the same session, read once.
              (should (eq session
                          (cl-letf (((symbol-function 'ecc-display-session) #'ignore))
                            (ecc-history-open
                             "24a1aa86-d53f-4457-b09e-4f4caf450f03"))))
              (should (= 3 (length (ecc-session-turns session)))))
          (ecc-test-cleanup-session session))))))

;;;; Resuming

(ert-deftest ecc-history-test-resume-appends-to-what-was-read ()
  "Resuming reads the recording first and then starts the CLI on it."
  (ecc-history-test--with-directory _file
    (let ((ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-render-debounce 0)
          (started nil))
      (let ((session (ecc-history-session "24a1aa86-d53f-4457-b09e-4f4caf450f03")))
        (unwind-protect
            (cl-letf (((symbol-function 'ecc-proc-start)
                       (lambda (session &optional resume fork)
                         (setq started (list session resume fork)))))
              (ecc-history-resume session t)
              (should (equal (list session t t) started))
              ;; The turns are there before the stream adds anything.
              (should (equal ecc-history-test-prompts
                             (ecc-history-test--prompts session)))
              ;; It is this Emacs's session from now on.
              (should (eq 'own (ecc-session-kind session))))
          (ecc-test-cleanup-session session))))))

(ert-deftest ecc-history-test-offer-resume-after-a-crash ()
  "An exit nobody asked for offers a resume; a stop from Emacs does not."
  (ecc-history-test--with-directory _file
    (let ((ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (offers nil))
      (let ((session (ecc-history-session "24a1aa86-d53f-4457-b09e-4f4caf450f03")))
        (unwind-protect
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_time _repeat function &rest args)
                         (push (apply #'list function args) offers))))
              ;; A clean exit says nothing.
              (ecc--offer-resume session 0)
              (should-not offers)
              ;; A crash offers to resume, once Emacs is out of the sentinel.
              (ecc--offer-resume session 1)
              (should (equal (list #'ecc-offer-resume-now session 1) (car offers)))
              ;; The offer is always made; the way to be rid of it is to
              ;; take it off the hook (decided 2026-09-10).
              (should (memq #'ecc--offer-resume ecc-session-exited-hook))
              (setq offers nil)
              ;; A stop the user asked for is not a crash, whatever the
              ;; status the signal left behind.
              (ecc-proc-stop session)
              (should (ecc-proc-stopped-on-request-p session))
              (ecc--offer-resume session 9)
              (should-not offers))
          (ecc-test-cleanup-session session))))))

(ert-deftest ecc-history-test-starting-clears-the-stop-flag ()
  "Starting the CLI again means the next exit is a crash once more."
  (ecc-test-with-fake-session session
    (ecc-proc-stop session)
    (should (ecc-proc-stopped-on-request-p session))
    (let ((spawn (symbol-function 'make-process)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _)
                   (funcall spawn :name "ecc-test-sleep"
                            :command '("sleep" "30") :noquery t)))
                ((symbol-function 'ecc-proc-control) #'ignore))
        (let ((process (ecc-proc-start session)))
          (unwind-protect
              (should-not (ecc-proc-stopped-on-request-p session))
            (delete-process process)))))))

(ert-deftest ecc-history-test-resume-refuses-a-live-process ()
  "A session whose CLI is still running is never resumed a second time."
  (ecc-test-with-fake-session session
    (let ((process (start-process "ecc-history-test" nil "sleep" "30")))
      (unwind-protect
          (progn
            (setf (ecc-session-process session) process)
            (should-error (ecc-history-resume session) :type 'user-error))
        (delete-process process)))))

(ert-deftest ecc-history-test-local-commands ()
  "The record of a slash command is read as a command, not as a turn.
The recording is the one of the phase 9 screenshots: three prompts, and
six local commands (/advisor, /color four times and /recap) that the CLI
answered itself."
  (ecc-test-with-fake-session session
    (let ((file (ecc-test-history-fixture "local-commands")))
      (should (= 3 (ecc-history-load session nil file)))
      (should (equal '("`ecc-core.el` L20-L30 このフォームは何してる？" "続けて" "もう少し何か書いて")
                     (mapcar (lambda (turn)
                               (car (split-string (ecc-turn-prompt turn) "\n")))
                             (ecc-session-turns session))))
      (let* ((nodes (hash-table-values (ecc-session-nodes session)))
             (commands (seq-filter (lambda (node) (eq (ecc-node-type node) 'command))
                                   nodes)))
        (should (equal '("/advisor" "/color" "/color" "/color" "/color" "/recap")
                       (sort (mapcar (lambda (node) (ecc-model-node-get node 'name))
                                     commands)
                             #'string<)))
        ;; What the command printed is on the node it belongs to.
        (should (equal (ecc-model-node-get
                        (seq-find (lambda (node)
                                    (equal (ecc-model-node-get node 'name) "/advisor"))
                                  commands)
                        'output)
                       "Advisor: off\nUsage: /advisor <fable|opus|sonnet|off>"))
        ;; Nothing of the record is left over as a note or as unknown.
        (should-not (seq-some (lambda (node)
                                (eq (ecc-node-type node) 'unknown))
                              nodes)))
      (ecc-session-ensure-buffer session)
      (ecc-render-flush session)
      (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
        (should (string-search "〉 /advisor" text))
        (should (string-search "〉 /color red" text))
        (should (string-search "  Advisor: off" text))
        ;; The caveat is written for the model and is not shown.
        (should-not (string-search "local-command-caveat" text))
        (should-not (string-search "<command-name>" text))
        (should-not (string-search "local-command-stdout" text))))))

(provide 'ecc-history-test)

;;; ecc-history-test.el ends here
