;;; ecc-review-pr.el --- Review a GitHub pull request  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
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

;; `p' in `ecc-review-menu' reviews a pull request of GitHub.  The `gh'
;; CLI is asked which pull requests there are and what their two sides
;; are -- and only then, when `p' is pressed: the menu offers `p' when
;; gh is installed and asks nothing of it.  gh is no dependency, and
;; what it says when it fails -- not logged in, no GitHub remote -- is
;; what the user is told.
;;
;; The question offers the open pull requests, gh's first page, and
;; before them a choice that searches; words submitted that are no
;; line and no number search as well, in GitHub's syntax, open, closed
;; and merged ones alike.  A completion UI that starts with a candidate
;; selected returns it on RET whenever one matches the words, so there
;; they are submitted as typed with that UI's own key (vertico M-RET);
;; no key is bound here, M-s being `next-matching-history-element'.
;; gh runs when the answer is given, not as it is typed:
;; `completing-read' has no way to change its candidates while it
;; waits, and `ecc-review-pr--complete', the one place the question is
;; put, is what a search as one types would take the place of.
;;
;; The diff is made by the local git, from the commits gh names: what a
;; review shows on the left and on the right are whole files, which a
;; patch from `gh pr diff' does not have.  A pull request of another
;; branch is BASE...HEAD by id, the files GitHub shows as changed, and
;; one whose head is the branch checked out here is that branch with
;; its working tree against where it parted from the base, as `b' of the
;; current branch is: Claude edits the files on disk, and the comments
;; have to be on their lines.  The commits are fetched only when this
;; repository does not have them, into FETCH_HEAD alone: no branch, no
;; ref, and the working tree and HEAD are not touched.
;;
;; A pull request is read a commit at a time as well.  Once one is
;; chosen, `p' asks for one of its commits, the whole of it by default,
;; and either way the review knows the pull request it is a part of
;; (`ecc-review-pr-walk'): ] and [ open the next and the previous
;; commit in its place, in the same window.  Each commit is a review of
;; its own, X^!, with comments of its own: the diff review left by ] is
;; kept while it holds any, and an ediff review, which takes the frame
;; and is quit to make room for the next, leaves them with the pull
;; request until it is opened again.  C-c C-c sends the comments of the
;; one review; C-c C-a sends those of every review of the pull request
;; as one prompt, a group per commit, so that Claude reads all of them
;; before changing anything.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-review)

(declare-function ecc-review-ediff-quit "ecc-review-ediff" (control))
(declare-function ecc-review-ediff-range-buffer "ecc-review-ediff"
                  (session &optional range root paths))
(declare-function ecc-review-direct-refresh-headers "ecc-review-direct" (control))

(defvar ecc-review-gh-executable "gh"
  "The gh program `p' in `ecc-review-menu' asks for pull requests.")

(defvar ecc-review-pr-fields
  "number,title,state,headRefName,baseRefName,headRefOid,baseRefOid,author,isDraft,isCrossRepository,url"
  "The fields of a pull request asked of gh, as its --json takes them.")

(defvar ecc-review-pr-search-label "Search pull requests…"
  "The choice of `p' in `ecc-review-menu' that asks for words to search with.")

(defvar ecc-review-pr--history nil
  "Pull requests typed at the question of `p'.")

(defvar ecc-review-pr--search-history nil
  "Searches typed at the question of `p'.")

(defvar ecc-review-pr--commit-history nil
  "Commits typed at the question of `p' that asks for one.")

(defun ecc-review-pr-available-p ()
  "Return non-nil when gh is installed, so that `p' is offered."
  (executable-find ecc-review-gh-executable))

;;;; Running gh and git

(defun ecc-review-pr--run (program directory &rest args)
  "Run PROGRAM with ARGS in DIRECTORY and return what it prints.
A failure is a `user-error' carrying what PROGRAM said on stderr.
Neither program may ask anything: there is no terminal to answer on."
  (let ((stderr (make-temp-file "ecc-review-pr"))
        (process-environment (append '("GH_PROMPT_DISABLED=1" "GH_NO_UPDATE_NOTIFIER=1"
                                       "NO_COLOR=1" "GIT_TERMINAL_PROMPT=0")
                                     process-environment))
        (default-directory (file-name-as-directory directory))
        ;; gh prints its JSON in UTF-8 whatever the locale says, and a
        ;; GUI Emacs started without LANG would read a Japanese title
        ;; through another coding system.
        (coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8))
    (unwind-protect
        (with-temp-buffer
          (let ((code (condition-case err
                          (apply #'call-process program nil (list t stderr) nil args)
                        (file-error
                         (user-error "Cannot run %s: %s" program (error-message-string err))))))
            (unless (eq code 0)
              (user-error "%s %s failed: %s" (file-name-nondirectory program)
                          (string-join args " ")
                          (let ((said (string-trim (with-temp-buffer
                                                     (insert-file-contents stderr)
                                                     (buffer-string)))))
                            (if (string-empty-p said) (format "exit %s" code) said))))
            (buffer-string)))
      (delete-file stderr))))

(defun ecc-review-pr--gh (root &rest args)
  "Run gh with ARGS in ROOT and return what it prints."
  (apply #'ecc-review-pr--run ecc-review-gh-executable root args))

;;;; What gh says

(defun ecc-review-pr--parse-one (object)
  "Return the pull request OBJECT of gh's JSON as a plist.
:number, :title, :state (`open', `closed' or `merged'), :head and
:base (the branch names), :head-oid and :base-oid, :author (a login),
:draft, :cross (the head is in another repository) and :url."
  (let ((get (lambda (key) (plist-get object key))))
    (list :number (funcall get :number)
          :title (or (funcall get :title) "")
          :state (when-let* ((state (funcall get :state)))
                   (intern (downcase state)))
          :head (funcall get :headRefName)
          :base (funcall get :baseRefName)
          :head-oid (funcall get :headRefOid)
          :base-oid (funcall get :baseRefOid)
          :author (plist-get (funcall get :author) :login)
          :draft (eq (funcall get :isDraft) t)
          :cross (eq (funcall get :isCrossRepository) t)
          :url (funcall get :url))))

(defun ecc-review-pr-parse (json)
  "Return the pull requests JSON, what gh prints, names: a list of plists.
JSON is an array of them or one; see `ecc-review-pr--parse-one'."
  (let ((value (json-parse-string json :object-type 'plist :array-type 'list
                                  :null-object nil :false-object :false)))
    (mapcar #'ecc-review-pr--parse-one
            (if (and (consp value) (keywordp (car value))) (list value) value))))

(defun ecc-review-pr-list (root)
  "Return the open pull requests of the repository of ROOT, as gh orders them."
  (ecc-review-pr-parse (ecc-review-pr--gh root "pr" "list" "--json" ecc-review-pr-fields)))

(defun ecc-review-pr-search (root query)
  "Return the pull requests of the repository of ROOT that QUERY finds.
QUERY is in GitHub's search syntax, and open, closed and merged ones
alike are found, as gh orders them."
  (ecc-review-pr-parse (ecc-review-pr--gh root "pr" "list" "--search" query
                                          "--state" "all" "--json" ecc-review-pr-fields)))

(defun ecc-review-pr-view (root number)
  "Return the pull request NUMBER of the repository of ROOT, open or not."
  (car (ecc-review-pr-parse (ecc-review-pr--gh root "pr" "view" (number-to-string number)
                                               "--json" ecc-review-pr-fields))))

;;;; Asking which

(defun ecc-review-pr-line (pr)
  "Return PR as a line to choose: number, state, title, branches and author.
The state is said when the pull request is closed or merged.  The title
is put on one line: a tab or a newline in it would break the list."
  (format "#%d  %s%s%s  %s → %s  @%s"
          (plist-get pr :number)
          (pcase (plist-get pr :state)
            ('merged "[merged] ")
            ('closed "[closed] ")
            (_ ""))
          (if (plist-get pr :draft) "[draft] " "")
          (ecc--truncate (string-trim (replace-regexp-in-string
                                       "[ \t\n\r]+" " " (plist-get pr :title)))
                         72)
          (plist-get pr :head) (plist-get pr :base)
          (or (plist-get pr :author) "?")))

(defun ecc-review-pr-own-p (pr branch)
  "Return non-nil when PR is of BRANCH, the branch checked out here.
Its head has that name and is in this repository, not in a fork: the
main of a fork is not the main checked out here.  A closed or merged
pull request is what it was, BASE...HEAD, whatever is checked out now:
a branch of that name may be newer work, or the next pull request."
  (and branch
       (equal (plist-get pr :head) branch)
       (not (plist-get pr :cross))
       (memq (plist-get pr :state) '(nil open))))

(defun ecc-review-pr-default (prs branch)
  "Return the one of PRS that is of BRANCH (`ecc-review-pr-own-p'), or nil."
  (seq-find (lambda (pr) (ecc-review-pr-own-p pr branch)) prs))

(defun ecc-review-pr-choose (root answer prs)
  "Return the pull request ANSWER names in ROOT, PRS being those offered.
A line of PRS is that one; a number, with or without #, is the one of
PRS of that number, or asked of gh -- a closed or merged one need not
be listed.  `ecc-review-pr-search-label' is (search), and other words
are (search . WORDS), to be searched for."
  (save-match-data
    (let ((answer (string-trim answer)))
      (cond ((string-empty-p answer)
             (user-error "Choose a pull request, type its number or words to search"))
            ((equal answer ecc-review-pr-search-label) (list 'search))
            ((seq-find (lambda (pr) (equal (ecc-review-pr-line pr) answer)) prs))
            ((string-match "\\`#?\\([0-9]+\\)\\'" answer)
             (let ((number (string-to-number (match-string 1 answer))))
               (or (seq-find (lambda (pr) (eql (plist-get pr :number) number)) prs)
                   (ecc-review-pr-view root number))))
            (t (cons 'search answer))))))

(defun ecc-review-pr--complete (prompt prs default table-function)
  "Ask with PROMPT for one of PRS and return the answer, a string.
DEFAULT, a line, is taken on an empty answer, and
`ecc-review-pr-search-label' comes first; TABLE-FUNCTION makes the
completion table of the lines, in their order.  This is the one place
the question is put, for one that searches as the words are typed to
take."
  (let ((lines (cons ecc-review-pr-search-label (mapcar #'ecc-review-pr-line prs))))
    (completing-read prompt (if table-function (funcall table-function lines) lines)
                     nil nil nil 'ecc-review-pr--history default)))

(defun ecc-review-pr--read-query ()
  "Ask for the words to search pull requests with."
  (read-string "Search pull requests (GitHub search: is:merged, author:NAME, label:NAME…): "
               nil 'ecc-review-pr--search-history))

(defun ecc-review-pr-read (root branch &optional table-function)
  "Ask for a pull request of the repository of ROOT and return it.
The open ones are offered as gh lists them, the one of BRANCH, the
branch checked out, by default, after `ecc-review-pr-search-label'.
That, or words that are no line and no number, search open, closed and
merged ones alike (`ecc-review-pr-search'), and what is found is
offered the same way; a search that finds nothing says so and the
question is put again.  gh runs only on an answer, never on a key.
TABLE-FUNCTION makes the completion table of the lines, in their
order."
  (let ((prs (ecc-review-pr-list root))
        (query nil)
        (missed nil)
        (chosen nil))
    (while (not chosen)
      (let* ((default (when-let* ((pr (ecc-review-pr-default prs branch)))
                        (ecc-review-pr-line pr)))
             (prompt (cond (missed
                            (format-prompt "No pull request matches \"%s\"; search again or choose"
                                           default missed))
                           (query
                            (format-prompt "Pull requests matching \"%s\"" default query))
                           (prs
                            (format-prompt "Review the pull request (or its number, or words)"
                                           default))
                           (t "No open pull request; type a number or words to search: ")))
             (answer (ecc-review-pr-choose
                      root (ecc-review-pr--complete prompt prs default table-function) prs)))
        (setq missed nil)
        (if (not (eq (car-safe answer) 'search))
            (setq chosen answer)
          (let ((words (string-trim (or (cdr answer) (ecc-review-pr--read-query)))))
            (unless (string-empty-p words)
              (let ((found (ecc-review-pr-search root words)))
                (if found
                    (setq prs found query words)
                  (setq missed words))))))))
    chosen))

;;;; Having the commits

(defun ecc-review-pr--has-commit-p (root oid)
  "Return non-nil when the repository of ROOT has the commit OID."
  (eq 0 (car (ecc-review--git root "cat-file" "-e" (concat oid "^{commit}")))))

(defun ecc-review-pr--repo-of-url (url)
  "Return (HOST . OWNER/REPO) of URL, a remote or a pull request, lowercased.
git@host:o/r.git, ssh://git@host/o/r, https://host/o/r(.git) and
https://host/o/r/pull/N all come out the same; a path names no host,
and its last two directories are OWNER/REPO.  Nil when there are not
two."
  (save-match-data
    (let* ((url (downcase (string-trim url)))
           (host (cond ((string-match "\\`[a-z][a-z0-9+.-]*://\\(?:[^@/]*@\\)?\\([^/:]+\\)" url)
                        (match-string 1 url))
                       ((string-match "\\`\\(?:[^@/]*@\\)?\\([^/:]+\\):" url)
                        (match-string 1 url))))
           (path (replace-regexp-in-string "/pull/[0-9]+.*\\'" "" url))
           (parts (last (split-string (string-remove-suffix
                                       ".git" (string-remove-suffix "/" path))
                                      "[/:]" t)
                        2)))
      (when (= (length parts) 2)
        (cons host (string-join parts "/"))))))

(defun ecc-review-pr-remote (root url)
  "Return the remote of ROOT that is the repository of the pull request URL.
The one whose URL names the same owner and repository on the same host,
else the same owner and repository, else URL's repository itself, to be
fetched from by its address."
  (let* ((want (or (ecc-review-pr--repo-of-url url)
                   (user-error "Cannot tell the repository of %s" url)))
         (remotes (pcase (ecc-review--git root "config" "--get-regexp"
                                          "^remote\\..*\\.url$")
                    (`(0 . ,output)
                     (mapcar (lambda (line)
                               (let ((pair (split-string line " ")))
                                 (cons (replace-regexp-in-string
                                        "\\`remote\\.\\|\\.url\\'" "" (car pair))
                                       (ecc-review-pr--repo-of-url
                                        (string-join (cdr pair) " ")))))
                             (split-string output "\n" t)))))
         (same (seq-filter (lambda (remote) (equal (cddr remote) (cdr want))) remotes)))
    (or (car (seq-find (lambda (remote) (equal (cadr remote) (car want))) same))
        (car (car same))
        (format "https://%s/%s.git" (car want) (cdr want)))))

