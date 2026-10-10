;;; docshots.el --- Build the pictures of the documentation site  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives a throwaway GUI Emacs through the scenes the documentation site
;; needs a picture of, so that scripts/docshots.sh can capture them.
;;
;; Like scripts/screenshot.el, and for the same reasons: recorded
;; fixtures are replayed through the real dispatch and the real renderer,
;; so no CLI and no network are involved and the result is the same every
;; time.  The two differ in what they are for -- screenshot.el makes the
;; one animation of README.md, this one makes the stills and the short
;; animations a page of the site points at.
;;
;; The scenes, in the order the wrapper runs them:
;;
;;   switch   two sessions, the picker, and the window changing hands
;;   menu     `ecc-menu' open over a session
;;   resume   the session picker of `ecc-resume', with an icon per state
;;   sessions the tab line and the dashboard, over four sessions at once
;;   prompt   the slash command list, and the transcript being folded
;;   review   the diff, a proposal, a plan, the Files section, the turns
;;
;; The recordings the resume picker offers are invented here.  The real
;; ones are the conversations of whoever runs this, and their titles and
;; their first prompts would go into a picture on a public site.
;;
;; Run it through scripts/docshots.sh rather than by hand.

;;; Code:

;; `open' on macOS goes through LaunchServices, which does not pass the
;; shell environment on, so the wrapper hands these in with --eval.
(defvar shot-geometry-file "/tmp/ecc-docshot-geom.txt"
  "Where the frame geometry is written for screencapture to read.")

(defvar shot-error-file "/tmp/ecc-docshot-error.txt"
  "Where a failure during setup is written.")

(defvar shot-frame-title "ecc docshot"
  "The title of the frame, which is how the recorder finds its window.
The wrapper makes it one of this run's own: the recorder takes the first
window of Emacs whose title contains it, and the Emacs of the person at
the machine is Emacs too.")

;; The pictures are of the checkout this was started in, and of nothing
;; else.  The packages are wanted for the theme, the mode line and the
;; completion UI, but an ecc installed among them would be activated
;; too: its directory, compiled, on `load-path', and its autoloads
;; loaded.  The checkout went in front of it and won, but only by that
;; order, and a module the checkout no longer has would still have been
;; found there.  So the installed one is not activated at all, a stale
;; .elc in the checkout loses to its .el, and `shot-foreign-ecc' is
;; checked before the first picture (2026-10-10).
(setq package-user-dir (expand-file-name "~/.emacs.d/elpa")
      package-load-list '((ecc nil) all)
      load-prefer-newer t)
(package-initialize)
(add-to-list 'load-path default-directory)
(add-to-list 'load-path (expand-file-name "test" default-directory))
(require 'ecc)
(require 'ecc-test-helpers)
(require 'server)

;; The pictures should show the completion UI most users of this package
;; have, rather than the one a bare Emacs falls back to: the candidates
;; as a list, in a frame of their own over the middle of the window.
(require 'vertico nil t)
(require 'vertico-posframe nil t)

;; The site's pictures are dressed the same way as the README's one, in
;; scripts/screenshot.el: a dark theme and a modern monospace, so that
;; the documentation looks like one set rather than two.  None of this is
;; loaded by `ecc' itself.
(setq doom-themes-enable-bold t
      doom-themes-enable-italic t)
