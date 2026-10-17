;;; ecc-visit-test.el --- Tests for opening the source from the transcript  -*- lexical-binding: t; -*-

;;; Commentary:

;; What RET on the transcript opens: a line of a diff, the heading of a
;; call that names a file, a line of the Files section or of a
;; permission request, and a path the model wrote.  A click opens the
;; path and none of the others.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)
(require 'ecc-session)
(require 'ecc-perm)
(require 'ecc-prompt)
(require 'ecc-visit)

(defun ecc-visit-test--replay-edit (session)
  "Replay the edit-tool fixture into SESSION, allowing its request.
Return the path the recorded Edit changed."
  (ecc-session-ensure-buffer session)
  (ecc-model-begin-turn session "greet を直して")
  (dolist (line (ecc-test-fixture-lines "edit-tool"))
    (let ((message (ecc-protocol-parse-line line)))
      (ecc-dispatch session message)
      (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
        (ecc-perm-respond (car (ecc-session-pending session)) 'allow))))
  (ecc-render-flush session)
  (ecc-file-entry-path (car (ecc-model-files session))))

(defun ecc-visit-test--target-after (anchor text)
  "Return the target of the first line holding TEXT after ANCHOR."
  (goto-char (point-min))
  (should (search-forward anchor nil t))
  (should (search-forward text nil t))
  (ecc-visit-target-at-point))

(defmacro ecc-visit-test--with-edit (vars &rest body)
  "Run BODY in the transcript of the replayed edit-tool fixture.
VARS is (SESSION PATH)."
  (declare (indent 1))
  `(ecc-test-with-fake-session ,(car vars)
     (let ((,(cadr vars) (ecc-visit-test--replay-edit ,(car vars))))
       (with-current-buffer (ecc-session-buffer ,(car vars))
         ,@body))))

(defun ecc-visit-test--patch (old-start old-lines new-start new-lines &rest lines)
  "Return a structuredPatch of one hunk with the given counts and LINES."
  (vector `((oldStart . ,old-start) (oldLines . ,old-lines)
            (newStart . ,new-start) (newLines . ,new-lines)
            (lines . ,(vconcat lines)))))

;;;; Diff lines of a call

(ert-deftest ecc-visit-test-numbered-diff-lines ()
  "Each line of a numbered diff opens the file at its line in the new file.
The removed line is numbered in the old file, and stands where it was
taken out."
  (ecc-visit-test--with-edit (session path)
    (should (equal (ecc-visit-test--target-after "✓ Edit" "+    return \"hello")
                   (cons path 3)))
    (should (equal (ecc-visit-test--target-after "✓ Edit" "-    return \"hi")
                   (cons path 3)))
    (should (equal (ecc-visit-test--target-after "✓ Edit" "def greet")
                   (cons path 1)))
    (should (equal (ecc-visit-test--target-after "✓ Edit" "def farewell")
                   (cons path 6)))
    ;; The line that counts the diff and the result are not the diff.
    (should-not (ecc-visit-test--target-after "✓ Edit" "Added 1 line"))
    (should-not (ecc-visit-test--target-after "✓ Edit" "has been updated"))))

(ert-deftest ecc-visit-test-unified-diff-lines ()
  "In the unified style the line is counted from the @@ header above it."
  (let ((ecc-diff-style 'unified))
    (ecc-visit-test--with-edit (session path)
      (should (string-search "@@ -1,6 +1,6 @@" (ecc-test-buffer-string)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" "@@ -1,6")
                     (cons path 1)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" " def greet")
                     (cons path 1)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" "-    return \"hi")
                     (cons path 3)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" "+    return \"hello")
                     (cons path 3)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" " def farewell")
                     (cons path 6))))))

(ert-deftest ecc-visit-test-removed-lines-map-to-the-new-file ()
  "A removed line opens after the line above it that is still there.
With nothing kept above it in the hunk, before the line below; and a
line of a later hunk is not taken for one of this one."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "edit")
    (let ((patch (vconcat
                  (ecc-visit-test--patch 10 4 10 3 " a" "-b" "-c" "+B" " d")
                  (ecc-visit-test--patch 40 2 39 1 "-x" " y"))))
      (ecc-model-node-changed
       session
       (ecc-model-add-node session :type 'tool :status 'done
                           :data `((name . "Edit")
                                   (input . ((file_path . "/src/f.el")
                                             (old_string . "b\nc")
                                             (new_string . "B")))
                                   (patch . ,patch)
                                   (result . "ok")))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (should (equal (ecc-visit-test--target-after "✓ Edit" "-b")
                     '("/src/f.el" . 11)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" "-c")
                     '("/src/f.el" . 11)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" "+B")
                     '("/src/f.el" . 11)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" " d")
                     '("/src/f.el" . 12)))
      ;; The second hunk opens on a removal: the line below says where.
      (should (equal (ecc-visit-test--target-after "✓ Edit" "-x")
                     '("/src/f.el" . 39))))))

;;;; What a Bash command changed

(ert-deftest ecc-visit-test-bash-edit-diff ()
  "A line of what a Bash call changed opens the file it is under.
The call names no file; the line over each block does.  That line opens
the file where its change starts, and a later change to the file moves
the lines, as it does for an Edit."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "bash")
    (dolist (line (ecc-test-fixture-lines "bash-edit-diff"))
      (let ((message (ecc-protocol-parse-line line)))
        (ecc-dispatch session message)
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          (ecc-perm-respond (car (ecc-session-pending session)) 'allow))))
    (ecc-render-flush session)
    (let* ((dir "/private/tmp/ecc-fixture/sandbox/")
           (a (concat dir "a.txt")))
      (with-current-buffer (ecc-session-buffer session)
        (should (equal (ecc-visit-test--target-after "✓ Bash" "+line TWO")
                       (cons a 2)))
        (should (equal (ecc-visit-test--target-after "✓ Bash" " line four")
                       (cons a 4)))
        (should (equal (ecc-visit-test--target-after "✓ Bash" "-bee")
                       (cons (concat dir "b.txt") 1)))
        (should (equal (ecc-visit-test--target-after "✓ Bash" "Updated ")
                       (cons a 2)))
        ;; A click opens nothing, so nothing lights up under the pointer.
        (goto-char (point-min))
        (search-forward "Updated ")
        (should-not (text-property-not-all (point) (line-end-position)
                                           'mouse-face nil))
        (should (equal (ecc-visit-test--target-after "✓ Bash" "Created ")
                       (cons (concat dir "new.txt") 1)))
        ;; A block after the first is the file it is under.
        (should (equal (ecc-visit-test--target-after "m3.txt (+1 -1)" "+new")
                       (cons (concat dir "m3.txt") 2)))
        ;; The description over the diff is not the diff.
        (should-not (ecc-visit-test--target-after "✓ Bash" "description: Run"))
        (should-not (ecc-visit-test--target-after "✓ Bash" "… 3 more files"))
        ;; Two lines put in at the top later push the change down.
        (ecc-model-note-hunk session a nil nil
                             (ecc-visit-test--patch 1 1 1 3 "+x" "+y" " line one"))
        (should (equal (ecc-visit-test--target-after "✓ Bash" "+line TWO")
                       (cons a 4)))
        (should (equal (ecc-visit-test--target-after "✓ Bash" "Updated ")
                       (cons a 4)))))))

;;;; Headings

(ert-deftest ecc-visit-test-headings ()
  "The heading of an Edit opens its first changed line; a Read opens at the top.
Neither the heading nor its body carries a `mouse-face': a click opens
nothing, so nothing lights up under the pointer."
  (ecc-visit-test--with-edit (session path)
    (goto-char (point-min))
    (search-forward "✓ Edit")
    (should (equal (ecc-visit-target-at-point) (cons path 3)))
    (should-not (text-property-not-all (line-beginning-position)
                                       (line-end-position) 'mouse-face nil))
    (forward-line 1)
    (should-not (get-text-property (point) 'mouse-face))
    (goto-char (point-min))
    (search-forward "✓ Read")
    (should (equal (ecc-visit-target-at-point) (list path)))
    ;; The Read's result is its body: not a diff, and not the heading.
    (should-not (ecc-visit-test--target-after "✓ Read" "Say bye"))))

(ert-deftest ecc-visit-test-read-offset-and-other-headings ()
  "A Read opens at its offset; a call with no file has nothing to open."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "read")
    (dolist (data '(((name . "Read")
                     (input . ((file_path . "/src/long.el") (offset . 40) (limit . 20)))
                     (result . "text"))
                    ((name . "Bash")
                     (input . ((command . "ls /src/x.el")))
                     (result . "x.el"))))
      (ecc-model-node-changed
       session (ecc-model-add-node session :type 'tool :status 'done :data data)))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (search-forward "✓ Read")
      (should (equal (ecc-visit-target-at-point) '("/src/long.el" . 40)))
      (search-forward "✓ Bash")
      (should-not (ecc-visit-target-at-point))
      (should-not (get-text-property (point) 'mouse-face)))))

(ert-deftest ecc-visit-test-ret-on-headings ()
  "RET on a heading that names a file opens it; on any other it lays the node open.
The node laid open is `o' everywhere."
  (ecc-visit-test--with-edit (session path)
    (let (opened shown)
      (cl-letf (((symbol-function 'ecc-visit-open)
                 (lambda (file line &rest _) (setq opened (cons file line))))
                ((symbol-function 'ecc-session--show-node)
                 (lambda (_session node) (setq shown (ecc-node-type node)))))
        (goto-char (point-min))
        (search-forward "✓ Edit")
        (should (eq (key-binding (kbd "o")) #'ecc-session-show-detail))
        (ecc-session-visit)
        (should (equal opened (cons path 3)))
        (should-not shown)
        (ecc-session-show-detail)
        (should (eq shown 'tool))
        ;; The permission's heading keeps showing the node.
        (setq opened nil shown nil)
        (search-forward "Permission: Edit")
        (ecc-session-visit)
        (should-not opened)
        (should (eq shown 'permission))))))

(ert-deftest ecc-visit-test-change-headings-without-a-patch ()
  "A change with no patch to read opens at the line it changed all the same.
A Write of a new file opens at line 1 and one over a file at its first
different line; a MultiEdit at the first of its edits in the file."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "write")
    (dolist (data '(((name . "Write")
                     (input . ((file_path . "/src/new.py") (content . "x\n")))
                     (patch . [])
                     (result . "created"))
                    ((name . "Write")
                     (input . ((file_path . "/src/old.py")
                               (content . "a\nb\nC\nd\n")))
                     (before . "a\nb\nc\nd\n")
                     (result . "updated"))
                    ((name . "MultiEdit")
                     (input . ((file_path . "/src/multi.py")
                               (edits . [((old_string . "d") (new_string . "D"))
                                         ((old_string . "b") (new_string . "B"))])))
                     (result . "updated"))))
      (ecc-model-node-changed
       session (ecc-model-add-node session :type 'tool :status 'done :data data)))
    (ecc-render-flush session)
    ;; A MultiEdit whose first edit only deletes, with the file before
    ;; it known: the deletion is where it opens, not the later edit.
    (ecc-model-node-changed
     session
     (ecc-model-add-node session :type 'tool :status 'done
                         :data '((name . "MultiEdit")
                                 (input . ((file_path . "/src/cut.py")
                                           (edits . [((old_string . "b\n") (new_string . ""))
                                                     ((old_string . "d") (new_string . "D"))])))
                                 (before . "a\nb\nc\nd\n")
                                 (result . "updated"))))
    (ecc-render-flush session)
    (cl-letf (((symbol-function #'ecc-diff-file-content)
               (lambda (path) (and (equal path "/src/multi.py") "a\nB\nc\nD\n"))))
      (with-current-buffer (ecc-session-buffer session)
        (goto-char (point-min))
        (search-forward "new.py")
        (should (equal (ecc-visit-target-at-point) '("/src/new.py" . 1)))
        (search-forward "old.py")
        (should (equal (ecc-visit-target-at-point) '("/src/old.py" . 3)))
        (search-forward "multi.py")
        (should (equal (ecc-visit-target-at-point) '("/src/multi.py" . 2)))
        (search-forward "cut.py")
        (should (equal (ecc-visit-target-at-point) '("/src/cut.py" . 2)))))))

(ert-deftest ecc-visit-test-numbered-diff-after-a-style-change ()
  "A numbered diff is read as one after `ecc-diff-style' is set to `unified'.
The style is read from the text drawn, not from the setting."
  (ecc-visit-test--with-edit (session path)
    (let ((ecc-diff-style 'unified))
      (should (equal (ecc-visit-test--target-after "✓ Edit" "+    return \"hello")
                     (cons path 3)))
      (should (equal (ecc-visit-test--target-after "✓ Edit" "def farewell")
                     (cons path 6))))))

(ert-deftest ecc-visit-test-first-difference ()
  "The first different line counts the lines the way the diff does.
A final newline does not make a line of its own, so a blank line added
at the end is found where it is."
  (should (equal (ecc-visit--first-difference nil "x\n") 1))
  (should (equal (ecc-visit--first-difference "a\nb\n" "a\nB\n") 2))
  (should (equal (ecc-visit--first-difference "" "\n") 1))
  (should (equal (ecc-visit--first-difference "a\n" "a\n\n") 2))
  (should (equal (ecc-visit--first-difference "a\nb\n" "a\n") 2))
  (should-not (ecc-visit--first-difference "a\n" "a\n")))

;;;; Where the file stands now

(ert-deftest ecc-visit-test-shift-line ()
  "A line moves through the hunks of every change made after its own."
  (ecc-test-with-fake-session session
    (let ((first (ecc-visit-test--patch 10 1 10 1 "-a" "+A"))
          (second (vconcat (ecc-visit-test--patch 1 3 1 5 " x" "+n" "+m" " y" " z")
                           (ecc-visit-test--patch 50 2 52 1 "-p" " q")))
          (third (ecc-visit-test--patch 30 1 30 0 "-gone")))
      (ecc-model-note-file session "/src/f.el" 'edit)
      (dolist (patch (list first second third))
        (ecc-model-note-hunk session "/src/f.el" "old" "new" patch))
      ;; Two lines added above it, the hunk at 50 below it, and a line
      ;; taken out below it by the third.
      (should (= (ecc-visit-shift-line session "/src/f.el" 10 first) 12))
      ;; Below every hunk: +2, -1 and -1.
      (should (= (ecc-visit-shift-line session "/src/f.el" 60 first) 60))
      ;; The last change has nothing after it.
      (should (= (ecc-visit-shift-line session "/src/f.el" 10 third) 10))
      ;; A patch the session did not record moves nothing.
      (should (= (ecc-visit-shift-line session "/src/f.el" 10 (vconcat first)) 10))
      (should (= (ecc-visit-shift-line session "/src/f.el" 10 nil) 10)))))

(ert-deftest ecc-visit-test-diff-line-follows-later-changes ()
  "The diff of an earlier Edit opens where its line is after a later one."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "edit twice")
    (let ((first (ecc-visit-test--patch 20 1 20 1 "-old" "+new"))
          (second (ecc-visit-test--patch 1 1 1 4 " top" "+one" "+two" "+three")))
      (ecc-model-note-file session "/src/f.el" 'edit)
      (dolist (patch (list first second))
        (ecc-model-note-hunk session "/src/f.el" "old" "new" patch)
        (ecc-model-node-changed
         session
         (ecc-model-add-node session :type 'tool :status 'done
                             :data `((name . "Edit")
                                     (input . ((file_path . "/src/f.el")
                                               (old_string . "x")
                                               (new_string . "y")))
                                     (patch . ,patch)
                                     (result . "ok"))))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (should (equal (ecc-visit-test--target-after "✓ Edit" "+new")
                     '("/src/f.el" . 23)))
      (goto-char (point-min))
      (search-forward "✓ Edit")
      (should (equal (ecc-visit-target-at-point) '("/src/f.el" . 23)))
      ;; The Files section draws both changes one after the other.
      (ecc-render-goto-id "file:/src/f.el")
      (should (equal (ecc-visit-target-at-point) '("/src/f.el")))
      (search-forward "+new")
      (should (equal (ecc-visit-target-at-point) '("/src/f.el" . 23)))
      (search-forward "+two")
      (should (equal (ecc-visit-target-at-point) '("/src/f.el" . 3))))))

;;;; The Files section and permissions

(ert-deftest ecc-visit-test-files-section-and-permission ()
  "A line of the Files section and of a permission request opens the file too."
  (ecc-visit-test--with-edit (session path)
    (ecc-render-goto-id (concat "file:" path))
    (should (equal (ecc-visit-target-at-point) (list path)))
    (should (equal (ecc-visit-test--target-after "Files (1)" "+    return \"hello")
                   (cons path 3)))
    (should (equal (ecc-visit-test--target-after "Files (1)" "def farewell")
                   (cons path 6)))
    (should (equal (ecc-visit-test--target-after "Permission: Edit"
                                                 "-    return \"hi")
                   (cons path 3)))
    (should (equal (ecc-visit-test--target-after "Permission: Edit" "def farewell")
                   (cons path 6)))))

;;;; Clicks

(defun ecc-visit-test--click (pos)
  "Click mouse-2 at POS in the current buffer, shown in the selected window."
  (set-window-buffer (selected-window) (current-buffer))
  (ecc-chat-follow-link (list 'mouse-2 (list (selected-window) pos '(0 . 0) 0))))

(ert-deftest ecc-visit-test-a-click-opens-nothing ()
  "A click on a diff line or a heading opens nothing; RET on the same place does.
`follow-link' says no, so mouse-1 stays a click, and mouse-2 moves the
point and stops there."
  (ecc-visit-test--with-edit (session path)
    (let (opened)
      (cl-letf (((symbol-function 'ecc-visit-open)
                 (lambda (file line &rest _) (push (cons file line) opened)))
                ((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url opened))))
        (goto-char (point-min))
        (dolist (text '("✓ Edit" "+    return \"hello" "has been updated"))
          (search-forward text)
          (let ((pos (1- (point))))
            (should-not (get-char-property pos 'mouse-face))
            (goto-char (point-min))
            (ecc-visit-test--click pos)
            (should (= (point) pos))))
        (should-not opened)
        (goto-char (point-min))
        (search-forward "+    return \"hello")
        (ecc-session-visit)
        (should (equal opened (list (cons path 3))))))))

;;;; Paths in the reply

(ert-deftest ecc-visit-test-paths-in-prose ()
  "A path the model wrote opens against the directory of the session."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "where")
    (ecc-model-node-changed
     session
     (ecc-model-add-node
      session :type 'text :status 'done
      :data '((text . "It is in `ecc-session.el:163`, see also lisp/a/b.el.\n\n```\nnot/this/one.el\n```\n"))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      ;; The buffer stands in a directory of its own, which holds the
      ;; file named first.
      (let ((root (file-name-as-directory (make-temp-file "ecc-visit-prose" t))))
        (setq default-directory root)
        (write-region "" nil (expand-file-name "ecc-session.el" root) nil 'silent)
        (unwind-protect
            (progn
              (goto-char (point-min))
              (search-forward "ecc-session")
              (should (equal (ecc-visit-target-at-point)
                             (cons (expand-file-name "ecc-session.el" root) 163)))
              ;; Drawn as a link, so a click opens it as well as RET.
              (should (get-text-property (point) 'mouse-face))
              (search-forward "lisp/a")
              (should (equal (ecc-visit-target-at-point)
                             (list (expand-file-name "lisp/a/b.el" root))))
              (search-forward "not/this")
              (should-not (ecc-visit-target-at-point))
              (let (opened)
                (cl-letf (((symbol-function 'ecc-visit-open)
                           (lambda (file line &rest _) (setq opened (cons file line)))))
                  (goto-char (point-min))
                  (search-forward "ecc-session")
                  (ecc-session-visit)
                  (should (equal opened (cons (expand-file-name "ecc-session.el" root)
                                              163)))
                  (setq opened nil)
                  (let ((pos (point)))
                    (goto-char (point-min))
                    (ecc-visit-test--click pos)))
                (should (equal opened (cons (expand-file-name "ecc-session.el" root)
                                            163)))))
          (delete-directory root t))))))

;;;; Finding a path the model wrote

(defmacro ecc-visit-test--with-tree (vars files &rest body)
  "Run BODY with a project of FILES in a fresh directory.
VARS is (SESSION ROOT): SESSION a session whose project root is ROOT.
FILES are relative to ROOT.  Nothing is asked and nothing outside ROOT
is searched unless BODY says so: the project's files are ROOT's own,
`y-or-n-p', `completing-read' and the machine search are errors.  The
buffers visiting the files are killed afterwards."
  (declare (indent 2))
  `(ecc-test-with-fake-session ,(car vars)
     (let* ((,(cadr vars) (file-name-as-directory
                           (make-temp-file "ecc-visit-tree" t)))
            (default-directory ,(cadr vars))
            (ecc-visit-search-machine 'ask)
            (ecc-visit-machine-search-function
             (lambda (name) (error "Searched the machine for %s" name))))
       (setf (ecc-session-project-root ,(car vars)) ,(cadr vars))
       (dolist (file ,files)
         (let ((path (expand-file-name file ,(cadr vars))))
           (make-directory (file-name-directory path) t)
           (write-region (format "%s\n2\n3\n4\n5\n" file) nil path nil 'silent)))
       (unwind-protect
           (cl-letf (((symbol-function 'ecc-prompt-project-files)
                      (let ((root ,(cadr vars)))
                        (lambda (_session)
                          (mapcar (lambda (file) (file-relative-name file root))
                                  (directory-files-recursively root "")))))
                     ((symbol-function 'y-or-n-p)
                      (lambda (prompt) (error "Asked: %s" prompt)))
                     ((symbol-function 'completing-read)
                      (lambda (prompt &rest _) (error "Asked: %s" prompt))))
             ,@body)
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (string-prefix-p ,(cadr vars) (buffer-file-name buffer)))
             (kill-buffer buffer)))
         (delete-directory ,(cadr vars) t)))))

(defmacro ecc-visit-test--choosing (var answer &rest body)
  "Run BODY with `completing-read' answering ANSWER, pushing what it offered.
VAR is bound to the list of candidate lists, the latest first."
  (declare (indent 2))
  `(let ((,var nil))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt collection &rest _)
                  (push (all-completions "" collection) ,var)
                  ,answer)))
       ,@body)))

(ert-deftest ecc-visit-test-suffix-rule ()
  "A name matches a path it ends on at a directory boundary, and no other."
  (should (ecc-visit--suffix-p "foo.el" "/a/foo.el"))
  (should-not (ecc-visit--suffix-p "foo.el" "/a/barfoo.el"))
  (should (ecc-visit--suffix-p "test/foo.el" "/a/test/foo.el"))
  (should-not (ecc-visit--suffix-p "test/foo.el" "/a/mytest/foo.el"))
  (should (equal (ecc-visit--written-suffix "./../test/foo.el") "test/foo.el"))
  (should-not (ecc-visit--written-suffix "/abs/foo.el"))
  (should-not (ecc-visit--written-suffix "~/foo.el"))
  (ecc-visit-test--with-tree (session root) '("lib/foo.el" "lib/barfoo.el"
                                              "test/foo-test.el" "other/test/x.el"
                                              "mytest/x.el")
    (should (equal (ecc-visit-find-written session "foo.el")
                   (cons (expand-file-name "lib/foo.el" root) 'project)))
    (should (equal (ecc-visit-find-written session "test/x.el")
                   (cons (expand-file-name "other/test/x.el" root) 'project)))))

(ert-deftest ecc-visit-test-written-as-it-stands ()
  "A path that is there as written opens without a search.
Against the session's directory first, then against the project root."
  (ecc-visit-test--with-tree (session root) '("src/a.el" "test/b.el")
    (cl-letf (((symbol-function 'ecc-prompt-project-files)
               (lambda (_) (error "Walked the project"))))
      (let ((src (expand-file-name "src/" root)))
        (should (equal (ecc-visit-find-written session "a.el" src)
                       (list (expand-file-name "a.el" src))))
        (should (equal (ecc-visit-find-written session "test/b.el" src)
                       (cons (expand-file-name "test/b.el" root) 'root)))))))

(ert-deftest ecc-visit-test-a-file-of-the-session-stops-the-search ()
  "A file the session handled, or one Emacs visits, is found without the project.
The project's files are never listed when either has it."
  (ecc-visit-test--with-tree (session root) '("deep/x/handled.el" "deep/y/open.el")
    (cl-letf (((symbol-function 'ecc-prompt-project-files)
               (lambda (_) (error "Walked the project"))))
      (ecc-model-note-file session (expand-file-name "deep/x/handled.el" root) 'read)
      (should (equal (ecc-visit-find-written session "handled.el")
                     (cons (expand-file-name "deep/x/handled.el" root) 'session)))
      (find-file-noselect (expand-file-name "deep/y/open.el" root))
      (should (equal (ecc-visit-find-written session "y/open.el")
                     (cons (expand-file-name "deep/y/open.el" root) 'buffer))))))

(defmacro ecc-visit-test--visiting-elsewhere (var file &rest body)
  "Run BODY with VAR bound to FILE in a fresh directory outside the tree, visited.
FILE is relative to that directory; the buffer and the directory go
afterwards."
  (declare (indent 2))
  `(let* ((other (file-name-as-directory (make-temp-file "ecc-visit-other" t)))
          (,var (expand-file-name ,file other)))
     (make-directory (file-name-directory ,var) t)
     (write-region "x\n" nil ,var nil 'silent)
     (let ((buffer (find-file-noselect ,var)))
       (unwind-protect
           (progn ,@body)
         (kill-buffer buffer)
         (delete-directory other t)))))

(ert-deftest ecc-visit-test-the-project-before-a-buffer-elsewhere ()
  "The project's file wins over the same name open in another checkout.
A worktree session that names a test file must not open the copy of
the main checkout the user has open."
  (ecc-visit-test--with-tree (session root) '("test/foo-test.el")
    (ecc-visit-test--visiting-elsewhere _elsewhere "test/foo-test.el"
      (should (equal (ecc-visit-find-written session "foo-test.el")
                     (cons (expand-file-name "test/foo-test.el" root) 'project))))))

(ert-deftest ecc-visit-test-a-buffer-elsewhere-when-the-project-has-none ()
  "A file Emacs visits outside the project is found when the project has no match.
It is found before the machine is asked about, and the echo area says
it is outside."
  (ecc-visit-test--with-tree (session _root) '("a.el")
    (ecc-visit-test--visiting-elsewhere elsewhere "notes/far.el"
      ;; `y-or-n-p' and the machine search are errors in the tree.
      (should (equal (ecc-visit-find-written session "far.el")
                     (cons elsewhere 'outside)))
      (let (said)
        (cl-letf (((symbol-function 'ecc-visit-open) #'ignore)
                  ((symbol-function 'message)
                   (lambda (format &rest args) (setq said (apply #'format format args)))))
          (remhash session ecc-visit--chosen)
          (ecc-visit-open-written session '("far.el" . 1))
          (should (string-suffix-p "(a file Emacs visits, outside the project)"
                                   said)))))))

(ert-deftest ecc-visit-test-a-file-of-the-project-does-not-ask ()
  "A file found in the project opens without a word about the machine."
  (ecc-visit-test--with-tree (session root) '("test/foo-test.el")
    ;; `y-or-n-p' and the machine search are errors in the tree.
    (should (equal (ecc-visit-find-written session "foo-test.el")
                   (cons (expand-file-name "test/foo-test.el" root) 'project)))))

(ert-deftest ecc-visit-test-the-project-as-project-el-sees-it ()
  "The project's files are the ones `project.el' lists, as @ completion has them."
  (let ((listed (symbol-function 'ecc-prompt-project-files)))
    (ecc-visit-test--with-tree (session root) '("test/foo-test.el")
      (let ((project-find-functions (list (lambda (_dir) (cons 'transient root)))))
        (cl-letf (((symbol-function 'ecc-prompt-project-files) listed))
          (should (equal (ecc-visit-find-written session "foo-test.el")
                         (cons (expand-file-name "test/foo-test.el" root)
                               'project))))))))

(ert-deftest ecc-visit-test-several-are-offered-in-order ()
  "Several matches go through `completing-read', shown against the root.
The files of the session first, then the nearest to the session's
directory, then the shortest."
  (ecc-visit-test--with-tree (session root) '("x/deep/foo.el" "src/a/b/foo.el"
                                              "lib/foo.el" "src/sub/foo.el")
    (let ((src (expand-file-name "src/" root)))
      (ecc-visit-test--choosing offered "src/sub/foo.el"
        (should (equal (ecc-visit-find-written session "foo.el" src)
                       (cons (expand-file-name "src/sub/foo.el" root) 'project)))
        (should (equal (car offered)
                       '("src/sub/foo.el" "lib/foo.el" "src/a/b/foo.el"
                         "x/deep/foo.el")))))
    ;; Among the files of the session and of Emacs, the session's come
    ;; first however far they are.
    (remhash session ecc-visit--chosen)
    (ecc-model-note-file session (expand-file-name "x/deep/foo.el" root) 'edit)
    (find-file-noselect (expand-file-name "src/sub/foo.el" root))
    (ecc-visit-test--choosing offered "x/deep/foo.el"
      (ecc-visit-find-written session "foo.el" (expand-file-name "src/" root))
      (should (equal (car offered) '("x/deep/foo.el" "src/sub/foo.el"))))))

(ert-deftest ecc-visit-test-outside-the-project-is-abbreviated ()
  "A file outside the project is shown from the home directory."
  (should (equal (ecc-visit--display-name (expand-file-name "x/foo.el" "~/") "/p/")
                 "~/x/foo.el"))
  (should (equal (ecc-visit--display-name "/p/a/foo.el" "/p/") "a/foo.el")))

(ert-deftest ecc-visit-test-opened-at-the-line-and-said-where ()
  "The line of the link is kept wherever the file was found, and the echo area says where."
  (ecc-visit-test--with-tree (session root) '("test/foo-test.el")
    (let (opened said)
      (cl-letf (((symbol-function 'ecc-visit-open)
                 (lambda (path line &rest _) (setq opened (cons path line))))
                ((symbol-function 'message)
                 (lambda (format &rest args) (setq said (apply #'format format args)))))
        (ecc-visit-open-written session '("foo-test.el" . 4))
        (should (equal opened (cons (expand-file-name "test/foo-test.el" root) 4)))
        (should (equal said "Opened test/foo-test.el (in the project)"))
        (setq said nil)
        (ecc-visit-open-written session '("test/foo-test.el" . 2))
        (should (equal opened (cons (expand-file-name "test/foo-test.el" root) 2)))
        (should-not said)))
    ;; And for real, at the line.
    (save-window-excursion
      (let ((window (ecc-visit-open-written session '("foo-test.el" . 3))))
        (should (= (line-number-at-pos (window-point window)) 3))))))

(ert-deftest ecc-visit-test-nothing-found-says-where-it-looked ()
  "No match is an error that names the places looked in."
  (ecc-visit-test--with-tree (session _root) '("a.el")
    (let ((ecc-visit-search-machine 'never))
      (let ((err (should-error (ecc-visit-find-written session "gone.el")
                               :type 'user-error)))
        (should (string-match-p "\\`No such file: gone.el (looked in .*project's files, the files open outside the project)\\'"
                                (cadr err)))))
    (let ((err (should-error (ecc-visit-find-written session "/no/such/gone.el")
                             :type 'user-error)))
      (should (string-match-p "No such file: /no/such/gone.el" (cadr err))))))

(ert-deftest ecc-visit-test-the-machine-is-searched-after-asking ()
  "Found nowhere nearer, the machine is searched -- after asking, by default.
What the search returns is filtered by the rule, and one match opens."
  (ecc-visit-test--with-tree (session root) '("a.el")
    (let* ((outside (file-name-as-directory (make-temp-file "ecc-visit-far" t)))
           (far (expand-file-name "lib/far.el" outside))
           asked searched)
      (unwind-protect
          (let ((ecc-visit-machine-search-function
                 (lambda (name)
                   (push name searched)
                   (list far (concat far "c")
                         (expand-file-name "lib/nearfar.el" outside)
                         (expand-file-name "gone/lib/far.el" outside)))))
            (make-directory (file-name-directory far) t)
            (dolist (file (list far (concat far "c")
                                (expand-file-name "lib/nearfar.el" outside)))
              (write-region "x\n" nil file nil 'silent))
            (cl-letf (((symbol-function 'y-or-n-p)
                       (lambda (prompt) (push prompt asked) nil)))
              (should-error (ecc-visit-find-written session "lib/far.el")
                            :type 'user-error)
              (should (equal asked '("Not in the project; search this machine? ")))
              (should-not searched))
            (cl-letf (((symbol-function 'y-or-n-p)
                       (lambda (prompt) (push prompt asked) t)))
              (should (equal (ecc-visit-find-written session "lib/far.el")
                             (cons far 'machine)))
              (should (equal searched '("far.el")))
              (should (= (length asked) 2)))
            ;; `always' does not ask, `never' neither asks nor searches.
            (setq searched nil)
            (let ((ecc-visit-search-machine 'always))
              (should (equal (car (ecc-visit-find-written session "far.el")) far))
              (should (equal searched '("far.el"))))
            (setq searched nil)
            (remhash session ecc-visit--chosen)
            (let ((ecc-visit-search-machine 'never))
              (should-error (ecc-visit-find-written session "far.el")
                            :type 'user-error)
              (should-not searched))
            (should (= (length asked) 2)))
        (delete-directory outside t)))))

(ert-deftest ecc-visit-test-the-pick-is-remembered ()
  "What was picked for a path opens at once the next time, while it is there."
  (ecc-visit-test--with-tree (session root) '("a/foo.el" "b/foo.el" "c/foo.el")
    (ecc-visit-test--choosing offered "b/foo.el"
      (should (equal (car (ecc-visit-find-written session "foo.el"))
                     (expand-file-name "b/foo.el" root)))
      (should (= (length offered) 1)))
    ;; `completing-read' is an error again in the tree.
    (should (equal (ecc-visit-find-written session "foo.el")
                   (cons (expand-file-name "b/foo.el" root) 'remembered)))
    (delete-file (expand-file-name "b/foo.el" root))
    (ecc-visit-test--choosing offered "c/foo.el"
      (should (equal (car (ecc-visit-find-written session "foo.el"))
                     (expand-file-name "c/foo.el" root)))
      (should (equal (car offered) '("a/foo.el" "c/foo.el"))))))

(ert-deftest ecc-visit-test-a-prefix-argument-picks-again ()
  "\\[universal-argument] RET on a path passes over the pick and remembers the new one."
  (ecc-visit-test--with-tree (session root) '("a/foo.el" "b/foo.el")
    (ecc-visit-test--choosing offered "a/foo.el"
      (ecc-visit-find-written session "foo.el"))
    (ecc-visit-test--choosing offered "b/foo.el"
      (should (equal (ecc-visit-find-written session "foo.el" nil t)
                     (cons (expand-file-name "b/foo.el" root) 'project)))
      (should (= (length offered) 1)))
    (should (equal (ecc-visit-find-written session "foo.el")
                   (cons (expand-file-name "b/foo.el" root) 'remembered)))
    ;; From the transcript, the prefix argument of RET is what asks.
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "where")
    (ecc-model-node-changed
     session
     (ecc-model-add-node session :type 'text :status 'done
                         :data '((text . "See `foo.el`.\n"))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (let (opened)
        (cl-letf (((symbol-function 'ecc-visit-open)
                   (lambda (path &rest _) (setq opened path))))
          (goto-char (point-min))
          (search-forward "foo.e")
          (ecc-session-visit)
          (should (equal opened (expand-file-name "b/foo.el" root)))
          (ecc-visit-test--choosing offered "a/foo.el"
            (let ((current-prefix-arg '(4)))
              (ecc-session-visit))
            (should offered))
          (should (equal opened (expand-file-name "a/foo.el" root))))))))

(ert-deftest ecc-visit-test-two-sessions-keep-their-own-picks ()
  "Two sessions in two projects each find in their own and remember their own pick."
  (ecc-visit-test--with-tree (one root-one) '("a/foo.el" "b/foo.el")
    (let* ((root-two (file-name-as-directory (make-temp-file "ecc-visit-two" t)))
           (two (ecc-model-create-session :name "two" :project-root root-two)))
      (unwind-protect
          (progn
            (dolist (file '("a/foo.el" "b/foo.el" "only-two.el"))
              (let ((path (expand-file-name file root-two)))
                (make-directory (file-name-directory path) t)
                (write-region "x\n" nil path nil 'silent)))
            (cl-letf (((symbol-function 'ecc-prompt-project-files)
                       (lambda (session)
                         (let ((root (ecc-session-project-root session)))
                           (mapcar (lambda (file) (file-relative-name file root))
                                   (directory-files-recursively root ""))))))
              (ecc-visit-test--choosing offered "a/foo.el"
                (ecc-visit-find-written one "foo.el" root-one))
              (ecc-visit-test--choosing offered "b/foo.el"
                (ecc-visit-find-written two "foo.el" root-two))
              (should (equal (ecc-visit-find-written one "foo.el" root-one)
                             (cons (expand-file-name "a/foo.el" root-one) 'remembered)))
              (should (equal (ecc-visit-find-written two "foo.el" root-two)
                             (cons (expand-file-name "b/foo.el" root-two) 'remembered)))
              ;; A file of the other project is not this one's.
              (let ((ecc-visit-search-machine 'never))
                (should-error (ecc-visit-find-written one "only-two.el" root-one)
                              :type 'user-error))))
        (ecc-test-cleanup-session two)
        (delete-directory root-two t)))))

(ert-deftest ecc-visit-test-ret-on-a-bare-name-in-the-reply ()
  "RET on a name the model wrote without its directory opens it from the project."
  (ecc-visit-test--with-tree (session root) '("test/foo-test.el")
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "where")
    (ecc-model-node-changed
     session
     (ecc-model-add-node session :type 'text :status 'done
                         :data '((text . "The test is `foo-test.el:3`.\n"))))
    (ecc-render-flush session)
    (with-current-buffer (ecc-session-buffer session)
      (let (opened)
        (cl-letf (((symbol-function 'ecc-visit-open)
                   (lambda (path line &rest _) (setq opened (cons path line)))))
          (goto-char (point-min))
          (search-forward "foo-test")
          (ecc-session-visit)
          (should (equal opened (cons (expand-file-name "test/foo-test.el" root)
                                      3))))))))

;;;; Opening

(ert-deftest ecc-visit-test-open ()
  "The file opens at the line; a file that is not there is an error."
  (let ((file (make-temp-file "ecc-visit" nil ".txt" "one\ntwo\nthree\nfour\n")))
    (unwind-protect
        (save-window-excursion
          (let ((window (ecc-visit-open file 3)))
            (should (window-live-p window))
            (with-current-buffer (window-buffer window)
              (should (equal buffer-file-name file))
              (should (= (line-number-at-pos (window-point window)) 3))))
          (should-error (ecc-visit-open (concat file ".missing") 1)
                        :type 'user-error))
      (when-let* ((buffer (find-buffer-visiting file)))
        (kill-buffer buffer))
      (delete-file file))))

(defmacro ecc-visit-test--recording-opens (&rest body)
  "Run BODY with both ways of opening a file recorded, not taken.
`played' and `visited' are bound in BODY to the paths each was given."
  (declare (indent 0))
  `(let ((played nil) (visited nil))
     (cl-letf (((symbol-function 'ecc-image-open-externally)
                (lambda (path) (push path played)))
               ((symbol-function 'find-file-noselect)
                (lambda (path &rest _) (push path visited)
                  (get-buffer-create " *ecc-visit-test*"))))
       (save-window-excursion ,@body))))

(ert-deftest ecc-visit-test-open-media-plays-outside ()
  "A video or a sound goes to the machine's player, and no buffer is made."
  (dolist (extension '(".mp4" ".mp3"))
    (let ((file (make-temp-file "ecc-visit" nil extension "bytes")))
      (unwind-protect
          (ecc-visit-test--recording-opens
            (should-not (ecc-visit-open file 12))
            (should (equal played (list file)))
            (should-not visited))
        (delete-file file)))))

(ert-deftest ecc-visit-test-open-missing-media-is-an-error ()
  "A video that is not there is the error, and nothing is started."
  (ecc-visit-test--recording-opens
    (should-error (ecc-visit-open "/nonexistent/ecc-visit/clip.mp4" 1)
                  :type 'user-error)
    (should-not played)
    (should-not visited)))

(ert-deftest ecc-visit-test-open-other-files-in-a-buffer ()
  "A picture and a source file still open in a buffer."
  (dolist (extension '(".png" ".el"))
    (let ((file (make-temp-file "ecc-visit" nil extension "x")))
      (unwind-protect
          (ecc-visit-test--recording-opens
            (ecc-visit-open file nil)
            (should (equal visited (list file)))
            (should-not played))
        (delete-file file)))))

(provide 'ecc-visit-test)

;;; ecc-visit-test.el ends here