(defun ecc-review-pr-fetch (root pr oids)
  "Make sure the repository of ROOT has OIDS, the commits of PR it needs.
Only what is missing is fetched, from its repository
\(`ecc-review-pr-remote') into FETCH_HEAD alone: refs/pull/N/head for
the head -- there for a pull request from a fork as well -- and then,
when the base is still missing, the base branch, whose commit is often
one the head brought along.  The base branch of a merged pull request
may have been deleted since; that fetch failing is an error only when
the base is still missing after it, and the error says what git said.
--refmap= keeps git from moving the remote-tracking branch of the base
on the way.  Return non-nil when something was fetched."
  (when (seq-remove (lambda (oid) (ecc-review-pr--has-commit-p root oid)) oids)
    (let* ((number (plist-get pr :number))
           (remote (ecc-review-pr-remote root (plist-get pr :url)))
           (missing (lambda (key)
                      (let ((oid (plist-get pr key)))
                        (and (member oid oids) (not (ecc-review-pr--has-commit-p root oid))))))
           (fetch (lambda (refspec)
                    (ecc-review-pr--run ecc-review-git-executable root
                                        "fetch" "--quiet" "--no-tags" "--recurse-submodules=no"
                                        "--refmap=" remote refspec)))
           (failed nil))
      (message "Fetching pull request #%d from %s..." number remote)
      (when (funcall missing :head-oid)
        (funcall fetch (format "pull/%d/head" number)))
      (when (funcall missing :base-oid)
        (condition-case err
            (funcall fetch (plist-get pr :base))
          (user-error (setq failed (error-message-string err)))))
      (dolist (oid oids)
        (unless (ecc-review-pr--has-commit-p root oid)
          (user-error "Pull request #%d: %s is not in %s even after fetching it%s"
                      number oid remote (if failed (concat "; " failed) ""))))
      t)))

;;;; What a pull request compares

(defun ecc-review-pr-range (root pr branch)
  "Return (RANGE . LABEL), what a review of PR in ROOT compares and is called.
BRANCH is the branch checked out.  PR of BRANCH (`ecc-review-pr-own-p')
is the working tree against where HEAD parted from the base of PR, as
`b' of the current branch reviews it: what is pushed and what is not,
on the lines of the files Claude edits.  Any other PR is BASE...HEAD by
their ids, what GitHub shows as its files changed; its right side is
not on disk, and the review says so (`ecc-review-elsewhere').  The
commits are fetched first if need be (`ecc-review-pr-fetch')."
  (let ((number (plist-get pr :number))
        (base-oid (plist-get pr :base-oid))
        (head-oid (plist-get pr :head-oid)))
    (unless (and (stringp base-oid) (stringp head-oid))
      (user-error "gh named no commits for pull request #%s" number))
    (if (ecc-review-pr-own-p pr branch)
        (progn
          (ecc-review-pr-fetch root pr (list base-oid))
          ;; Called as `b' calls the same commit, not after the pull
          ;; request: the review is named by what it compares, and `b'
          ;; and `p' of one fork are one review in one buffer, whichever
          ;; opened it first.
          (cons (or (ecc-review--merge-base root base-oid "HEAD")
                    (user-error "Pull request #%d: %s and HEAD have no commit in common"
                                number (plist-get pr :base)))
                (format "%s + working tree" (plist-get pr :base))))
      (ecc-review-pr-fetch root pr (list base-oid head-oid))
      (ecc-review-name-side root head-oid (plist-get pr :head))
      (cons (format "%s...%s" base-oid head-oid)
            (format "PR #%d %s" number
                    (ecc--truncate (string-trim (replace-regexp-in-string
                                                 "[ \t\n\r]+" " " (plist-get pr :title)))
                                   48))))))