(load-theme 'doom-tokyo-night t)
(require 'doom-modeline)
(setq doom-modeline-icon t
      doom-modeline-buffer-encoding nil
      doom-modeline-height 28
      doom-modeline-bar-width 4
      doom-modeline-buffer-file-name-style 'file-name)
(doom-modeline-mode 1)
;; doom-modeline right-aligns to the last pixel of the window, and with
;; this font the closing bracket of the process segment lands half off
;; the edge; a mode line of its own, ending in two spaces, is the least
;; invasive way back.
(doom-modeline-def-modeline 'shot-main-line
  '(bar modals buffer-info buffer-position selection-info)
  '(misc-info major-mode process "  "))
(doom-modeline-set-modeline 'shot-main-line t)

;; A warning opens a window of its own over the scene.  There should be
;; none left, but a picture is not the place to find out.
(setq native-comp-async-report-warnings-errors 'silent
      warning-minimum-level :error)

(setq ecc-render-debounce 0
      ecc-visual-enable-icons t
      ecc-visual-enable-spinner nil
      ecc-chat-text-width 64
      inhibit-startup-screen t
      frame-title-format shot-frame-title
      icon-title-format shot-frame-title)

(defconst shot-project "records"
  "The name of the demo project, which the main session is named after.")

(defconst shot-root (concat "/tmp/" shot-project)
  "The demo project, where scripts/docshots-fixtures.sh recorded its sessions.")

(defconst shot-repository default-directory
  "The repository this was started in.
The wrapper starts Emacs with --chdir there, and the scenes change
`default-directory' as they go, so it is kept while it is still true.")

(defun shot-foreign-ecc ()
  "Return every ecc file loaded from outside this checkout."
  (seq-filter (lambda (file)
                (and (string-match-p "/ecc\\(-[a-z-]+\\)?\\.elc?\\'" file)
                     (not (file-in-directory-p file shot-repository))))
              (mapcar #'car load-history)))

(defconst shot-project-files (expand-file-name "scripts/docshots-project" shot-repository)
  "The demo projects' sources.  Real files rather than strings here, so
that scripts/docshots-fixtures.sh records its sessions over the same
code these scenes show.  Written for this and nobody's but this
repository's.")

(defconst shot-fixtures (expand-file-name "scripts/docshots-fixtures" shot-repository)
  "The recordings these scenes replay, made by scripts/docshots-fixtures.sh.
Not test/fixtures: those are the ERT tests', and what they record is
whatever a test needs, not a story somebody can read.")

(defun shot-read (file)
  "Return the contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defconst shot-file (expand-file-name "reader.py" shot-root))

(defconst shot-broken-file (expand-file-name "report.py" shot-root)
  "A file with a real syntax error, for the scene about fixing one.")

(defconst shot-broken (shot-read (expand-file-name "records/report.py" shot-project-files))
  "The broken file.  The error is inside a line rather than at its end:
a diagnostic that flymake anchors on the newline belongs to the region
of neither line, and the command that reads the line under the point
would find nothing.")

(defconst shot-before (shot-read (expand-file-name "records/reader.py" shot-project-files))
  "The demo source before the recorded session edits it.
Its lines are kept under fifty columns, the width of the source window
beside a transcript.")

(defconst shot-after (shot-read (expand-file-name "edit.reader.py" shot-fixtures))
  "The same file after the edit the recording makes, as it made it.")

(defun shot-prompt-of (fixture)
  "Return the prompt FIXTURE was recorded with."
  (string-trim (shot-read (expand-file-name (concat fixture ".prompt") shot-fixtures))))

(defconst shot-hero-file (expand-file-name "summary.py" shot-root)
  "A longer file of the demo project, for the source window of the hero picture.")

(defconst shot-hero-source (shot-read (expand-file-name "records/summary.py" shot-project-files))
  "The contents of that file.")

(defvar shot-main nil "The session the pictures are taken of.")
(defvar shot-other nil "The second session, so that switching has somewhere to go.")

(defun shot-fixture (name)
  "Return recording NAME as parsed messages.
One of `shot-fixtures', or, for what carries no story -- the usage
report -- a test fixture of that name."
  (let ((file (expand-file-name (concat name ".jsonl") shot-fixtures)))
    (delq nil
          (mapcar #'ecc-protocol-parse-line
                  (if (file-exists-p file)
                      (split-string (shot-read file) "\n" t)
                    (ecc-test-fixture-lines name))))))

(defun shot-request-index (fixture)
  "Return the 1-based position of the first permission FIXTURE asks for.
The scenes stop a recording there, answer it as a user would, and play
the rest; counted by hand, the positions broke with every recording."
  (let ((index 0))
    (catch 'found
      (dolist (message (shot-fixture fixture))
        (setq index (1+ index))
        (when (equal (alist-get 'type message) "control_request")
          (throw 'found index)))
      (error "%s asks for no permission" fixture))))

(defun shot-play-to-request (session fixture)
  "Play FIXTURE into SESSION up to the permission it asks for."
  (shot-play session fixture 1 (shot-request-index fixture)))

(defun shot-play-after-request (session fixture)
  "Play the rest of FIXTURE into SESSION, after its permission."
  (shot-play session fixture (1+ (shot-request-index fixture))))

(defun shot-play (session fixture &optional from to)
  "Dispatch the messages of FIXTURE into SESSION and draw the result.
FROM and TO, 1-based and inclusive, narrow it to part of the recording.
The turn it plays is given the prompt it was recorded with, which the
stream never says back: without it the heading reads \"(resumed)\"."
  (let ((messages (shot-fixture fixture))
        (prompt (expand-file-name (concat fixture ".prompt") shot-fixtures)))
    (dolist (message (seq-subseq messages (1- (or from 1)) (or to (length messages))))
      (ecc-dispatch session message))
    (when-let* (((file-exists-p prompt))
                (turn (car (last (ecc-session-turns session))))
                ((not (ecc-turn-prompt turn))))
      (setf (ecc-turn-prompt turn) (shot-prompt-of fixture))
      (ecc-render-refresh session)))
  (ecc-render-flush session))

(defun shot-allow (session)
  "Answer the permission SESSION is waiting on, and change the file for real."
  (dolist (request (copy-sequence (ecc-session-pending session)))
    (ecc-perm-allow-request request))
  (with-temp-file shot-file (insert shot-after))
  (ecc-render-flush session))

(defun shot-prepare ()
  "Create the demo project and the two sessions, and replay into them."
  (make-directory shot-root t)
  (with-temp-file shot-file (insert shot-before))
  (setq ecc--sessions (make-hash-table :test #'equal)
        ecc--session-order nil)
  ;; The replayed sessions have no process to talk to.  A session that
  ;; really is running -- the ones the Send scenes start -- is left
  ;; alone.
  (advice-add 'ecc-proc-send-json :around
              (lambda (original session &rest arguments)
                (when (process-live-p (ecc-session-process session))
                  (apply original session arguments))))
  (setq shot-main (ecc-model-create-session :name shot-project
                                            :project-root shot-root))
  (setq shot-other (ecc-model-create-session :name "notes"
                                             :project-root shot-root))
  (ecc-session-ensure-buffer shot-main)
  (ecc-session-ensure-buffer shot-other)
  ;; The recording ends with a permission nobody answered, which the
  ;; renderer rightly draws as denied.  Answering it where it was asked
  ;; leaves the transcript the way a session that went well looks: the
  ;; diff allowed, the result, the summary.
  (shot-play-to-request shot-main "edit")
  (shot-allow shot-main)
  (shot-play-after-request shot-main "edit")
  ;; The second session is there to be switched to, so it has to look
  ;; different from the first at a glance.
  (shot-play shot-other "tasks")
  ;; What every way into a session turns on: the count of waiting
  ;; requests, the announcements, the tab line.  The scenes here make
  ;; their sessions through the model rather than through `ecc-start',
  ;; so without this the pictures would be missing the tabs that are on
  ;; the screen of anyone actually using the package.
  (ecc--enable-session-modes))

(defun shot-show (session)
  "Show the source in the frame and SESSION in the window ecc gives it.
The layout is made with ecc's own window commands rather than by
splitting the frame here: a session window carries a role, and the
commands that move a session between windows look for that role.  A
hand-made split has none of it, and the pictures would show something
no user has."
  ;; The sidebar every Space opens with is a column the pictures of one
  ;; feature cannot spare at this width; it has scenes of its own
  ;; (`shot-scene-sidebar', `shot-scene-spaces').  Left there, it is
  ;; also the frame's first window, and the layout below went into a
  ;; frame of its own (2026-10-10).
  (when (fboundp 'ecc-sidebar-hide)
    (ecc-sidebar-hide))
  ;; A scene before this one may have left the point somewhere that is
  ;; not an ordinary window -- a minibuffer, the child frame the
  ;; completion list is drawn in -- and window commands run from there
  ;; fail rather than act on the frame.
  (select-window (frame-first-window (selected-frame)))
  ;; It may also have left the side windows ecc puts a session in, and a
  ;; side window refuses to become the only window unless its
  ;; parameters are ignored.
  (let ((ignore-window-parameters t))
    (delete-other-windows))
  (find-file shot-file)
  (let ((window (ecc-window-select-session session)))
    ;; Showing a session lays its Space out, sidebar and all, and the
    ;; sidebar is put back by it; it goes again here.
    (when (fboundp 'ecc-sidebar-hide)
      (ecc-sidebar-hide))
    (when (window-live-p window)
      (with-selected-window window
        (ecc-chat--set-margins window)
        (goto-char (point-max))
        (recenter -1))))
  (redisplay t))

;;;; The invented recordings of the resume picker

(defconst shot-elsewhere-id "8f2c1a64-elsewhere"
  "The recording the picker should mark as running in another process.")

(defun shot-fake-recordings (&rest _)
  "Return invented recordings, so that no real conversation is pictured."
  (list `((session-id . ,shot-elsewhere-id)
          (title . "parser: accept a trailing comma")
          (time . ,(time-subtract (current-time) (* 26 60)))
          (prompt . "The CSV reader chokes on a trailing comma -- fix it"))
        `((session-id . "3b7d90e2-recorded")
          (title . "docs: write the install page")
          (time . ,(time-subtract (current-time) (* 5 3600)))
          (prompt . "Draft the installation page from the README"))
        `((session-id . "c04e5517-recorded")
          (title . "flaky test in test_queue.py")
          (time . ,(time-subtract (current-time) (* 3 86400)))
          (prompt . "test_queue.py fails about one run in ten"))))

(defun shot-fake-registry (session-id)
  "Say that only `shot-elsewhere-id' is running in another process."
  (and (equal session-id shot-elsewhere-id)
       '((pid . 4271) (sessionId . "8f2c1a64-elsewhere"))))

;;;; A session that really runs, for the Send scenes

;; `ecc-send-region' and the rest are answered by the model, so these
;; scenes need the real CLI.  It is asked for haiku and given a budget,
;; as scripts/record-*.sh are.

(defvar shot-live nil "The session the Send scenes send to.")

(defun shot-start-live ()
  "Start a real session in the demo project and show it.
The replayed sessions are killed first, so that this one can have the
name of the project rather than `records<2>'."
  (dolist (session (ecc-model-sessions))
    (ecc-kill session))
  (setq shot-live (ecc-model-create-session
                   :project-root shot-root
                   :name shot-project
                   ;; Remote Control off: it is on in the Claude Code
                   ;; settings of the machine this was made on, and the
                   ;; transcript then opens with the session's own
                   ;; claude.ai URL across it.
                   :options '(:model "haiku"
                              :remote-control nil
                              ;; The CLI offers a prompt only when it is
                              ;; asked to; the scene that takes one waits
                              ;; for it to arrive.
                              :prompt-suggestions t
                              :extra-args ("--max-budget-usd" "0.30"))))
  (ecc-session-ensure-buffer shot-live)
  (ecc-proc-start shot-live)
  (ecc--enable-session-modes)
  (shot-show shot-live))

(defun shot-start-live-default ()
  "Start a real session on the model the Claude Code settings name.
The suggestion scene needs one rather than the haiku every other live
scene asks for: haiku sends no `prompt_suggestion\=' at all, while the
default model offers one after a turn or two (confirmed 2026-09-11,
with --prompt-suggestions and --include-partial-messages both passed
either way).  The budget is larger to match, and still a budget."
  (dolist (session (ecc-model-sessions))
    (ecc-kill session))
  (setq shot-live (ecc-model-create-session
                   :project-root shot-root
                   :name shot-project
                   :options '(:remote-control nil
                              :prompt-suggestions t
                              :extra-args ("--max-budget-usd" "0.50"))))
  (ecc-session-ensure-buffer shot-live)
  (ecc-proc-start shot-live)
  (ecc--enable-session-modes)
  (shot-show shot-live))

(defun shot-source-window (&optional file)
  "Return the window showing FILE, or the demo source, selecting it.
A file that is not on screen yet is put in the window that is not a
session window: the scenes open more than one file, and only the first
of them is there because `shot-show' put it there."
  ;; Not a window with a role, nor a side window, nor one with ecc's own
  ;; buffer in it: under the Spaces a transcript's window carries no
  ;; role, and the broken file of the fix-error scene took the
  ;; transcript's place (2026-10-10).
  (let* ((buffer (find-file-noselect (or file shot-file)))
         (window (or (get-buffer-window buffer)
                     (seq-find (lambda (window)
                                 (not (or (window-parameter window 'ecc-window-role)
                                          (window-parameter window 'window-side)
                                          (ecc-window-own-buffer-p
                                           (window-buffer window)))))
                               (window-list nil 'no-minibuffer)))))
    (when (window-live-p window)
      (select-window window)
      (unless (eq (window-buffer window) buffer)
        (switch-to-buffer buffer)))
    window))

;;;; Typing in the prompt region of a live session

(defun shot-prompt-window ()
  "Return the window the live session is shown in, or nil."
  (get-buffer-window (ecc-session-buffer shot-live)))

(defun shot-prompt-type (text)
  "Type TEXT into the prompt region, as a person would.
The draft is buffer text, so this is an insertion rather than a key
fed to a read loop."
  (when-let* ((window (shot-prompt-window)))
    (with-selected-window window
      (ecc-chat-goto-prompt)
      (goto-char (ecc-chat-prompt-end))
      (insert text)
      (ecc-chat-update-placeholder)
      (redisplay t))))

(defun shot-prompt-send ()
  "Send what is in the prompt region."
  (when-let* ((window (shot-prompt-window)))
    (with-selected-window window
      (call-interactively #'ecc-prompt-send)
      (redisplay t))))

(defun shot-prompt-command (command)
  "Run COMMAND in the prompt region, as a key under the prefix would."
  (when-let* ((window (shot-prompt-window)))
    (with-selected-window window
      (ecc-chat-goto-prompt)
      (call-interactively command)
      (redisplay t))))

(defun shot-restore-source ()
  "Put the demo source back as the recorded edit left it.
The rewrite scene changes it for real, and the scenes after it would
otherwise show the rewritten signature."
  ;; The inline answer of the scene before is still over the code.
  (when (fboundp 'ecc-inline-quit)
    (ecc-inline-quit))
  (unless (equal (shot-read shot-file) shot-after)
    (with-temp-file shot-file (insert shot-after)))
  (when-let* ((buffer (get-file-buffer shot-file)))
    (with-current-buffer buffer
      (revert-buffer t t t))))

(defun shot-scene-cursor-point (line)
  "Put the point on LINE of the demo source, with nothing marked.
`@cursor' reads the buffer the user last worked in, which is this one."
  (shot-restore-source)
  (with-selected-window (shot-source-window)
    (deactivate-mark)
    (goto-char (point-min))
    (forward-line (1- line))
    (back-to-indentation))
  (redisplay t))

(defun shot-scene-image-file ()
  "Return the demo image, putting it in the project the session runs in.
A plain chart, kept in scripts/ beside this file: a screenshot of Emacs
inside a screenshot of Emacs is not a picture anyone can read, and the
model then answers about the very thing the reader is already looking
at.  It is sized to fit the window beside the session."
  (let ((file (expand-file-name "coffee.png" shot-root)))
    (unless (file-exists-p file)
      (copy-file (expand-file-name "scripts/docshots-image.png"
                                   shot-repository)
                 file t))
    file))

(defun shot-scene-image-open ()
  "Show the demo image itself in the window beside the session.
Without it the scene is a path appearing in the prompt: ecc sends an
image by reference, so nothing of the picture is otherwise on screen."
  (with-selected-window (shot-source-window (shot-scene-image-file))
    (when (fboundp 'image-transform-fit-to-window)
      (ignore-errors (image-transform-fit-to-window)))
    (goto-char (point-min)))
  (redisplay t))

(defun shot-scene-insert-image ()
  "Insert the demo image into the prompt, as C-c C-i does."
  (when-let* ((window (shot-prompt-window)))
    (with-selected-window window
      (ecc-chat-goto-prompt)
      (ecc-prompt-insert-image (shot-scene-image-file))
      (ecc-chat-update-placeholder)
      (redisplay t))))

(defun shot-suggestion-p ()
  "Return non-nil once the CLI has suggested a prompt.
The wrapper asks until it has one: a suggestion arrives when the CLI
feels like offering one, not on a schedule."
  (and shot-live (ecc-hint-suggestion shot-live) t))

(defun shot-scene-send-region-point ()
  "Put the point at the start of `parse_line', with nothing marked."
  (shot-restore-source)
  (with-selected-window (shot-source-window)
    (deactivate-mark)
    (goto-char (point-min))
    (re-search-forward "^def parse_line" nil t)
    (beginning-of-line))
  (redisplay t))

(defun shot-scene-send-region-mark ()
  "Set the mark where the point is."
  (with-selected-window (shot-source-window)
    (push-mark (point) t t)
    (activate-mark))
  (redisplay t))

(defun shot-scene-send-region-extend ()
  "Take the selection down one more line.
The mark is activated again on every step: between two requests the
command loop has run, and it deactivates a region that nothing is
holding on to."
  (with-selected-window (shot-source-window)
    (forward-line 1)
    (activate-mark))
  (redisplay t))

(defun shot-typing-steps (start chunks)
  "Return timer steps that type CHUNKS, the first at START seconds."
  (let ((time start))
    (mapcar (lambda (chunk)
              (setq time (+ time 0.6))
              (cons time (lambda () (shot-scene-type chunk))))
            chunks)))

(defun shot-ask-sequence (command chunks &optional prefix)
  "Return the steps that run COMMAND and answer its minibuffer with CHUNKS.
COMMAND is run in the window the source is in, because what these ask
about is the region marked there.  PREFIX is its prefix argument."
  (let* ((typing (shot-typing-steps 1.0 chunks))
         (end (+ 0.8 (car (car (last typing))))))
    (append (list (cons 0.5
                        (lambda ()
                          (with-selected-window (shot-source-window)
                            (let ((current-prefix-arg prefix))
                              (call-interactively command))))))
            typing
            (list (cons end (lambda () (shot-keys "RET")))))))

(defun shot-scene-send-region-sequence ()
  "Ask for an instruction and send the marked region with it.
The prefix argument is what makes `ecc-send-region' ask for one."
  (shot-script
   (shot-ask-sequence #'ecc-send-region
                      '("What could " "go wrong " "with this " "function?")
                      '(4))))

(defun shot-scene-inline-sequence ()
  "Ask a question about the marked code, answered where the code is."
  (shot-script
   (shot-ask-sequence #'ecc-inline-prompt '("Why is this " "fragile?"))))

(defun shot-scene-rewrite-sequence ()
  "Ask for the marked code to be rewritten."
  (shot-script
   (shot-ask-sequence #'ecc-rewrite '("add a type " "hint"))))

;;;; What a session can do

(defun shot-capabilities-window ()
  "Return the window the capabilities buffer is in, selecting it."
  (let ((window (get-buffer-window ecc-capabilities-buffer-name)))
    (when (window-live-p window)
      (select-window window))
    window))

(defun shot-scene-capabilities ()
  "Open the capabilities of the replayed session.
The list is what the CLI reported in system/init, and the fixture
carries a real one, so this scene needs no process."
  (shot-show shot-main)
  (ecc-capabilities-show shot-main)
  (shot-capabilities-window)
  (goto-char (point-min))
  (redisplay t))

(defun shot-scene-capabilities-toggle (heading)
  "Put the point on HEADING and fold or unfold it.
The groups are found by name rather than by counting lines, because
folding one moves every line under it."
  (with-selected-window (shot-capabilities-window)
    (goto-char (point-min))
    (when (search-forward heading nil t)
      (beginning-of-line)
      (call-interactively #'ecc-capabilities-toggle))
    (redisplay t)))

;;;; Fixing the error at point

;; `ecc-fix-error-at-point' sends what a checker said, so the scene
;; needs a checker.  There is no pyflakes on the machine this is made
;; on, and the standard library can answer the question: `ast.parse'
;; reports a syntax error with a line, a column and a message, which is
;; the shape python-mode's flymake backend already reads.

(defconst shot-python-checker "\
import ast, sys
try:
    ast.parse(sys.stdin.read())
except SyntaxError as error:
    print('stdin:%d:%d: %s' % (error.lineno or 1, error.offset or 1, error.msg))
")

(defun shot-scene-fix-error-open ()
  "Open the broken file with flymake on, and wait for it to report."
  (with-temp-file shot-broken-file (insert shot-broken))
  (setq python-flymake-command (list "python3" "-c" shot-python-checker))
  ;; A backend that runs code is turned off in a file Emacs has not been
  ;; told to trust: "Disabling python-flymake in report.py (untrusted
  ;; content)", and the scene sent nothing (Emacs 32, 2026-10-10).
  (when (boundp 'trusted-content)
    ;; Both spellings: the check reads the file's true name, and /tmp
    ;; is /private/tmp on macOS.
    (setq trusted-content
          (list (file-name-as-directory shot-root)
                (file-name-as-directory (file-truename shot-root)))))
  (with-selected-window (shot-source-window shot-broken-file)
    (flymake-mode 1)
    (flymake-start)
    (goto-char (point-min))
    (redisplay t)))

(defun shot-scene-fix-error-point ()
  "Put the point on the line the checker complained about."
  (with-selected-window (shot-source-window shot-broken-file)
    (goto-char (point-min))
    (forward-line 1)
    (redisplay t)))

(defun shot-scene-fix-error ()
  "Ask Claude to fix the diagnostic the checker found."
  (with-selected-window (shot-source-window shot-broken-file)
    (call-interactively #'ecc-fix-error-at-point))
  (redisplay t))

(defun shot-scene-allow ()
  "Allow the request waiting, the way `a' in the transcript does.
`ecc-answer-allow', the one for answering from another buffer, asks to
confirm first -- rightly, since the user is not looking at what they
are allowing -- and a question asked while a server request is being
served never lets that request answer.

The scene runs to the end on purpose: a permission left waiting goes on
blinking, and every picture taken after it would have that in the
corner."
  (shot-later
   (lambda ()
     (with-current-buffer (ecc-session-buffer shot-live)
       (call-interactively #'ecc-perm-allow)))))

(defun shot-scene-recheck ()
  "Read the file back and run the checker again, now that it is fixed."
  (with-selected-window (shot-source-window shot-broken-file)
    (revert-buffer t t t)
    (flymake-mode 1)
    (flymake-start)
    (goto-char (point-min))
    (forward-line 1)
    (redisplay t)))

;;;; The inline question and the rewrite

(defun shot-scene-accept ()
  "Accept what is waiting to be accepted."
  (with-selected-window (shot-source-window)
    (call-interactively #'ecc-rewrite-accept))
  (redisplay t))

;;;; The hand-off

(defconst shot-handover-id "47497a40-9f64-4203-b040-ebf68c77354e"
  "The conversation the hand-off scene carries into the terminal.
`ecc-tui-open' runs the interactive CLI with --resume, so this has to
be a conversation the CLI can really find: the wrapper records it in
the demo project the first time it is needed, and it stays there.")

(defvar shot-handover nil "The session read back from that recording.")

;;;; The scenes the wrapper calls

(defvar shot-third nil "A third session, for the switch scene's picker.")

(defun shot-scene-switch-start ()
  "The frame showing the first session, before anything is switched.
A third session is made for the scene: with one other session in the
row, `ecc-switch-session' goes straight to it and asks nothing, and the
picker is what the scene is about."
  ;; A candidate begins with the mark of its session's state, so a name
  ;; typed from its first letter matches nothing under the default
  ;; prefix completion, and the picker stayed open (2026-10-10).
  (setq completion-styles '(substring basic))
  (unless shot-third
    (setq shot-third (ecc-model-create-session :name "server"
                                               :project-root shot-root))
    (ecc-session-ensure-buffer shot-third)
    (shot-play-allowed shot-third "background"))
  (shot-show shot-main))

(defun shot-scene-switch-end ()
  "Take the third session away again; no other scene has it."
  (when shot-third
    (ecc-model-remove-session shot-third)
    (when (buffer-live-p (ecc-session-buffer shot-third))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (ecc-session-buffer shot-third))))
    (setq shot-third nil))
  (shot-show shot-main))

(defun shot-script (steps)
  "Run STEPS, a list of (SECONDS . FUNCTION), each at SECONDS from now.
A scene that reads from the minibuffer is scheduled whole rather than
driven a step at a time from the wrapper: Emacs does not always answer
the server while a recursive edit is running, and a scene that needed
an answer for every keystroke hung the run.  Timers keep firing in
there, so the whole interaction can be laid out in advance and the
wrapper left to take frames on a clock."
  (dolist (step steps)
    (run-at-time (car step) nil (cdr step))))

(defun shot-later (function)
  "Run FUNCTION once this server request has been answered.
A command that reads from the minibuffer enters a recursive edit, and
one entered while a server request is still being served never lets
that request answer -- `emacsclient' then waits for ever.  The delay is
what keeps the two apart."
  (run-at-time 0.5 nil function))

(defun shot-scene-switch-pick ()
  "Open the picker of `ecc-switch-session' and leave it on screen."
  (shot-later (lambda () (call-interactively #'ecc-switch-session))))

(defun shot-scene-switch-sequence ()
  "Switch to the other session and back, typing the names."
  (shot-script
   (list (cons 0.5 (lambda () (call-interactively #'ecc-switch-session)))
         (cons 2.0 (lambda () (shot-keys "n")))
         (cons 2.6 (lambda () (shot-keys "o")))
         (cons 3.2 (lambda () (shot-keys "t")))
         (cons 4.2 (lambda () (shot-keys "RET")))
         (cons 6.0 (lambda () (call-interactively #'ecc-switch-session)))
         (cons 7.5 (lambda () (shot-keys "r")))
         (cons 8.1 (lambda () (shot-keys "e")))
         (cons 9.1 (lambda () (shot-keys "RET"))))))

(defun shot-keys (keys)
  "Feed KEYS, a `kbd' string, to whatever is reading input.
The wrapper drives this Emacs through the server, and a server request
is served from inside whatever read loop is running -- a minibuffer, a
transient.  `execute-kbd-macro' there quits; leaving the events on
`unread-command-events' lets that read loop pick them up itself."
  (setq unread-command-events
        (append (listify-key-sequence (kbd keys)) unread-command-events)))

(defun shot-scene-type (text)
  "Type TEXT into whatever is reading from the minibuffer.
`kbd' reads a space as the separator between two keys, so a space in
the text has to be spelled."
  (shot-keys (mapconcat (lambda (character)
                          (if (eq character ?\s) "SPC" (string character)))
                        text " ")))

(defun shot-scene-return ()
  "Answer the minibuffer with what is typed."
  (shot-keys "RET"))

(defun shot-scene-menu ()
  "Open `ecc-menu' over the session."
  (shot-show shot-main)
  (shot-later (lambda () (call-interactively #'ecc-menu))))

(defconst shot-other-root "/tmp/api-server"
  "A second project, so that a frame can hold two of them.
The Spaces and the sidebar are about several projects at once, which is
the one thing a demo living in a single directory cannot show.")

(defconst shot-other-file (expand-file-name "server.py" shot-other-root))

(defconst shot-other-source (shot-read (expand-file-name "api-server/server.py" shot-project-files))
  "The source of the second project, so its buffer is telling at a glance.")

(defvar shot-foreign nil "A session of the second project.")

(defun shot-foreign-session (&optional fixture)
  "Create the second project and the session in it, once, and return it.
The scenes that want two projects on the screen -- the Spaces and the
sidebar -- all want the same one.  FIXTURE is the recording to
replay into it, `write\=' by default: a scene whose own session
was replayed from that one has to name another, since two sessions on
one recording evict each other from the registry."
  (make-directory shot-other-root t)
  (unless (file-exists-p shot-other-file)
    (with-temp-file shot-other-file (insert shot-other-source)))
  (unless shot-foreign
    (setq shot-foreign (ecc-model-create-session :name "api-server"
                                                 :project-root shot-other-root))
    (ecc-session-ensure-buffer shot-foreign)
    ;; Not the fixture `notes\=' was replayed from: a recording carries
    ;; the session id it was made under, the dispatch puts the session
    ;; in the registry under it, and two sessions replaying one
    ;; recording means the second quietly evicts the first (confirmed
    ;; 2026-09-13).
    (shot-play-allowed shot-foreign (or fixture "write"))
    ;; Every fixture was recorded in one sandbox and every sandbox path
    ;; is rewritten to the demo project, so the init message of the
    ;; recording puts this session back in it -- which is where a
    ;; session\='s project comes from.  Saying so again afterwards is what
    ;; makes this a second project rather than a second name for the
    ;; first (confirmed 2026-09-13).
    (setf (ecc-session-cwd shot-foreign)
          (file-name-as-directory shot-other-root)))
  shot-foreign)

(defun shot-scene-focus-end ()
  "Take the second project away again.
The scenes after this one photograph the dashboard and the tab line,
which list every session there is: a project left over from here would
be in both of them."
  (when shot-foreign
    (ecc-window-hide-session shot-foreign)
    (ecc-model-remove-session shot-foreign)
    (when (buffer-live-p (ecc-session-buffer shot-foreign))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (ecc-session-buffer shot-foreign))))
    (setq shot-foreign nil))
  (when-let* ((buffer (get-file-buffer shot-other-file)))
    (kill-buffer buffer))
  (shot-show shot-main))

(defun shot-scene-spaces ()
  "The Spaces: a tab for each project, the sidebar down the left, and
this project\='s two transcripts standing beside its source.

This is the picture the Spaces page opens with, so it has to hold the
whole idea at once: the list on the left, the tabs across the top, and
one Space laid out underneath them."
  (require 'ecc-space)
  (require 'ecc-sidebar)
  (shot-foreign-session)
  ;; Wide enough for the sidebar, the source and two transcripts side by
  ;; side.  A transcript may not go under `ecc-space-session-min-width\=',
  ;; 80 columns, and no screen this is run on fits that twice beside the
  ;; rest -- so the picture is taken with the width the frame can really
  ;; give two of them.
  (let* ((area (frame-monitor-workarea))
         (columns (min 170 (/ (- (nth 2 area) 48) (frame-char-width)))))
    (set-frame-size (selected-frame) columns 32)
    (setq ecc-space-session-min-width 44))
  (shot-place-frame-bottom-right)
  ;; A tab for each project, ending on the demo one: the picture is of
  ;; its Space, with the other Space waiting in the tab bar and in the
  ;; sidebar.
  (ecc-space-select (ecc-space-of-root shot-other-root))
  (ecc-space-select (ecc-space-of-root shot-root))
  (ecc-sidebar-show)
  ;; Deal the tab the way a new one is dealt: the source on the left,
  ;; the transcripts beside it.
  (ecc-space-reset-windows)
  ;; The demo file is eight lines long, so the source is given a narrow
  ;; column -- and that is also what leaves the row wide enough for the
  ;; second transcript to divide the first rather than go windowless.
  (when-let* ((window (get-buffer-window (get-file-buffer shot-file))))
    (ignore-errors (window-resize window (- 34 (window-width window)) t)))
  ;; The second transcript is put beside the first with the Space's own
  ;; helper rather than with `ecc-space-display-session\=', which goes
  ;; through `ecc-space-select\=' -- and selecting the tab restores the
  ;; window configuration stored in it, undoing the narrow source a line
  ;; above and leaving the row too tight to divide (measured 2026-09-18).
  (when-let* ((windows (ecc-space--session-windows))
              (right (car (last windows)))
              (other (if (eq (window-buffer right) (ecc-session-buffer shot-main))
                         shot-other
                       shot-main)))
    (ecc-space--display-beside (ecc-session-buffer other) right
                               (/ (window-total-width right) 2)))
  (dolist (session (list shot-main shot-other))
    (when-let* ((window (get-buffer-window (ecc-session-buffer session))))
      (with-selected-window window
        (ecc-chat--set-margins window)
        (goto-char (point-max))
        (recenter -1))))
  (message nil)
  (redisplay t))

(defun shot-scene-spaces-end ()
  "Take the tabs, the sidebar and the second project away again.
Every scene after this one photographs one frame of windows, and a tab
bar or a sidebar left behind would be in all of them."
  (setq ecc-space-session-min-width 80)
  (ecc-sidebar-hide)
  (tab-bar-mode -1)
  (set-frame-size (selected-frame) 112 44)
  (shot-place-frame-bottom-right)
  (shot-scene-focus-end))

(defconst shot-worktree-roots
  '(("feat/x" . "feat-x") ("fix/parser" . "fix-parser"))
  "The worktrees the sidebar picture shows, branch to directory.")

(defvar shot-worktree-sessions nil "The sessions made for those worktrees.")

(defun shot-worktree-root (slug)
  "Return the directory the worktree SLUG stands in."
  (expand-file-name slug (expand-file-name ".claude/worktrees" shot-root)))

(defun shot-fake-git (&rest _)
  "Answer git\='s questions about the demo projects without a repository.
The sidebar draws the branch a Space is on, how far it is from its
upstream, and the worktrees hanging under a repository -- all of it read
from git.  The demo projects are directories in /tmp with no repository
in them, so the answers are invented here, the way the resume picker\='s
recordings are.  Making real repositories and real worktrees instead
would put this machine\='s paths and branches in the picture."
  (advice-add 'ecc-worktree-main :override
              (lambda (root)
                (and (seq-find (lambda (pair)
                                 (equal (file-name-as-directory root)
                                        (file-name-as-directory
                                         (shot-worktree-root (cdr pair)))))
                               shot-worktree-roots)
                     shot-root))
              '((name . shot-fake-git)))
  (advice-add 'ecc-worktree-branch :override
              (lambda (root)
                (let ((root (file-name-as-directory root)))
                  (or (car (seq-find
                            (lambda (pair)
                              (equal root (file-name-as-directory
                                           (shot-worktree-root (cdr pair)))))
                            shot-worktree-roots))
                      (and (equal root (file-name-as-directory shot-root)) "main")
                      (and (equal root (file-name-as-directory shot-other-root))
                           "master"))))
              '((name . shot-fake-git)))
  (advice-add 'ecc-worktree-ahead-behind :override
              (lambda (root)
                (when (equal (file-name-as-directory root)
                             (file-name-as-directory shot-root))
                  (cons 2 0)))
              '((name . shot-fake-git))))

(defun shot-unfake-git ()
  "Give git its own answers back."
  (dolist (function '(ecc-worktree-main ecc-worktree-branch
                                        ecc-worktree-ahead-behind))
    (advice-remove function 'shot-fake-git)))

(defun shot-scene-sidebar ()
  "The sidebar on its own: several Spaces, two of them worktrees.
The picture the sidebar section opens with, so it has to carry a
repository with worktrees under it, a second project, and a session
waiting for an answer -- everything the two lists can say."
  (require 'ecc-space)
  (require 'ecc-sidebar)
  (shot-foreign-session)
  (shot-fake-git)
  (unless shot-worktree-sessions
    (dolist (pair shot-worktree-roots)
      (let* ((slug (cdr pair))
             (root (shot-worktree-root slug))
             (session (progn (make-directory root t)
                             (ecc-model-create-session :name slug
                                                       :project-root root))))
        (ecc-session-ensure-buffer session)
        (setf (ecc-session-cwd session) (file-name-as-directory root))
        (push session shot-worktree-sessions))))
  ;; One of them is left waiting, which is the mark the Spaces list
  ;; carries up to the repository above.  A fixture of its own: a
  ;; recording carries the session id it was made under, and a second
  ;; session replaying one another session already has quietly evicts
  ;; that one from the registry -- which took the main session out of the
  ;; Sessions list (measured 2026-09-18).
  (let ((waiting (car (last shot-worktree-sessions))))
    (shot-play-to-request waiting "deny"))
  ;; Short: the picture is of the two lists, and a sidebar as tall as
  ;; the other scenes' frame is mostly empty below them.
  (set-frame-height (selected-frame) 18)
  (shot-place-frame-bottom-right)
  (ecc-sidebar-show)
  (ecc-sidebar-redraw)
  (message nil)
  (redisplay t))

(defun shot-report-sidebar-geometry ()
  "Write where the sidebar window is, for a picture of it alone.
The same five numbers as `shot-report-geometry', for the sidebar window
rather than the whole frame."
  (unless (active-minibuffer-window)
    (message nil))
  (redisplay t)
  (let* ((window (get-buffer-window ecc-sidebar-buffer-name))
         (outer (frame-edges nil 'outer-edges))
         (inner (frame-edges nil 'inner-edges))
         (edges (window-pixel-edges window)))
    (with-temp-file shot-geometry-file
      (insert (format "%d %d %d %d %d\n"
                      (+ (- (nth 0 inner) (nth 0 outer)) (nth 0 edges))
                      (+ (- (nth 1 inner) (nth 1 outer)) (nth 1 edges))
                      (- (nth 2 edges) (nth 0 edges))
                      (- (nth 3 edges) (nth 1 edges))
                      (- (nth 2 outer) (nth 0 outer)))))))

(defun shot-scene-sidebar-end ()
  "Take the extra sessions, the sidebar and the invented git away again."
  (dolist (session shot-worktree-sessions)
    (ecc-model-remove-session session)
    (when (buffer-live-p (ecc-session-buffer session))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (ecc-session-buffer session)))))
  (setq shot-worktree-sessions nil)
  (shot-unfake-git)
  (ecc-sidebar-hide)
  (set-frame-height (selected-frame) 44)
  (shot-place-frame-bottom-right)
  (shot-scene-focus-end))

(defvar shot-usecase-session nil "The session the use-case scene starts.")

(defun shot-scene-usecase-start ()
  "The frame as the use-case page opens: one Space, its sidebar, no more.
The second project is left with no session of its own and offered as a
project that has only recordings -- which is what `C-c c j\=' reaches and
what the scene is about."
  (require 'ecc-space)
  (require 'ecc-sidebar)
  (shot-fake-git)
  (make-directory shot-other-root t)
  (unless (file-exists-p shot-other-file)
    (with-temp-file shot-other-file (insert shot-other-source)))
  ;; `ecc-space-past-projects\=' reads the recordings on this machine, which
  ;; are this machine\='s own projects.  The scene answers for it instead,
  ;; the way the resume picker\='s recordings are answered for.
  (advice-add 'ecc-space-past-projects :override
              (lambda () (list (ecc-space-of-root shot-other-root)))
              '((name . shot-usecase)))
  ;; Going to a Space with nothing running starts a session there, and
  ;; a session here is a replayed recording rather than a CLI.
  (advice-add 'ecc-start :override
              (lambda (&rest _)
                (find-file shot-other-file)
                (let ((session (ecc-model-create-session
                                :name "api-server" :project-root shot-other-root)))
                  (ecc-session-ensure-buffer session)
                  (setf (ecc-session-cwd session)
                        (file-name-as-directory shot-other-root))
                  ;; Only the init message of a recording: what the
                  ;; picture is of is a session that has just started,
                  ;; and a transcript with a conversation already in it
                  ;; reads as a session that was there all along.
                  (shot-play session "write" 1 1)
                  (setq shot-usecase-session session)
                  ;; `ecc-start\=' shows the session it starts; the Space was
                  ;; laid out before there was one, so without this the
                  ;; new tab comes up with the source alone.
                  (ecc-space-display-session session)
                  (when-let* ((window (get-buffer-window
                                       (ecc-session-buffer session))))
                    (with-selected-window window
                      (ecc-chat--set-margins window)
                      (goto-char (point-max))
                      (recenter -1)))
                  session))
              '((name . shot-usecase)))
  (let* ((area (frame-monitor-workarea))
         (columns (min 150 (/ (- (nth 2 area) 48) (frame-char-width)))))
    (set-frame-size (selected-frame) columns 34)
    (setq ecc-space-session-min-width 44))
  (shot-place-frame-bottom-right)
  ;; A Space is offered under a line that begins with its number and its
  ;; name in a fixed column, so the default prefix completion finds
  ;; nothing for the name typed in the middle of it: `api\=' matched no
  ;; candidate and the minibuffer stayed open through the rest of the
  ;; run (measured 2026-09-18).
  (setq completion-styles '(substring basic))
  (ecc-space-select (ecc-space-of-root shot-root))
  (ecc-sidebar-show)
  (ecc-space-reset-windows)
  (message nil)
  (redisplay t))

(defun shot-scene-usecase-goto ()
  "Pick the project that has only recordings, and let its Space open."
  (shot-script
   (list (cons 0.5 (lambda () (call-interactively #'ecc-space-goto)))
         (cons 2.0 (lambda () (shot-keys "a")))
         (cons 2.6 (lambda () (shot-keys "p")))
         (cons 3.2 (lambda () (shot-keys "i")))
         (cons 4.4 (lambda () (shot-keys "RET")))
         (cons 6.0 (lambda () (redisplay t))))))

(defun shot-scene-usecase-worktree ()
  "The Space a hand-off makes: the worktree\='s tab, beside the repository.
What `start_worktree_session\=' leaves on the screen, without the CLI: the
worktree has a Space and a session of its own, and the sidebar draws it
under the repository it came from."
  (let* ((slug "feat-x")
         (root (shot-worktree-root slug)))
    (make-directory root t)
    (unless (file-exists-p (expand-file-name "reader.py" root))
      (with-temp-file (expand-file-name "reader.py" root) (insert shot-before)))
    ;; The worktree's own source, so that its Space opens on code rather
    ;; than on Dired of a directory with one file in it.
    (find-file (expand-file-name "reader.py" root))
    (let ((session (ecc-model-create-session :name slug :project-root root)))
      (ecc-session-ensure-buffer session)
      (setf (ecc-session-cwd session) (file-name-as-directory root))
      ;; Not `edit': `records' was replayed from it, and the second
      ;; session on one recording evicts the first from the registry --
      ;; which took the main session out of the Sessions list
      ;; (2026-09-18).
      (shot-play-allowed session "background")
      (push session shot-worktree-sessions)
      (ecc-space-select (ecc-space-of-root root))
      (ecc-sidebar-show)
      (ecc-space-reset-windows)
      (when-let* ((window (get-buffer-window (ecc-session-buffer session))))
        (with-selected-window window
          (ecc-chat--set-margins window)
          (goto-char (point-max))
          (recenter -1)))))
  (message nil)
  (redisplay t))

(defun shot-scene-usecase-end ()
  "Take the use-case sessions, the tabs and the invented answers away."
  (setq completion-styles (default-value 'completion-styles))
  (dolist (function '(ecc-space-past-projects ecc-start))
    (advice-remove function 'shot-usecase))
  (when shot-usecase-session
    (ecc-model-remove-session shot-usecase-session)
    (when (buffer-live-p (ecc-session-buffer shot-usecase-session))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (ecc-session-buffer shot-usecase-session))))
    (setq shot-usecase-session nil))
  (setq ecc-space-session-min-width 80)
  (set-frame-size (selected-frame) 112 44)
  (shot-place-frame-bottom-right)
  (shot-scene-sidebar-end))

(defun shot-scene-quit ()
  "Close whatever the last scene left open -- a menu, a picker.
A minibuffer is left by aborting its recursive edit from a timer: the
`C-g' a transient wants is read as a key, but a minibuffer reading with
a completion UI over it does not always get to read one."
  (shot-keys "C-g")
  (shot-later
   (lambda ()
     (when-let* ((window (active-minibuffer-window)))
       (with-selected-window window
         (abort-recursive-edit))))))

(defun shot-dump-log (session file)
  "Write the protocol log of SESSION to FILE, for looking at afterwards."
  (when-let* ((buffer (get-buffer (ecc-log-buffer-name
                                   (ecc-session-name session)))))
    (with-current-buffer buffer
      (write-region (point-min) (point-max) file nil 'quiet))))

(defun shot-dump-live-log ()
  "Write the log of the live session out."
  (when shot-live
    (shot-dump-log shot-live "/tmp/ecc-docshot-live.log")))

(defun shot-scene-resume ()
  "Open the session picker of `ecc-resume', over invented recordings."
  (shot-show shot-main)
  (advice-add 'ecc-history-recordings :override #'shot-fake-recordings)
  (advice-add 'ecc-registry-session :override #'shot-fake-registry)
  ;; A session with a live process is drawn as running; one without, as a
  ;; session this Emacs holds that has stopped.  `sleep' is only there to
  ;; be alive.
  (setf (ecc-session-process shot-main) (start-process "shot-alive" nil "sleep" "600"))
  ;; Both sessions answered a moment ago, which makes every line of the
  ;; picker say "just now"; spreading them out shows the column doing
  ;; its work.
  (setf (ecc-session-last-result-time shot-main) (current-time))
  (setf (ecc-session-last-result-time shot-other)
        (time-subtract (current-time) (* 12 60)))
  (shot-later
   (lambda ()
     ;; `ecc-read-session' takes the session of the current buffer when
     ;; there is one, which is the whole point everywhere but here.
     (let ((ecc-render--session nil))
       (with-temp-buffer (ecc-read-session "Resume: "))))))

(defun shot-place-frame-bottom-right ()
  "Put the frame in the bottom right corner of its monitor.
The capture is a region of the screen, so the frame has to stand
somewhere nothing else will be doing anything -- the rest of the screen
belongs to whoever is running this.  The bottom margin is generous
because the frame grows downwards when the minibuffer does, and a frame
that would grow past the screen is moved instead -- which would shift
it out from under the rectangle being captured."
  (let* ((area (frame-monitor-workarea))
         (margin-x 24)
         (margin-y 260)
         (x (max (nth 0 area)
                 (- (+ (nth 0 area) (nth 2 area)) (frame-pixel-width) margin-x)))
         (y (max (nth 1 area)
                 (- (+ (nth 1 area) (nth 3 area)) (frame-pixel-height) margin-y))))
    (set-frame-position (selected-frame) x y)))

(defun shot-report-geometry ()
  "Write which part of the frame's window is the picture.
The recorder takes the whole window, title bar and all, so this says
what to keep of it: X, Y, the width and the height of the rectangle,
from the top left of the window, and the width of the window, all in
points -- the picture is in pixels, and the last number is what says
how many to the point.  Opening the menu, or a minibuffer with a list
under it, resizes the frame, so this is asked for again before every
picture rather than once at the start."
  ;; Whatever was last said in the echo area would be in the picture,
  ;; and for a still taken early in a run that is Emacs's own greeting.
  (unless (active-minibuffer-window)
    (message nil))
  (redisplay t)
  (let* ((geometry (frame-geometry))
         (size (alist-get 'outer-size geometry))
         ;; The title bar is left out of the picture.  macOS writes the
         ;; new size into it whenever the frame is resized -- opening
         ;; the menu resizes it -- and nothing in Emacs clears that
         ;; again, so a picture that includes it says "(144 x 38)".
         (title-bar (or (cdr (alist-get 'title-bar-size geometry)) 0))
         (width (or (car size) (frame-pixel-width)))
         (height (or (cdr size) (frame-pixel-height))))
    (with-temp-file shot-geometry-file
      (insert (format "%d %d %d %d %d\n"
                      0 title-bar width (- height title-bar) width)))))

(defun shot-scene-handover-start ()
  "Read the recorded conversation back and show it, as a session would be."
  (setq shot-handover (ecc-history-session shot-handover-id))
  ;; The recording says /private/tmp/records, which macOS answers for
  ;; /tmp/records, and a second Space opened for it.
  (setf (ecc-session-project-root shot-handover) (file-name-as-directory shot-root)
        (ecc-session-cwd shot-handover) (file-name-as-directory shot-root))
  (ecc-session-ensure-buffer shot-handover)
  (ecc-render-refresh shot-handover)
  (shot-show shot-handover))

(defun shot-scene-handover ()
  "Hand that session over to the terminal."
  (shot-later (lambda () (ecc-tui-open shot-handover))))

;;;; What the plan has been used for, and a question asked on the side

(defun shot-scene-usage ()
  "Show the usage report, floating over the frame.
The numbers are a fixture's, not this machine's: the real answer
carries the plan of whoever runs this, what it has cost and which of
their projects has been spending it."
  (shot-show shot-main)
  (setq ecc-usage-display 'posframe)
  (let* ((message (car (shot-fixture "usage")))
         (response (alist-get 'response (alist-get 'response message)))
         (buffer (get-buffer-create ecc-usage-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-usage-mode)
        (ecc-usage-mode))
      (setq ecc-usage--data response))
    (ecc-usage--draw (ecc-usage-render response nil))
    (ecc-usage--show-posframe buffer)
    (redisplay t)
    buffer))

(defun shot-scene-usage-hide ()
  "Take the usage away again."
  (ecc-usage-hide)
  (redisplay t))

(defun shot-scene-btw-turn ()
  "Send a prompt long enough to still be running when the side question goes.
The point of a side question is that it does not interrupt the turn, so
the turn has to be there to watch: a short one had answered before the
question was typed."
  (shot-prompt-type
   "List 12 edge cases worth testing in parse_line, one short line each.")
  (shot-prompt-send))

(defun shot-scene-btw-end ()
  "Take the side question off the screen, and put the display back.
The answer is shown in a posframe, which is a child frame rather than
a window: `shot-show\=' deletes the windows of the frame and the
posframe stays where it is, floating over every picture taken after
this scene -- the tab line, the slash picker, the folding and the
capabilities all came out with it across them (confirmed 2026-09-12)."
  (when-let* ((buffer (get-buffer (ecc-btw-buffer-name shot-main))))
    (when (featurep 'posframe)
      (posframe-hide buffer))
    (when-let* ((window (get-buffer-window buffer)))
      (quit-window nil window)))
  (setq ecc-btw-display 'window)
  (redisplay t))

(defun shot-scene-btw-sequence (chunks)
  "Ask a side question, typing CHUNKS into the minibuffer.
`ecc-btw-ask' reads its question there, so the whole thing is
scheduled inside Emacs."
  (setq ecc-btw-display 'posframe)
  (let ((typing (shot-typing-steps 1.0 chunks)))
    (shot-script
     (append (list (cons 0.5 (lambda ()
                               (with-selected-window (shot-prompt-window)
                                 (call-interactively #'ecc-btw-ask)))))
             typing
             (list (cons (+ 0.8 (car (car (last typing))))
                         (lambda () (shot-keys "RET"))))))))

;;;; Reviewing what changed, a proposal and a plan

(defun shot-reset-main ()
  "Build the main session again from its recording, so a scene starts clean.
The scenes share one Emacs and a session keeps what an earlier one
replayed into it: the Files section grew a plan file and a second
write, and a scene that had ended mid-turn left the state line saying
so.  The second session is left alone, so the tab line still has one."
  ;; Every session of this name goes, not only the one `shot-main' holds:
  ;; one left behind in the model makes `ecc-model-unique-name' call the
  ;; new one records<2>, and the tab line, the mode line and the plan
  ;; buffer all said so (confirmed 2026-09-12).
  (dolist (session (ecc-model-sessions))
    (when (string-prefix-p shot-project (ecc-session-name session))
      (ecc-model-remove-session session)
      (when (buffer-live-p (ecc-session-buffer session))
        (kill-buffer (ecc-session-buffer session)))))
  (when (and shot-main (buffer-live-p (ecc-session-buffer shot-main)))
    (kill-buffer (ecc-session-buffer shot-main)))
  (with-temp-file shot-file (insert shot-before))
  (setq shot-main (ecc-model-create-session :name shot-project
                                            :project-root shot-root))
  (ecc-session-ensure-buffer shot-main)
  (shot-play-to-request shot-main "edit")
  (shot-allow shot-main)
  (shot-play-after-request shot-main "edit")
  shot-main)

(defun shot-play-allowed (session fixture)
  "Replay FIXTURE into SESSION, allowing the permission it asks for.
Played straight through it ends with the permission nobody answered,
which the renderer rightly draws as denied -- a failure in a picture
that is not about one."
  (shot-play-to-request session fixture)
  (dolist (request (copy-sequence (ecc-session-pending session)))
    (ecc-perm-allow-request request))
  (shot-play-after-request session fixture))

(defun shot-play-write (session)
  "Replay the recording that writes a file into SESSION, permission and all."
  (shot-play-allowed session "write"))


(defun shot-review-window ()
  "Return the window of the review buffer of the main session, selecting it."
  (when-let* ((buffer (get-buffer (ecc-review-buffer-name shot-main)))
              (window (get-buffer-window buffer)))
    (select-window window)
    window))

(defun shot-scene-review ()
  "Open every change of the session as one diff.
A second file is replayed in first, so that the diff has more than one
hunk to walk."
  (shot-reset-main)
  (shot-show shot-main)
  (shot-play-write shot-main)
  (ecc-review shot-main)
  (when-let* ((window (shot-review-window)))
    (with-selected-window window
      (goto-char (point-min))
      (ignore-errors (diff-hunk-next))
      (redisplay t))))

(defun shot-scene-review-hunk ()
  "Move to the next hunk, as n does."
  (when-let* ((window (shot-review-window)))
    (with-selected-window window
      (ignore-errors (diff-hunk-next))
      (redisplay t))))

(defun shot-scene-review-comment (chunks)
  "Comment on the added line of the hunk at point, typing CHUNKS.
On the @@ line \`c' comments on the whole hunk; on any other line, on
that line, which is what is shown."
  (let ((typing (shot-typing-steps 1.0 chunks)))
    (shot-script
     (append (list (cons 0.5 (lambda ()
                               (with-selected-window (shot-review-window)
                                 (when (re-search-forward "^\\+" nil t)
                                   (beginning-of-line))
                                 (call-interactively #'ecc-review-comment)))))
             typing
             (list (cons (+ 0.8 (car (car (last typing))))
                         (lambda () (shot-keys "RET"))))))))

(defun shot-scene-review-send ()
  "Ask to send the comments, which shows the prompt before it goes.
The prefix argument is what opens that buffer; plain \`C-c C-c\=' sends."
  (when-let* ((window (shot-review-window)))
    (with-selected-window window
      (let ((current-prefix-arg '(4)))
        (call-interactively #'ecc-review-send))))
  (when-let* ((buffer (get-buffer (ecc-review-message-buffer-name shot-main)))
              (window (get-buffer-window buffer)))
    (select-window window)
    (goto-char (point-min)))
  (redisplay t))

(defun shot-scene-proposal ()
  "Stop a recording at the file it asks to write, and go to the request."
  (shot-reset-main)
  (shot-show shot-main)
  (shot-play-to-request shot-main "write")
  (when-let* ((request (shot-pending-request)))
    (ecc-answer-goto-request request))
  (redisplay t))

(defun shot-proposal-window ()
  "Return the window the proposal is edited in, selecting it."
  (when-let* ((buffer (get-buffer (ecc-review-proposal-buffer-name shot-main)))
              (window (get-buffer-window buffer)))
    (select-window window)
    window))

(defun shot-scene-proposal-edit ()
  "Open the text of the proposal, as e does in the transcript."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (call-interactively #'ecc-review-edit-proposal))
  (when-let* ((window (shot-proposal-window)))
    (with-selected-window window
      (goto-char (point-max))
      (redisplay t))))

(defun shot-scene-proposal-type (text)
  "Type TEXT into the proposal, the way it would be edited by hand."
  (when-let* ((window (shot-proposal-window)))
    (with-selected-window window
      (goto-char (point-max))
      (insert text)
      (redisplay t))))

(defun shot-scene-proposal-apply ()
  "Allow the proposal with what the buffer now says."
  (when-let* ((window (shot-proposal-window)))
    (with-selected-window window
      (call-interactively #'ecc-review-proposal-apply)))
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (goto-char (point-max))
    (recenter -1)
    (redisplay t)))

(defun shot-plan-window ()
  "Return the window the plan is reviewed in, selecting it."
  (when-let* ((buffer (get-buffer (ecc-plan-buffer-name shot-main)))
              (window (get-buffer-window buffer)))
    (select-window window)
    window))

(defun shot-scene-plan ()
  "Replay a turn that ends in plan mode; the plan buffer opens by itself."
  (shot-reset-main)
  (shot-show shot-main)
  (shot-play-to-request shot-main "plan")
  ;; The plan opens under the source, which leaves it a third of the
  ;; frame high and half of it wide, and every line of the plan was cut
  ;; off on the right: the picture showed a plan nobody could read.  The
  ;; source has no part in this scene, so it goes.
  (when-let* ((window (get-buffer-window (get-file-buffer shot-file))))
    (let ((ignore-window-parameters t))
      (ignore-errors (delete-window window))))
  (when-let* ((window (shot-plan-window)))
    (with-selected-window window
      (goto-char (point-min))
      (redisplay t))))

(defun shot-scene-plan-comment (line chunks)
  "Comment on LINE of the plan, typing CHUNKS into the minibuffer.
`ecc-plan-comment\=' reads the comment there, so this is scheduled
inside Emacs like the other scenes that answer a prompt."
  (let ((typing (shot-typing-steps 1.0 chunks)))
    (shot-script
     (append (list (cons 0.5 (lambda ()
                               (with-selected-window (shot-plan-window)
                                 (goto-char (point-min))
                                 (forward-line (1- line))
                                 (call-interactively #'ecc-plan-comment)))))
             typing
             (list (cons (+ 0.8 (car (car (last typing))))
                         (lambda () (shot-keys "RET"))))))))

(defun shot-scene-plan-mode-sequence ()
  "Choose the permission mode the approval switches to."
  (shot-script
   (list (cons 0.5 (lambda ()
                     (with-selected-window (shot-plan-window)
                       (call-interactively #'ecc-plan-set-mode))))
         (cons 2.0 (lambda () (shot-keys "RET"))))))

(defun shot-scene-plan-approve ()
  "Approve the plan, which allows the request and switches the mode."
  (when-let* ((window (shot-plan-window)))
    (with-selected-window window
      (call-interactively #'ecc-plan-approve)))
  (when-let* ((window (get-buffer-window (ecc-session-buffer shot-main))))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1)))
  (redisplay t))

;;;; The Files section and the Timeline

(defun shot-scene-files ()
  "Go to the Files section of the transcript."
  (shot-reset-main)
  (shot-show shot-main)
  (shot-play-write shot-main)
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (call-interactively #'ecc-chat-goto-files)
    (recenter 2)
    (redisplay t)))

(defun shot-scene-files-key (command)
  "Run COMMAND in the transcript, as a key of the Files section would."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (call-interactively command)
    (redisplay t)))

(defun shot-scene-timeline ()
  "Open the turn picker over a session whose turns carry their prompts.
A replayed turn has none of its own: `shot-play' gives it the one it was
recorded with."
  (shot-reset-main)
  (shot-show shot-main)
  (shot-play-write shot-main)
  (shot-later
   (lambda ()
     (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
       (call-interactively #'ecc-session-timeline)))))

;;;; The prompt and the transcript

(defun shot-scene-slash ()
  "Open the slash command list from the prompt region.
The names and their descriptions are a fixture's, not the skills and
commands of whoever runs this: the first line of `basic' is the
initialize response the CLI answers with, and it is what carries them.
The recording the rest of the scene shows is left alone."
  (shot-play shot-main "basic" 1 1)
  (shot-show shot-main)
  ;; What `/' does, rather than the key itself: a key left on
  ;; `unread-command-events' from a timer is read by whatever loop is
  ;; running, and at top level there is none, so the slash was never
  ;; typed at all.  The picker is opened the way `shot-scene-resume'
  ;; opens its own, from a timer, once this server request has been
  ;; answered.
  (shot-later
   (lambda ()
     (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
       (ecc-chat-goto-prompt)
       (insert "/")
       (ecc-chat-update-placeholder)
       (ecc-prompt-read-command ecc-render--session)))))

;;;; Answering what is waiting

;; Both scenes are replayed into the session `shot-prepare' already
;; made, so the conversation goes on rather than starting again: the
;; recording is stopped where it asks, answered here as a user would,
;; and then played to its end.

(defun shot-pending-request ()
  "Return the request the main session is waiting on, or nil."
  (car (ecc-session-pending shot-main)))

(defun shot-scene-permission ()
  "Replay a turn up to the permission it asks for, and go to it."
  (shot-show shot-main)
  (shot-play-to-request shot-main "write")
  (when-let* ((request (shot-pending-request)))
    (ecc-answer-goto-request request))
  (redisplay t))

(defun shot-scene-permission-allow ()
  "Answer it with `a', which is the transcript's own key for it."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (call-interactively #'ecc-perm-allow)
    (redisplay t)))

(defun shot-scene-permission-finish ()
  "Play the rest of that recording, now that the tool may run."
  (shot-play-after-request shot-main "write")
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (goto-char (point-max))
    (recenter -1)
    (redisplay t)))

(defun shot-question-window ()
  "Return the window of the question buffer, selecting it."
  (when-let* ((buffer (get-buffer (ecc-question-buffer-name shot-main)))
              (window (get-buffer-window buffer)))
    (select-window window)
    window))

(defun shot-scene-question ()
  "Replay a turn that asks a question, and stop where it waits."
  (shot-show shot-main)
  (shot-play-to-request shot-main "question")
  (when-let* ((request (shot-pending-request)))
    (ecc-render-goto-node shot-main (ecc-request-node request)))
  (redisplay t))

(defun shot-scene-question-open ()
  "Open the buffer the question is answered in, as RET on the node does."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (call-interactively #'ecc-session-visit))
  (shot-question-window)
  (redisplay t))

(defun shot-scene-question-choose (n)
  "Choose option N of the question at point."
  (when (shot-question-window)
    (let ((last-command-event (+ ?0 n)))
      (call-interactively #'ecc-question-choose))
    (redisplay t)))

(defun shot-scene-question-submit ()
  "Send the answers, and play the rest of the recording."
  (when (shot-question-window)
    (call-interactively #'ecc-question-submit))
  (shot-play-after-request shot-main "question")
  (when-let* ((window (get-buffer-window (ecc-session-buffer shot-main))))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1)))
  (redisplay t))

(defun shot-scene-clear-prompt ()
  "Empty the prompt region again after the slash scene.
The slash it typed stays there when the picker is dismissed, and the
scenes after this one are of a session nobody has typed into."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (ecc-chat-clear-draft)
    (ecc-chat-update-placeholder)
    (redisplay t)))

(defun shot-scene-fold-start ()
  "Show the transcript with the point on its first heading."
  (shot-show shot-main)
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (goto-char (point-min))
    (ecc-chat-next-heading)
    (redisplay t)))

(defun shot-scene-fold (command)
  "Run COMMAND in the transcript of the session being shown.
The folding commands take no argument and read nothing, so the wrapper
drives this one step at a time and takes a frame after each."
  (with-selected-window (get-buffer-window (ecc-session-buffer shot-main))
    (call-interactively command)
    (redisplay t)))

;;;; The dashboard and the tab line

;; Both pictures want the same thing: several sessions at once, each in a
;; different state, so that a mark, a colour and a column can be read
;; against one another.  Two of the four are replayed sessions that are
;; already there; the other two are made here and taken away again by
;; `shot-scene-sessions-end'.

(defvar shot-waiting nil "The session left waiting for an answer.")
(defvar shot-exited nil "The session whose CLI has stopped.")

(defun shot-scene-sessions ()
  "Put four sessions into four states and show the tab line over them.
`records' is working, `notes' has nothing to do, a third is waiting for
an answer and a fourth has stopped.  The states are set here rather
than arrived at: a picture of a dashboard with one idle row in it says
nothing about what the columns are for."
  ;; The waiting one stops where its recording asks to write a file: the
  ;; first eight messages are the turn up to the permission.
  (setq shot-waiting (ecc-model-create-session :name "api"
                                               :project-root shot-root))
  (ecc-session-ensure-buffer shot-waiting)
  (shot-play-to-request shot-waiting "write")
  (setq shot-exited (ecc-model-create-session :name "docs"
                                              :project-root shot-root))
  (ecc-session-ensure-buffer shot-exited)
  (shot-play shot-exited "basic")
  (ecc-model-set-state shot-exited 'exited)
  ;; `sleep' is only there to be a live process: a session whose process
  ;; has died is drawn as one that stopped, whatever its state says.
  (setf (ecc-session-process shot-main) (start-process "shot-alive" nil "sleep" "600"))
  (ecc-model-set-state shot-main 'running)
  (ecc-model-set-state shot-other 'idle)
  ;; Every session answered a moment ago, which makes every Updated cell
  ;; say "just now"; spreading them out shows the column doing its work.
  (setf (ecc-session-last-result-time shot-main) (current-time))
  (setf (ecc-session-last-result-time shot-waiting)
        (time-subtract (current-time) (* 4 60)))
  (setf (ecc-session-last-result-time shot-other)
        (time-subtract (current-time) (* 26 60)))
  (setf (ecc-session-last-result-time shot-exited)
        (time-subtract (current-time) (* 95 60)))
  ;; The tab of a session waiting for an answer blinks, and a still
  ;; taken on the dark beat shows it inverse-video -- which is the
  ;; blink, not the colour the page is about.
  (ecc-tab-blink-stop)
  (setq ecc-tab--blink-phase nil)
  (shot-show shot-main)
  (ecc-tab--force-update)
  (redisplay t))

(defun shot-scene-dashboard ()
  "Open the dashboard over those four sessions, filling the frame.
The list is seven columns wide, and in the window `display-buffer'
gives it beside a session everything after Project falls off the right
edge -- which is most of what the picture is for."
  ;; The seven columns and the gutter want more than the 112 the other
  ;; scenes are framed at, and the height is cut to what four rows and
  ;; the summary above them need, so that the list is the picture.  The frame is put back in the corner
  ;; afterwards, because it grows to the right and would leave the screen.
  (set-frame-size (selected-frame) 150 12)
  (shot-place-frame-bottom-right)
  (ecc-dashboard)
  (when-let* ((window (get-buffer-window ecc-dashboard-buffer-name)))
    (select-window window)
    ;; A session window is a side window, and a side window refuses to
    ;; become the only window unless its parameters are ignored.
    (let ((ignore-window-parameters t))
      (delete-other-windows))
    (goto-char (point-min))
    (ecc-dashboard--first-row))
  (ecc-tab-blink-stop)
  (setq ecc-tab--blink-phase nil)
  (redisplay t))

(defun shot-scene-sessions-end ()
  "Answer what was left waiting and take the two invented sessions away.
A scene runs to the end: a permission nobody answered goes on blinking,
and every picture taken after it has a blinking corner."
  (dolist (request (copy-sequence (ecc-session-pending shot-waiting)))
    (ecc-perm-allow-request request))
  ;; The session leaves the model first, so that the hook on the buffer
  ;; -- which stops the CLI and forgets the session -- finds nothing left
  ;; to do.
  (dolist (session (list shot-waiting shot-exited))
    (when session
      (ecc-model-remove-session session)
      (when (buffer-live-p (ecc-session-buffer session))
        (kill-buffer (ecc-session-buffer session)))))
  (setq shot-waiting nil shot-exited nil)
  ;; The dashboard still widened the frame; the scenes after this one are
  ;; framed the way `shot-setup-frame' left it.
  (set-frame-size (selected-frame) 112 44)
  (shot-place-frame-bottom-right)
  (when-let* ((process (ecc-session-process shot-main)))
    (when (process-live-p process) (delete-process process)))
  (setf (ecc-session-process shot-main) nil)
  (ecc-model-set-state shot-main 'idle)
  (shot-show shot-main))

(defun shot-fold-tools (session)
  "Fold every tool call in the transcript of SESSION to its heading.
What the tools did is still there, a line each.  The permission of the
first turn keeps its diff, the edit the picture is about; the ones after
it are folded too, since the file the second turn writes is thirteen
lines drawn in full, and the first turn of the overview went off the
top of a screen of 900 points (2026-10-10)."
  (with-current-buffer (ecc-session-buffer session)
    (let ((first t))
      (cl-labels ((walk (nodes)
                    (dolist (node nodes)
                      (when (or (eq (ecc-node-type node) 'tool)
                                (and (not first)
                                     (eq (ecc-node-type node) 'permission)))
                        (ecc-render-hide-node (ecc-node-id node)))
                      (walk (ecc-node-children node)))))
        (dolist (turn (ecc-session-turns session))
          (walk (ecc-turn-children turn))
          (setq first nil))))))

(defun shot-scene-overview ()
  "One picture of a whole session, for the front page and for README.md.
Smaller type and as much of the screen as the capture can safely have,
so that several turns are in view at once rather than the tail of one."
  (set-frame-font "JetBrains Mono 10" nil t)
  ;; The source keeps a narrow column on the left and the transcript has
  ;; the rest, drawn wider than the 64 columns the other scenes use.
  (setq ecc-chat-text-width 88)
  (shot-reset-main)
  ;; A second turn, so the picture shows a conversation rather than an
  ;; exchange: the edit `shot-reset-main\=' replays, then the write.
  (shot-play-write shot-main)
  (shot-fold-tools shot-main)
  ;; Wide, and as tall as the conversation is.  Sized to the screen
  ;; instead, the bottom two thirds of the picture came out empty.
  ;; This one stands at the top of the screen and takes nearly all of its
  ;; height: nothing here opens a minibuffer, so it does not need the
  ;; room `shot-place-frame-bottom-right\=' keeps for one, and the whole
  ;; conversation only fits in the picture with that room spent on it.
  ;; The Spaces are what a frame looks like now: the sidebar down the
  ;; left listing every project, its worktrees and its sessions, with
  ;; the code and the conversation beside it.  The strip of tabs is left
  ;; off -- `tab-bar-show' nil -- because the sidebar is the better list
  ;; of the same thing and the picture has room for one of them.
  (require 'ecc-space)
  (require 'ecc-sidebar)
  (setq tab-bar-show nil)
  (shot-fake-git)
  ;; Not `write\=': this scene replays it into the main session itself.
  (shot-foreign-session "background")
  ;; A worktree of the demo project, with a session waiting for an
  ;; answer in it: the sidebar draws it under the repository, and the
  ;; marks of the two lists are the colour in the picture.
  (let ((root (shot-worktree-root "feat-x")))
    (make-directory root t)
    (with-temp-file (expand-file-name "summary.py" root)
      (insert shot-hero-source))
    (unless (seq-find (lambda (session)
                        (equal (ecc-session-name session) "feat-x"))
                      (ecc-model-sessions))
      (let ((session (ecc-model-create-session :name "feat-x"
                                               :project-root root)))
        (ecc-session-ensure-buffer session)
        (setf (ecc-session-cwd session) (file-name-as-directory root))
        (shot-play-to-request session "deny")
        (push session shot-worktree-sessions))))
  ;; And a session of the project running, so that the Sessions list
  ;; carries all three marks rather than a column of grey dots.
  (ecc-model-set-state shot-other 'running)
  (let* ((area (frame-monitor-workarea))
         (columns (min 160 (/ (- (nth 2 area) 48) (frame-char-width))))
         (limit (/ (- (nth 3 area) 40) (frame-char-height))))
    (set-frame-size (selected-frame) columns limit)
    (ecc-space-select (ecc-space-of-root shot-other-root))
    (ecc-space-select (ecc-space-of-root (shot-worktree-root "feat-x")))
    (ecc-space-select (ecc-space-of-root shot-root))
    ;; `tab-bar-show\=' nil is what keeps the strip off a frame that has
    ;; tabs, but a mode already on goes on drawing it: the tabs stay in
    ;; the frame either way, and this picture is of the sidebar.
    (tab-bar-mode -1)
    (shot-show shot-main)
    ;; The source window holds a file that looks like work rather than
    ;; the eight lines the recordings edit: this is the one picture a
    ;; reader meets before anything is explained.
    (when-let* ((window (get-buffer-window (get-file-buffer shot-file))))
      (with-selected-window window
        (with-temp-file shot-hero-file (insert shot-hero-source))
        (find-file shot-hero-file)))
    (ecc-sidebar-show)
    (when-let* ((window (get-buffer-window (ecc-session-buffer shot-main))))
      (ecc-chat--set-margins window)
      ;; Grow until the first line of the conversation is in view, or
      ;; until the screen runs out.  Counting the lines instead is
      ;; wrong: the transcript folds, and what is folded away is not
      ;; drawn but is still there to count.
      (set-frame-size (selected-frame) columns 30)
      (while (and (< (frame-height) limit)
                  (progn (with-selected-window window
                           (goto-char (point-max))
                           (recenter -1))
                         (redisplay t)
                         (not (pos-visible-in-window-p (point-min) window))))
        (set-frame-size (selected-frame) columns
                        (min limit (+ 4 (frame-height)))))))
  (let ((area (frame-monitor-workarea)))
    (set-frame-position (selected-frame)
                        (max (nth 0 area)
                             (- (+ (nth 0 area) (nth 2 area))
                                (frame-pixel-width) 24))
                        (+ (nth 1 area) 12)))
  ;; The three columns are given their widths last of all.  Resizing the
  ;; frame -- which the loop above does once a line until the whole
  ;; conversation is in view -- hands the new room out in proportion, so
  ;; widths set before it came back 49/88/17 of 160 columns instead of
  ;; the 28/60/72 they were given (measured 2026-09-18).
  (when-let* ((sidebar (get-buffer-window ecc-sidebar-buffer-name)))
    (ecc-sidebar--set-width sidebar))
  (when-let* ((window (get-buffer-window (get-file-buffer shot-hero-file))))
    (ignore-errors (window-resize window (- 60 (window-width window)) t)))
  (when-let* ((window (get-buffer-window (ecc-session-buffer shot-main))))
    (setq ecc-chat-text-width (max 60 (- (window-width window) 6)))
    (with-selected-window window
      (ecc-chat--set-margins window)
      (ecc-render-refresh shot-main)
      ;; And grow again now that the text has been re-wrapped to the
      ;; column it really has: the loop above measured a transcript 17
      ;; columns wide, so the frame it settled on opened this one in the
      ;; middle of a sentence.
      (let ((limit (/ (- (nth 3 (frame-monitor-workarea)) 40)
                      (frame-char-height))))
        (while (and (< (frame-height) limit)
                    (progn (goto-char (point-max))
                           (recenter -1)
                           (redisplay t)
                           (not (pos-visible-in-window-p (point-min) window))))
          (set-frame-size (selected-frame) (frame-width)
                          (min limit (+ 4 (frame-height))))))
      (goto-char (point-max))
      (recenter -1)))
  (message nil)
  ;; The frame was resized and moved a moment ago, and the capture is of
  ;; the screen: without this the picture came out with the old contents
  ;; drawn again below the new ones.
  (redraw-display)
  (redisplay t))

(defun shot-scene-overview-end ()
  "Put the frame back to the type and the size every other scene wants."
  (ecc-sidebar-hide)
  (setq tab-bar-show t)
  (tab-bar-mode -1)
  (shot-unfake-git)
  (setq ecc-chat-text-width 64)
  (set-frame-font "JetBrains Mono 13" nil t)
  (set-frame-size (selected-frame) 112 44)
  (shot-place-frame-bottom-right)
  (redisplay t))

(defun shot-setup-frame ()
  "Size and dress the frame, then write its geometry out for capture."
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (set-fringe-mode 8)
  (blink-cursor-mode -1)
  (set-frame-font "JetBrains Mono 13" nil t)
  (setq-default line-spacing 0.1)
  ;; Tall enough for `ecc-menu', which is two rows of columns and the
  ;; longest of them has ten lines.
  (when-let* ((foreign (shot-foreign-ecc)))
    (error "Not this checkout's ecc: %S" foreign))
  ;; The title formats are not always what the title is: with a
  ;; completion list open in a frame of its own, the frame lost the
  ;; title the recorder finds it by, and the picture was never taken
  ;; (2026-10-10).  A name of the frame's own is its title throughout.
  (set-frame-parameter nil 'name shot-frame-title)
  (set-frame-size (selected-frame) 112 44)
  (redisplay t)
  (shot-place-frame-bottom-right)
  (raise-frame)
  (x-focus-frame nil)
  ;; A light inline session and a rewrite each run a CLI of their own,
  ;; and both are asked for the cheap model, as this file's sessions are.
  (setq ecc-inline-binding 'light
        ecc-inline-light-args '("--tools" "" "--model" "haiku"
                                "--max-budget-usd" "0.10")
        ecc-rewrite-model "haiku")
  ;; The candidates are worth seeing as a list.
  (cond
   ((featurep 'vertico)
    (setq vertico-count 8)
    (vertico-mode 1)
    (when (featurep 'vertico-posframe)
      (setq vertico-posframe-border-width 5
            vertico-posframe-parameters '((left-fringe . 8) (right-fringe . 8)))
      (set-face-background 'vertico-posframe-border "#323445" nil)
      (vertico-posframe-mode 1)))
   (t
    (fido-vertical-mode 1)
    (setq icomplete-prospects-height 8)))
  (shot-prepare)
  (shot-show shot-main)
  (setq server-name "ecc-docshot")
  (server-start)
  (shot-report-geometry))

(add-hook 'window-setup-hook
          (lambda ()
            (run-at-time
             1.5 nil
             (lambda ()
               (condition-case err (shot-setup-frame)
                 (error (with-temp-file shot-error-file
                          (insert (format "%S" err)))))))))

;;; docshots.el ends here
