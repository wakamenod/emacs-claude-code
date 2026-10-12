;;; ecc-mermaid.el --- Mermaid diagrams in the transcript  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Maintainer: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; URL: https://github.com/wakamenod/emacs-claude-code
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A fenced block whose language is `mermaid' is drawn as the diagram
;; it describes, by mermaid-cli (`mmdc') in the background.
;;
;; Nothing waits for a diagram, and nothing is drawn again for one.
;; The block goes into the transcript as the code block it is, and
;; `ecc-markdown' hands each closed one to `ecc-mermaid--mark' as it is
;; fontified, which puts the `ecc-mermaid' property on its body: the
;; source, the arguments it is drawn with and the hash of both, which
;; names the picture on disk.  As the renderer inserts the text it calls
;; `ecc-mermaid-show', which puts a picture that is on disk already over
;; the body with a `display' property and asks for one that is not.
;; The jobs run one at a time.  When one finishes, the picture is put
;; over every block of that hash in the buffers that asked for it: a
;; change of property, so no text moves, no marker is walked and no
;; redraw is asked for.  The source stays in the buffer under the
;; picture, so a search and a copy still find it, and
;; `ecc-mermaid-toggle' shows it in place of the picture.
;;
;; There is no setting.  The diagrams are drawn where `mmdc' is found,
;; in a frame that draws images, while `ecc-image-inline' is on, and
;; `ecc-mermaid-command' set to nil turns them off.
;;
;; It sits below `ecc-render', as `ecc-image' does, and above
;; `ecc-markdown', which does not know it is here.

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'ecc-core)
(require 'ecc-image)
(require 'ecc-markdown)

;;;; Options

(defvar ecc-mermaid-command "mmdc"
  "The mermaid-cli program, or nil to draw no diagrams.
It is looked for on the variable `exec-path' once, the first time a
diagram is drawn; a block is left as code where it is not found.")