;;;; Its commits

(defun ecc-review-pr-commits (root pr branch)
  "Return the commits of PR in ROOT, oldest first, as plists.
Each has :id, the full id, :short and :subject.  Merges are left out --
a merge of the base into the branch, read alone, is all the base did
in between -- and so are commits that change nothing, which have
nothing to show.  PR of BRANCH (`ecc-review-pr-own-p') is its base to
HEAD, the commits not pushed yet among them, as its review is; any
other is its base to its head.  What is missing is fetched first
\(`ecc-review-pr-fetch')."
  (let* ((base (plist-get pr :base-oid))
         (own (ecc-review-pr-own-p pr branch))
         (head (if own "HEAD" (plist-get pr :head-oid))))
    (unless (and (stringp base) (stringp head))
      (user-error "gh named no commits for pull request #%s" (plist-get pr :number)))
    (ecc-review-pr-fetch root pr (if own (list base) (list base head)))
    (mapcar (lambda (line)
              (pcase-let ((`(,id ,short ,subject) (split-string line "\x1f")))
                (list :id id :short short :subject (or subject ""))))
            (split-string
             ;; --full-history with the path: of the commits that are no
             ;; merge, those that change no file are what a path leaves
             ;; out, and without it git would follow one side of a merge.
             (ecc-review-pr--run ecc-review-git-executable root
                                 "log" "--no-merges" "--full-history" "--reverse"
                                 "--no-color" "--format=%H%x1f%h%x1f%s"
                                 (format "%s..%s" base head) "--" ".")
             "\n" t))))

(defun ecc-review-pr-commit-line (commit index total)
  "Return COMMIT, the INDEXth of TOTAL counted from 0, as a line to choose."
  (format "%d/%d  %s  %s" (1+ index) total (plist-get commit :short)
          (ecc--truncate (plist-get commit :subject) 72)))

(defun ecc-review-pr--whole-line (pr commits)
  "Return the choice of the whole of PR, whose commits are COMMITS."
  (format "The whole of #%d (%s)" (plist-get pr :number)
          (ecc-review--count (length commits) "commit")))

(defun ecc-review-pr-read-commit (pr commits &optional table-function)
  "Ask for one of COMMITS of PR, oldest first; return it, or nil for the whole.
The whole of PR is offered first and taken on an empty answer, so RET
reviews what `p' reviewed before it asked.  An id, or the start of one,
names that commit.  With no commit there is nothing to ask.
TABLE-FUNCTION makes the completion table of the lines, in their order."
  (when commits
    (let* ((whole (ecc-review-pr--whole-line pr commits))
           (total (length commits))
           (lines (seq-map-indexed (lambda (commit index)
                                     (ecc-review-pr-commit-line commit index total))
                                   commits))
           (choices (cons whole lines))
           (answer (string-trim
                    (completing-read (format-prompt "Which commit of #%d" whole
                                                    (plist-get pr :number))
                                     (if table-function (funcall table-function choices) choices)
                                     nil nil nil 'ecc-review-pr--commit-history whole)))
           (word (car (split-string answer nil t))))
      (cond ((or (null word) (equal answer whole)) nil)
            ((let ((at (seq-position lines answer)))
               (and at (nth at commits))))
            ((and (string-match-p "\\`[0-9a-f]\\{4,64\\}\\'" word)
                  (seq-find (lambda (commit) (string-prefix-p word (plist-get commit :id)))
                            commits)))
            (t (user-error "%s is no commit of #%d" answer (plist-get pr :number)))))))

;;;; Reading it a commit at a time

(cl-defstruct (ecc-review-pr-walk (:constructor ecc-review-pr--make-walk)
                                  (:copier nil))
  "A pull request read a commit at a time, which its reviews point at.
ROOT is the repository and PR the plist of `ecc-review-pr-parse'; OWN
is non-nil when it is of the branch checked out.  WHOLE is the range
the whole of it is reviewed as, and COMMITS are its commits, oldest
first (`ecc-review-pr-commits'), each with :range once it has been
reviewed.  HELD is a hash of a range to the comments of its review
when that review was closed to make room for another -- an ediff
review, quit by \\`]' -- as a plist of :notes, :next-id and :positions.
UNSENT is how many comments of yours each review holds, as an alist of
its index to the count, worked out whenever it can change
\(`ecc-review-pr--count'), t until it first is: the header lines read
it as they are drawn, and redisplay is no time to go through every
buffer."
  root pr own whole commits held (unsent t))

(defvar ecc-review-pr--walks (make-hash-table :test #'equal)
  "Hash of (ROOT . NUMBER) to the `ecc-review-pr-walk' of that pull request.
One per pull request, so that `p' of it again finds the reviews left
open and the comments held.")

(defun ecc-review-pr-walk (root pr branch whole &optional commits)
  "Return the pull request PR of ROOT read a commit at a time.
BRANCH is the branch checked out, and WHOLE the range the whole of PR
is reviewed as (`ecc-review-pr-range').  COMMITS are its commits, when
they have been read already (`ecc-review-pr-commits').  The one made
before for PR is returned, brought up to date with what PR and its
commits are now."
  (let* ((key (cons root (plist-get pr :number)))
         (walk (or (gethash key ecc-review-pr--walks)
                   (puthash key (ecc-review-pr--make-walk
                                 :root root :held (make-hash-table :test #'equal))
                            ecc-review-pr--walks))))
    (setf (ecc-review-pr-walk-pr walk) pr
          (ecc-review-pr-walk-own walk) (ecc-review-pr-own-p pr branch)
          (ecc-review-pr-walk-whole walk) whole
          (ecc-review-pr-walk-commits walk) (or commits
                                                (ecc-review-pr-commits root pr branch)))
    walk))

(defun ecc-review-pr--number (walk)
  "Return the number of the pull request of WALK."
  (plist-get (ecc-review-pr-walk-pr walk) :number))

(defun ecc-review-pr-commit-index (walk id)
  "Return where the commit ID, full or the start of one, is among those of WALK."
  (seq-position (ecc-review-pr-walk-commits walk) id
                (lambda (commit id) (string-prefix-p id (plist-get commit :id)))))

(defun ecc-review-pr-commit-range (walk index)
  "Return the range the INDEXth commit of WALK is reviewed as.
That commit alone, by its id (`ecc-review-commit-alone'), worked out
the first time it is asked for."
  (let ((commit (nth index (ecc-review-pr-walk-commits walk))))
    (or (plist-get commit :range)
        (let ((range (ecc-review-commit-alone (ecc-review-pr-walk-root walk)
                                              (plist-get commit :id))))
          (nconc commit (list :range range))
          range))))

(defun ecc-review-pr--index (walk range)
  "Return what the review of RANGE is of WALK: `whole', a commit's index, or nil."
  (cond ((equal range (ecc-review-pr-walk-whole walk)) 'whole)
        ((stringp range)
         (let ((id (ecc-review--right-revision range)))
           (seq-position (ecc-review-pr-walk-commits walk) id
                         (lambda (commit id) (equal (plist-get commit :id) id)))))))

(defvar ecc-review-pr--opening nil
  "The `ecc-review-pr-walk' the review being opened is a part of, or nil.")

(defmacro ecc-review-pr-opening (walk &rest body)
  "Run BODY, which opens a review, as a review of the pull request WALK.
The review is told so as it comes on the screen
\(`ecc-review-pr--on-displayed')."
  (declare (indent 1) (debug t))
  `(let ((ecc-review-pr--opening ,walk))
     ,@body))

(defun ecc-review-pr--adopt (walk review)
  "Make REVIEW one of the pull request WALK.
The comments held for its range, when it was closed to make room for
another, are put back in it, unless it has comments of its own."
  (with-current-buffer review
    (setq ecc-review--walk walk)
    (add-hook 'kill-buffer-hook #'ecc-review-pr--on-kill nil t)
    (let* ((held (ecc-review-pr-walk-held walk))
           (kept (gethash ecc-review--range held)))
      (when (and kept (null ecc-review--notes))
        (remhash ecc-review--range held)
        (setq ecc-review--notes (plist-get kept :notes)
              ecc-review--next-id (plist-get kept :next-id)
              ecc-review--positions (plist-get kept :positions))
        (ecc-review--draw-notes)))
    (ecc-review-pr--count walk)))

(defun ecc-review-pr--on-displayed (review)
  "Make REVIEW one of the pull request being opened, if one is.
On `ecc-review-displayed-functions'."
  (when ecc-review-pr--opening
    (ecc-review-pr--adopt ecc-review-pr--opening review)))

(add-hook 'ecc-review-displayed-functions #'ecc-review-pr--on-displayed)

;;;;; Going from one commit to the next

(defun ecc-review-pr--hold (walk)
  "Keep the comments of this review with WALK, for when it is opened again."
  (when ecc-review--notes
    (puthash ecc-review--range
             (list :notes ecc-review--notes :next-id ecc-review--next-id
                   :positions ecc-review--positions)
             (ecc-review-pr-walk-held walk))))

(defun ecc-review-pr--leave (review)
  "Kill REVIEW, a diff review just left, unless it has comments or is shown.
One with comments is kept as it is, to be come back to or sent with
the rest; one with none is opened again as easily."
  (when (and (buffer-live-p review)
             (null (buffer-local-value 'ecc-review--notes review))
             (null (get-buffer-window review t)))
    (kill-buffer review)))

(defun ecc-review-pr--open-ediff (walk session range)
  "Open the ediff review of RANGE, of the pull request WALK, for SESSION."
  (require 'ecc-review-ediff)
  (ecc-review-pr-opening walk
    (ecc-review-ediff-range-buffer session range (ecc-review-pr-walk-root walk))))

(defun ecc-review-pr--go (walk index)
  "Open the review of the INDEXth commit of WALK in place of this one.
A diff review is followed in its window by the next, and kept while it
has comments (`ecc-review-pr--leave').  An ediff review takes the
frame, so it is quit, its comments held by WALK, and the next opened
in its place; if that cannot be opened, the one quit comes back."
  (let* ((from (current-buffer))
         (session ecc-review--session)
         (root (ecc-review-pr-walk-root walk))
         (range (ecc-review-pr-commit-range walk index)))
    (if (derived-mode-p 'ediff-mode)
        (let ((left ecc-review--range))
          (ecc-review-pr--hold walk)
          (ecc-review-ediff-quit from)
          (condition-case err
              (ecc-review-pr--open-ediff walk session range)
            (error
             (ecc-review-pr--open-ediff walk session left)
             (signal (car err) (cdr err)))))
      (let ((buffer (ecc-review-range-buffer session range root))
            (window (if (eq (window-buffer) from) (selected-window) (get-buffer-window from))))
        (ecc-review-pr--adopt walk buffer)
        (if (not (window-live-p window))
            (ecc-review--display buffer session)
          (set-window-buffer window buffer)
          (select-window window)
          (run-hook-with-args 'ecc-review-displayed-functions buffer))
        (ecc-review-pr--leave from)
        buffer))))

(defun ecc-review-pr--step (forward)
  "Open the next commit of this pull request when FORWARD, else the previous.
From the whole of it, the next is its first commit.  At either end,
say so and stay."
  (let* ((walk (or ecc-review--walk
                   (user-error "This review is no pull request read a commit at a time; p in the review menu opens one")))
         (number (ecc-review-pr--number walk))
         (commits (ecc-review-pr-walk-commits walk))
         (index (ecc-review-pr--index walk ecc-review--range))
         (short (and (integerp index) (plist-get (nth index commits) :short))))
    (ecc-review-pr--go
     walk
     (cond ((null commits) (user-error "#%d has no commit to read alone" number))
           ((eq index 'whole)
            (if forward 0 (user-error "This is the whole of #%d; ] goes to its first commit"
                                      number)))
           ((null index) (user-error "This review is no longer one of #%d" number))
           (forward (if (< index (1- (length commits)))
                        (1+ index)
                      (user-error "%s is the last commit of #%d" short number)))
           ((> index 0) (1- index))
           (t (user-error "%s is the first commit of #%d" short number))))))

(defun ecc-review-pr-next-commit ()
  "Review the next commit of this pull request in place of this one.
From the review of the whole of it, its first commit.  The comments of
this one stay with it, and come back with it."
  (interactive)
  (ecc-review-pr--step t))

(defun ecc-review-pr-previous-commit ()
  "Review the previous commit of this pull request in place of this one.
The comments of this one stay with it, and come back with it."
  (interactive)
  (ecc-review-pr--step nil))

;;;;; What the reviews say

(defun ecc-review-pr--reviews (walk)
  "Return the reviews of WALK that hold comments, in the order of the pull request.
The whole of it first, then its commits, oldest first.  Each is a
plist: :index (`whole' or a commit's), :range, :review, the review
buffer -- nil for one closed to make room for another, whose comments
WALK holds -- and :notes, all its comments.  Only those with comments
of yours are returned: Claude's are not sent."
  (let ((found nil))
    (dolist (buffer (buffer-list))
      (when (and (eq (buffer-local-value 'ecc-review--walk buffer) walk)
                 (ecc-review-buffer-p buffer))
        (with-current-buffer buffer
          (push (list :index (ecc-review-pr--index walk ecc-review--range)
                      :range ecc-review--range :review buffer :notes ecc-review--notes)
                found))))
    (maphash (lambda (range kept)
               (push (list :index (ecc-review-pr--index walk range) :range range
                           :notes (plist-get kept :notes) :held kept)
                     found))
             (ecc-review-pr-walk-held walk))
    (sort (seq-filter (lambda (review)
                        (and (plist-get review :index)
                             (seq-remove #'ecc-review--agent-p (plist-get review :notes))))
                      found)
          (lambda (a b)
            (let ((a (plist-get a :index)) (b (plist-get b :index)))
              (and (not (eq b 'whole)) (or (eq a 'whole) (< a b))))))))

(defun ecc-review-pr--yours (review)
  "Return how many comments of yours REVIEW, of `ecc-review-pr--reviews', holds."
  (seq-count (lambda (note) (not (ecc-review--agent-p note))) (plist-get review :notes)))

(defun ecc-review-pr--count (walk &optional dying)
  "Count again the comments of yours the reviews of WALK hold, and say so.
Kept in WALK (`ecc-review-pr-walk-unsent'), and every review of WALK
open has its header line, or its mode line in ediff, drawn again.
DYING is a review being killed, which is left out.  Run whenever the
count can change: a comment made or removed in a review of WALK, a
review of it opened, left, sent or killed."
  (let ((reviews (seq-remove (lambda (review)
                               (and dying (eq (plist-get review :review) dying)))
                             (ecc-review-pr--reviews walk)))
        (unsent nil))
    (dolist (review reviews)
      (cl-incf (alist-get (plist-get review :index) unsent 0 nil #'equal)
               (ecc-review-pr--yours review)))
    (setf (ecc-review-pr-walk-unsent walk) (nreverse unsent))
    (dolist (buffer (buffer-list))
      (when (and (not (eq buffer dying))
                 (eq (buffer-local-value 'ecc-review--walk buffer) walk)
                 (ecc-review-buffer-p buffer))
        (with-current-buffer buffer
          (if (derived-mode-p 'ediff-mode)
              (ecc-review-direct-refresh-headers buffer)
            (force-mode-line-update)))))))

(defun ecc-review-pr--on-draw ()
  "Count the comments of the pull request again, this review's being drawn.
On `ecc-review-after-draw-hook', which every change of the comments of
a review ends in."
  (when ecc-review--walk
    (ecc-review-pr--count ecc-review--walk)))

(add-hook 'ecc-review-after-draw-hook #'ecc-review-pr--on-draw)

(defun ecc-review-pr--on-kill ()
  "Count the comments of the pull request again, without this review.
On `kill-buffer-hook' of a review of a pull request."
  (when ecc-review--walk
    (ecc-review-pr--count ecc-review--walk (current-buffer))))

(defun ecc-review-pr--unsent-elsewhere (walk)
  "Return the counts of WALK of the reviews that are not this one, as kept.
An alist of an index to a count of comments of yours, worked out first
when it never has been (`ecc-review-pr--count')."
  (when (eq (ecc-review-pr-walk-unsent walk) t)
    (ecc-review-pr--count walk))
  (let ((index (ecc-review-pr--index walk ecc-review--range)))
    (seq-remove (lambda (cell) (equal (car cell) index))
                (ecc-review-pr-walk-unsent walk))))

(defun ecc-review-pr-walk-status (&optional subject)
  "Return what this review says of the pull request it is a part of.
Which commit it is, out of how many -- with its SUBJECT when asked
for -- or that it is the whole, and how many comments of yours the
other reviews of the pull request hold, which \\`C-c C-a' sends with these.
Read off what is kept (`ecc-review-pr--count'): this is drawn with
every redisplay of the header line."
  (let* ((walk ecc-review--walk)
         (number (ecc-review-pr--number walk))
         (commits (ecc-review-pr-walk-commits walk))
         (index (ecc-review-pr--index walk ecc-review--range))
         (others (ecc-review-pr--unsent-elsewhere walk)))
    (concat
     (propertize
      (pcase index
        ('whole (format "#%d as a whole, %s" number
                        (ecc-review--count (length commits) "commit")))
        ('nil (format "#%d" number))
        (_ (format "#%d commit %d/%d%s" number (1+ index) (length commits)
                   (if subject
                       (concat ": " (ecc--truncate (plist-get (nth index commits) :subject) 40))
                     ""))))
      'face 'bold)
     (when others
       (let* ((whole (assq 'whole others))
              (count (length (if whole (remq whole others) others)))
              (commits (and (> count 0)
                            (format "%d %scommit%s" count (if (integerp index) "other " "")
                                    (if (= count 1) "" "s")))))
         (propertize (format "  unsent: %d in %s" (apply #'+ (mapcar #'cdr others))
                             (cond ((and whole commits) (concat "the whole PR and " commits))
                                   (whole "the whole PR")
                                   (t commits)))
                     'face 'warning))))))

;;;;; Sending them all

(defvar ecc-review-pr-commits-note
  "They are on pull request #%d, %s, read a commit at a time: each group below is the whole of it or one of its commits, oldest first, and the lines of a commit are as it left them -- a later one may have changed them.  Read every group before changing anything: what is asked of one commit may be done, or have to be done differently, in a later one."
  "What the prompt of the comments of every review of a pull request says first.
Formatted with its number and title, after `ecc-review-header'.")

(defvar ecc-review-pr-elsewhere-note
  "Its head, %s, is not checked out here, so the lines below are not in the files of the working tree.  Ask before editing anything for them, and do not check anything out yourself."
  "What that prompt says next of a pull request whose branch is not checked out.
Formatted with its branch and the short id of its head.")

(defun ecc-review-pr--comments (review)
  "Return the comments of yours REVIEW, of `ecc-review-pr--reviews', would send.
A review buffer lists its own; the comments held for one closed are
listed as it would list them."
  (if-let* ((buffer (plist-get review :review)))
      (with-current-buffer buffer
        (funcall ecc-review--comments-function))
    (with-temp-buffer
      (let ((kept (plist-get review :held)))
        (setq ecc-review--notes (plist-get kept :notes)
              ecc-review--positions (plist-get kept :positions))
        (ecc-review-comments)))))

(defun ecc-review-pr-message (walk reviews)
  "Return the prompt carrying the comments of REVIEWS, of the pull request WALK.
`ecc-review-header', what they are on (`ecc-review-pr-commits-note',
`ecc-review-pr-elsewhere-note'), and then a group for each commit, as
`ecc-review-format-message' writes one review.  Two reviews of one
commit -- a diff review and an ediff one -- are one group."
  (let* ((pr (ecc-review-pr-walk-pr walk))
         (commits (ecc-review-pr-walk-commits walk))
         (total (length commits)))
    (concat
     ecc-review-header "\n"
     (format ecc-review-pr-commits-note (plist-get pr :number)
             (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (plist-get pr :title))))
     (unless (ecc-review-pr-walk-own walk)
       (concat "  " (format ecc-review-pr-elsewhere-note
                            (format "%s (%s)" (plist-get pr :head)
                                    (substring (plist-get pr :head-oid) 0 7)))))
     "\n\n"
     (mapconcat
      (lambda (index)
        (ecc-review-format-message
         (mapcan (lambda (review)
                   (and (equal (plist-get review :index) index)
                        (ecc-review-pr--comments review)))
                 reviews)
         (if (eq index 'whole)
             (format "# The whole of #%d" (plist-get pr :number))
           (let ((commit (nth index commits)))
             (format "# Commit %d/%d %s: %s" (1+ index) total
                     (plist-get commit :short) (plist-get commit :subject))))))
      (delete-dups (mapcar (lambda (review) (plist-get review :index)) reviews))
      "\n\n"))))

(defun ecc-review-pr--sent (walk reviews review)
  "Close REVIEWS of WALK, whose comments have been sent; REVIEW, this one, last.
A review open is closed as one whose comments have been sent is, and
the comments held for one closed are dropped."
  (let ((this nil))
    (dolist (one reviews)
      (let ((buffer (plist-get one :review)))
        (cond ((null buffer) (remhash (plist-get one :range) (ecc-review-pr-walk-held walk)))
              ((eq buffer review) (setq this buffer))
              (t (ecc-review--close buffer)))))
    (when this
      (ecc-review--close this))
    (ecc-review-pr--count walk)))

(defun ecc-review-pr-send-all (&optional edit)
  "Send the comments of every review of this pull request as one prompt.
The whole of it and each of its commits, open or left by \\`]' and \\`[',
a group for each, so that Claude reads all of them before changing
anything (`ecc-review-pr-message').  Each review whose comments went is
closed, as \\[ecc-review-send] closes one.  With a prefix argument EDIT
the prompt is opened to be read over and changed first."
  (interactive "P")
  (let* ((walk (or ecc-review--walk
                   (user-error "This review is no pull request read a commit at a time; C-c C-c sends its comments")))
         (session (or ecc-review--session (user-error "Not a review buffer")))
         (reviews (or (ecc-review-pr--reviews walk)
                      (user-error "No comment to send in any review of #%d; put one on a hunk with c"
                                  (ecc-review-pr--number walk))))
         (review (current-buffer)))
    (ecc-review-send-text session (ecc-review-pr-message walk reviews) review edit
                          (lambda () (ecc-review-pr--sent walk reviews review)))))

(provide 'ecc-review-pr)

;;; ecc-review-pr.el ends here