(defvar ecc-mermaid-arguments '("-s" "2" "-b" "transparent")
  "Arguments `ecc-mermaid-command' draws a diagram with.
The input, the output and `-q' are put in front of these, and `-t
dark' as well when the frame is dark.  `-s 2' draws at twice the size
and `ecc-mermaid-scale' shows it at half, which keeps the lines sharp on
a screen of two pixels a point.  The arguments are part of what names a
picture on disk, so changing them draws every diagram again.")

(defvar ecc-mermaid-scale 0.5
  "Scale a diagram is shown at: the inverse of the `-s' it was drawn with.")

(defvar ecc-mermaid-timeout 20
  "Seconds a diagram may take before its job is killed.
mmdc starts a browser for each one: 2.2 seconds cold and 0.35 warm on
the Mac this was written on (2026-10-12).  A job that has not finished
after this is taken for a hang, and its block stays code.")

(defvar ecc-mermaid-directory (expand-file-name "ecc-mermaid" temporary-file-directory)
  "Directory the pictures are kept in, one file per hash.
It is not `ecc-image-dir': that is per session and deleted when the
session ends, and a diagram drawn once is worth keeping for the next
session that shows it, a restored one included.")

(defface ecc-mermaid-error-face
  '((t :inherit error :weight normal))
  "Face for the first line of a diagram mmdc could not draw.
The reason is in its `help-echo' and in the log of the session."
  :group 'ecc)

;;;; State

(defvar ecc-mermaid--program nil
  "(COMMAND . PATH): the last `ecc-mermaid-command' looked for, and where it was.
PATH is nil when it was not found.  `executable-find' walks the whole
of PATH, and this is asked on every draw of a diagram.")

(defvar ecc-mermaid--state (make-hash-table :test #'equal)
  "What became of each hash asked for: `queued', `running' or (failed . WHY).
A hash whose picture is on disk is not in here.  A failure stays for
the rest of the Emacs session, so that a source mmdc cannot read is
tried once and not on every redraw.")

(defvar ecc-mermaid--waiting (make-hash-table :test #'equal)
  "Hash of a picture not made yet to the buffers that showed its source.")

(defvar ecc-mermaid--queue nil
  "The jobs waiting, first one first: each (HASH SOURCE ARGUMENTS LOG-NAME).")

(defvar ecc-mermaid--process nil
  "The mmdc running, or nil.")

(defvar ecc-mermaid--kick nil
  "The timer that starts the next job, or nil.")

(defvar-local ecc-mermaid--sources nil
  "Hashes of the diagrams this buffer shows as source, by `ecc-mermaid-toggle'.")

;;;; Marking a block

(defun ecc-mermaid-program ()
  "Return the mermaid-cli to run, or nil when there is none."
  (when ecc-mermaid-command
    (unless (equal (car ecc-mermaid--program) ecc-mermaid-command)
      (setq ecc-mermaid--program
            (cons ecc-mermaid-command (executable-find ecc-mermaid-command))))
    (cdr ecc-mermaid--program)))

(defun ecc-mermaid--arguments ()
  "Return the arguments a diagram is drawn with in the selected frame."
  (append (and (eq (frame-parameter nil 'background-mode) 'dark)
               '("-t" "dark"))
          ecc-mermaid-arguments))

(defun ecc-mermaid--mark (language start end)
  "Mark the body from START to END as a diagram when LANGUAGE is mermaid.
Called by `ecc-markdown-fontify' on each closed block, in the buffer
it fontifies.  The mark is made whether or not a diagram will be
drawn: the fontified text is kept and drawn again, and a mark left out
because mmdc was missing then would stay out once it is there.  It
costs a hash of the block."
  (when (and language (string= (downcase language) "mermaid") (< start end))
    (let* ((source (buffer-substring-no-properties start end))
           (arguments (ecc-mermaid--arguments)))
      ;; One value for the whole body: the lines of a block are split
      ;; and indented apart when they are drawn, and `eq' values are
      ;; how the runs are known again as one block.
      (put-text-property start end 'ecc-mermaid
                         (list (sha1 (prin1-to-string (cons source arguments)))
                               source arguments)))))

(add-hook 'ecc-markdown-code-block-functions #'ecc-mermaid--mark)

(defun ecc-mermaid--file (hash)
  "Return the file the picture of HASH is kept in."
  (expand-file-name (concat hash ".png") ecc-mermaid-directory))

(defun ecc-mermaid--enabled-p ()
  "Return non-nil when diagrams are drawn here at all."
  (and ecc-image-inline
       (display-graphic-p)
       (image-type-available-p 'png)
       (ecc-mermaid-program)))

;;;; Finding a block in the buffer

(defun ecc-mermaid--gap-p (from to)
  "Return non-nil when FROM to TO holds only line breaks and indentation.
That is what the renderer puts between two lines of one block."
  (save-excursion
    (goto-char from)
    (skip-chars-forward " \t\n" to)
    (= (point) to)))

(defun ecc-mermaid--run-end (pos limit)
  "Return where the run of `ecc-mermaid' at POS ends, at most LIMIT."
  (next-single-property-change pos 'ecc-mermaid nil limit))

(defun ecc-mermaid--block-end (pos limit)
  "Return the end of the block whose run starts at POS, at most LIMIT.
The runs of one block carry one `eq' value and stand apart only by a
newline and the indentation of the next line."
  (let ((value (get-text-property pos 'ecc-mermaid))
        (end (ecc-mermaid--run-end pos limit))
        (next nil))
    (while (and (< end limit)
                (null (get-text-property end 'ecc-mermaid))
                (setq next (ecc-mermaid--run-end end limit))
                (< next limit)
                (eq (get-text-property next 'ecc-mermaid) value)
                (ecc-mermaid--gap-p end next))
      (setq end (ecc-mermaid--run-end next limit)))
    end))

(defun ecc-mermaid--block-start (pos)
  "Return the start of the block of the `ecc-mermaid' run at POS."
  (let* ((value (get-text-property pos 'ecc-mermaid))
         (start (or (previous-single-property-change (1+ pos) 'ecc-mermaid)
                    (point-min)))
         (before nil))
    (while (and (> start (point-min))
                (setq before (previous-single-property-change start 'ecc-mermaid))
                (> before (point-min))
                (eq (get-text-property (1- before) 'ecc-mermaid) value)
                (ecc-mermaid--gap-p before start))
      (setq start (or (previous-single-property-change before 'ecc-mermaid)
                      (point-min))))
    start))

(defun ecc-mermaid--blocks (start end)
  "Return the diagrams between START and END, each (VALUE FROM TO).
VALUE is the `ecc-mermaid' property: (HASH SOURCE ARGUMENTS)."
  (let ((pos start)
        (blocks nil))
    (while (and (< pos end)
                (setq pos (text-property-not-all pos end 'ecc-mermaid nil)))
      (let ((to (ecc-mermaid--block-end pos end)))
        (push (list (get-text-property pos 'ecc-mermaid) pos to) blocks)
        (setq pos to)))
    (nreverse blocks)))

(defun ecc-mermaid-block-at (&optional pos)
  "Return the diagram at POS, the point by default, as (VALUE FROM TO).
Nil when there is none.
The point may stand on the indentation in front of a line of it, or at
the end of the last: that is where it lands beside a picture."
  (let* ((pos (or pos (point)))
         (bol (save-excursion (goto-char pos) (line-beginning-position)))
         (eol (save-excursion (goto-char pos) (line-end-position)))
         (at (cond ((get-text-property pos 'ecc-mermaid) pos)
                   ((let ((next (next-single-property-change pos 'ecc-mermaid nil eol)))
                      (and (< next eol) next)))
                   ((and (> pos bol) (get-text-property (1- pos) 'ecc-mermaid))
                    (1- pos)))))
    (when at
      (let ((from (ecc-mermaid--block-start at)))
        (list (get-text-property at 'ecc-mermaid)
              from
              (ecc-mermaid--block-end from (point-max)))))))

;;;; Putting a picture in

(defun ecc-mermaid--image (file from)
  "Return the image of FILE, fitted to the window, for the block at FROM."
  (let ((indent (string-width (buffer-substring-no-properties
                               (save-excursion (goto-char from) (line-beginning-position))
                               from))))
    (create-image file 'png nil
                  :scale ecc-mermaid-scale
                  :max-width (ecc-image-width indent)
                  :ascent 'center)))

(defun ecc-mermaid--put-picture (file from to)
  "Show the picture FILE over the block from FROM to TO."
  (with-silent-modifications
    (add-text-properties from to
                         (list 'display (ecc-mermaid--image file from)
                               'help-echo "mermaid: I shows the source"))))

(defun ecc-mermaid--put-failure (why from to)
  "Say on the block from FROM to TO that it could not be drawn, and WHY.
No text goes in: the reason is the `help-echo' of the block, and its
first line is drawn in `ecc-mermaid-error-face'."
  (with-silent-modifications
    (put-text-property from to 'help-echo (concat "mermaid: " why))
    (add-face-text-property from (save-excursion (goto-char from)
                                                 (min to (line-end-position)))
                            'ecc-mermaid-error-face)))

(defun ecc-mermaid--show-block (value from to log-name)
  "Put the picture of VALUE over FROM to TO, or ask for it.
LOG-NAME is the session the failure of a job is logged under."
  (pcase-let ((`(,hash ,source ,arguments) value))
    (unless (member hash ecc-mermaid--sources)
      (let ((file (ecc-mermaid--file hash)))
        (if (file-exists-p file)
            (ecc-mermaid--put-picture file from to)
          (pcase (gethash hash ecc-mermaid--state)
            (`(failed . ,why) (ecc-mermaid--put-failure why from to))
            (state
             (cl-pushnew (current-buffer) (gethash hash ecc-mermaid--waiting))
             (unless state
               (ecc-mermaid--enqueue hash source arguments log-name)))))))))

(defun ecc-mermaid-wanted-p (text)
  "Return non-nil when TEXT, as fontified, holds a diagram to draw here."
  (and (ecc-mermaid--enabled-p)
       (text-property-not-all 0 (length text) 'ecc-mermaid nil text)))

(defun ecc-mermaid-show (start end &optional log-name)
  "Put in the diagrams between START and END, or ask for them.
Called by the renderer on text it has just inserted.  A picture on disk
is put on at once; one that is not is queued, and put on when it is
made.  LOG-NAME is the session a failure is logged under."
  (when (ecc-mermaid--enabled-p)
    (pcase-dolist (`(,value ,from ,to) (ecc-mermaid--blocks start end))
      (ecc-mermaid--show-block value from to (or log-name "mermaid")))))

(defun ecc-mermaid--place (hash)
  "Put the picture of HASH, or why there is none, where it was asked for.
Only text that is read-only is looked at: the transcript is, and a
block yanked into the draft is the user's to write."
  (let ((buffers (gethash hash ecc-mermaid--waiting)))
    (remhash hash ecc-mermaid--waiting)
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (pcase-dolist (`(,value ,from ,to) (ecc-mermaid--blocks (point-min) (point-max)))
              (when (and (equal (car value) hash)
                         (get-text-property from 'read-only))
                (ecc-mermaid--show-block value from to nil)))))))))

;;;; The jobs

(defun ecc-mermaid--enqueue (hash source arguments log-name)
  "Queue the drawing of SOURCE with ARGUMENTS as HASH.
LOG-NAME is the session a failure is logged under.  The job is started
from a timer rather than here: this is called from the middle of a
draw."
  (puthash hash 'queued ecc-mermaid--state)
  (setq ecc-mermaid--queue
        (nconc ecc-mermaid--queue (list (list hash source arguments log-name))))
  (unless (or ecc-mermaid--process ecc-mermaid--kick)
    (setq ecc-mermaid--kick (run-at-time 0 nil #'ecc-mermaid--next))))

(defun ecc-mermaid--next ()
  "Start the next job when none is running."
  (setq ecc-mermaid--kick nil)
  (unless (process-live-p ecc-mermaid--process)
    (setq ecc-mermaid--process nil)
    (let (job)
      (while (and (null ecc-mermaid--process)
                  (setq job (pop ecc-mermaid--queue)))
        (apply #'ecc-mermaid--start job)))))

(defun ecc-mermaid--error-message (output)
  "Return what mmdc's OUTPUT says went wrong, without the stack under it.
mmdc 12.0.0 prints the error of Mermaid's parser and then the
JavaScript stack it was thrown through, a dozen lines of paths into
node_modules (2026-10-12)."
  (let ((lines nil))
    (catch 'stack
      (dolist (line (split-string (string-trim (or output "")) "\n"))
        (when (string-match-p "\\`[ \t]*at \\|([a-z]+://" line)
          (throw 'stack nil))
        (push line lines)))
    (let ((message (string-trim (string-join (nreverse lines) "\n"))))
      (if (string-empty-p message) "mmdc failed and said nothing" message))))

(defun ecc-mermaid--fail (hash why log-name)
  "Record that HASH could not be drawn, and WHY, in the log of LOG-NAME."
  (puthash hash (cons 'failed why) ecc-mermaid--state)
  (ecc-log log-name "mermaid: %s" why)
  (ecc-mermaid--place hash))

(defun ecc-mermaid--start (hash source arguments log-name)
  "Start drawing SOURCE with ARGUMENTS into the picture of HASH.
LOG-NAME is the session a failure is logged under."
  (make-directory ecc-mermaid-directory t)
  (let* ((input (expand-file-name (concat hash ".mmd") ecc-mermaid-directory))
         ;; A PNG and not an SVG: Mermaid's SVG puts every label in a
         ;; <foreignObject> of HTML, and librsvg, which draws an SVG in
         ;; Emacs, draws the boxes and arrows without a word in them
         ;; (mmdc 12.0.0 and rsvg-convert, 2026-10-12).  mmdc picks the
         ;; format by the extension, so the file it writes ends in .png
         ;; too; it is renamed once whole, so that a picture half
         ;; written is never taken for one.
         (output (expand-file-name (concat hash "-part.png") ecc-mermaid-directory))
         (buffer (generate-new-buffer " *ecc-mermaid*" t)))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region source nil input nil 'silent))
    (puthash hash 'running ecc-mermaid--state)
    (condition-case err
        (let ((process
               (make-process
                :name "ecc-mermaid"
                :buffer buffer
                :noquery t
                :connection-type 'pipe
                :command (append (list (ecc-mermaid-program) "-q" "-i" input "-o" output)
                                 arguments))))
          (process-put process 'ecc-mermaid-timer
                       (run-at-time ecc-mermaid-timeout nil
                                    #'ecc-mermaid--timed-out process))
          (set-process-sentinel
           process
           (lambda (process _event)
             (unless (process-live-p process)
               (ecc-mermaid--finished process hash input output log-name))))
          (setq ecc-mermaid--process process))
      (error
       (kill-buffer buffer)
       (delete-file input)
       (ecc-mermaid--fail hash (format "could not start %s: %s"
                                       ecc-mermaid-command
                                       (error-message-string err))
                          log-name)))))

(defun ecc-mermaid--timed-out (process)
  "Kill PROCESS, which has taken longer than `ecc-mermaid-timeout'."
  (when (process-live-p process)
    (process-put process 'ecc-mermaid-timed-out t)
    (delete-process process)))

(defun ecc-mermaid--finished (process hash input output log-name)
  "Take the picture of HASH that PROCESS drew from INPUT into OUTPUT.
LOG-NAME is the session a failure is logged under.  The next job is
started whatever became of this one."
  (unwind-protect
      (let ((said (when (buffer-live-p (process-buffer process))
                    (prog1 (with-current-buffer (process-buffer process) (buffer-string))
                      (kill-buffer (process-buffer process))))))
        (cancel-timer (process-get process 'ecc-mermaid-timer))
        (when (file-exists-p input) (delete-file input))
        (if (and (eq (process-status process) 'exit)
                 (zerop (process-exit-status process))
                 (file-exists-p output))
            (progn
              (rename-file output (ecc-mermaid--file hash) t)
              (remhash hash ecc-mermaid--state)
              (ecc-mermaid--place hash))
          (when (file-exists-p output) (delete-file output))
          (ecc-mermaid--fail
           hash
           (if (process-get process 'ecc-mermaid-timed-out)
               (format "no diagram after %s seconds" ecc-mermaid-timeout)
             (ecc-mermaid--error-message said))
           log-name)))
    (when (eq process ecc-mermaid--process)
      (setq ecc-mermaid--process nil))
    (ecc-mermaid--next)))

;;;; Picture or source

(defun ecc-mermaid-toggle ()
  "Show the diagram at point as its source, or the source as the diagram.
What is chosen holds for that diagram in this buffer until it is
toggled again, a redraw included."
  (interactive)
  (pcase-let ((`(,value ,from ,to) (or (ecc-mermaid-block-at)
                                       (user-error "No diagram here"))))
    (let ((hash (car value)))
      (if (get-text-property from 'display)
          (progn
            (push hash ecc-mermaid--sources)
            (with-silent-modifications
              (remove-text-properties from to '(display nil help-echo nil)))
            (goto-char from)
            (message "Source"))
        (setq ecc-mermaid--sources (delete hash ecc-mermaid--sources))
        (ecc-mermaid--show-block value from to nil)
        (message (cond ((get-text-property from 'display) "Diagram")
                       ((not (ecc-mermaid--enabled-p)) "Diagrams are not drawn here")
                       ((eq (car-safe (gethash hash ecc-mermaid--state)) 'failed)
                        (concat "mermaid: " (cdr (gethash hash ecc-mermaid--state))))
                       (t "The diagram is not drawn yet")))))))

(provide 'ecc-mermaid)

;;; ecc-mermaid.el ends here
