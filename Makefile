# emacs-claude-code — build / test / lint
# Override EMACS if the one you want is not the `emacs` on PATH, e.g.
#   make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
EMACS ?= emacs
ELPA  ?= $(HOME)/.emacs.d/elpa

# The documentation site.  The only part of this repository that wants Node,
# which is why no docs- target is a prerequisite of `all' or `clean'.
NPM  ?= npm
SITE := docs/site

# ecc-autoloads.el is generated, not written: keep it out of what is
# compiled, linted and scanned for cookies.
AUTOLOADS := ecc-autoloads.el
SRC   := $(filter-out $(AUTOLOADS),$(wildcard ecc*.el))
TESTS := $(wildcard test/ecc-*-test.el)

# The dependencies are read from ~/.emacs.d/elpa by package-initialize
INIT := --eval '(progn (setq package-user-dir "$(ELPA)") (package-initialize))'
BATCH := $(EMACS) -Q --batch $(INIT) -L . -L test

.PHONY: all autoloads compile test test-live lint clean release release-check \
        release-tag release-tag-check version-check \
        docs-install docs-dev docs-build docs-preview docs-clean

all: autoloads compile lint test

# The `;;;###autoload' cookies only become autoloads once something writes
# them out.  package.el does that when it installs; a checkout used straight
# from `load-path' has nobody to do it, which is why an init that points at
# one otherwise has to name every command by hand.  Load ecc-autoloads.el
# from such an init and the cookies take effect instead.
autoloads: $(AUTOLOADS)

$(AUTOLOADS): $(SRC)
	$(BATCH) --eval '(progn (require (quote loaddefs-gen)) (loaddefs-generate default-directory (expand-file-name "$(AUTOLOADS)") (list "$(AUTOLOADS)")))'

# A stale .elc is loaded without the changes of what it depends on, which
# shows up as a bogus "function is not defined".  Wipe them every time
# before compiling; it costs a second or two.
compile:
	rm -f *.elc test/*.elc
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRC)

# ecc-autoloads.el is a prerequisite so that a test run always has a current
# one to check, and so that the checkout an init loads it from is never left
# behind by a `make test'.  It costs about 0.3s, and only when a source file
# is newer than it; make skips the target otherwise.
test: autoloads compile
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (not (tag live))))'

# Tests against the real CLI.  Run by hand only (haiku + a budget cap)
test-live: autoloads compile
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag live)))'

lint:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(foreach f,$(SRC),"$(f)"))) (checkdoc-file f)))'
	$(BATCH) --eval '(if (require (quote package-lint) nil t) (progn (setq command-line-args-left (list $(foreach f,$(SRC),"$(f)"))) (package-lint-batch-and-exit)) (message "package-lint not installed; skipping"))'

# A release is a tag, and the one thing it can get silently wrong is the
# Version header of ecc.el disagreeing with it: package-vc then reports the
# old number and nobody notices.  It takes two steps, because main takes no
# direct push -- a repository ruleset requires a pull request, and nobody
# can bypass it (confirmed 2026-09-14).  The work accumulates on `develop',
# and a release is cut from it onto a branch of its own: the bump, the
# CHANGELOG section and the notes are one pull request into main, and
# nothing half-finished may ride along with them.  Write the two pieces of
# prose first -- nothing here writes any -- the CHANGELOG.md section, which
# is `## [Unreleased]' renamed and dated, and release-notes/$(VERSION).md,
# which is what the GitHub release says; then
#   git switch develop && git pull
#   git switch -c release/0.2.0
#   make release VERSION=0.2.0     # checks, bumps, commits
#   ... open the pull request into main and merge it ...
#   git switch main && git pull
#   make release-tag VERSION=0.2.0 # tags what main became
#   git push origin v0.2.0         # this is what publishes the release
#   git switch develop && git merge main && git push
# The last line is not housekeeping.  Without it develop carries no release
# commit, its ecc.el still says the version before this one, and the next
# release is written on top of a number that was already published.
release: release-check all
	sed -e 's/^;; Version: .*/;; Version: $(VERSION)/' ecc.el > ecc.el.new
	mv ecc.el.new ecc.el
	git add ecc.el CHANGELOG.md release-notes/$(VERSION).md
	git commit -m "chore(release): $(VERSION)" \
	  ecc.el CHANGELOG.md release-notes/$(VERSION).md
	@echo
	@echo "committed $(VERSION).  Put it on main through a pull request, then:"
	@echo "  git switch main && git pull && make release-tag VERSION=$(VERSION)"
	@echo "and once the tag is pushed, take main back to develop:"
	@echo "  git switch develop && git merge main && git push"

# The tag, once the pull request is merged.  It goes on the main that
# origin has, so that the tag cannot name a commit nobody else can see, and
# it is refused unless the header of that main is the version being tagged.
release-tag: release-tag-check
	git tag -a "v$(VERSION)" -m "ecc $(VERSION)"
	@echo
	@echo "tagged v$(VERSION).  Publish it with: git push origin v$(VERSION)"

# The checks that are the same whether the release is being committed or
# tagged: the number, the two pieces of prose, and the tag not being taken.
version-check:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.2.0"; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' \
	  || { echo "VERSION must look like 0.2.0"; exit 1; }
	@grep -q '^## \[$(VERSION)\]' CHANGELOG.md \
	  || { echo "CHANGELOG.md has no '## [$(VERSION)]' section"; exit 1; }
	@test -s release-notes/$(VERSION).md \
	  || { echo "release-notes/$(VERSION).md is missing or empty -- that file is the release notes"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null \
	  || { echo "v$(VERSION) is already tagged"; exit 1; }

# Everything that has to be true before the release commit, checked ahead
# of `all' so that a missing VERSION does not cost a test run first.  The
# commit is made on release/$(VERSION), not on main -- main takes no direct
# push -- and not on develop, where a release that is abandoned halfway
# would leave a bumped version header in everybody's way.
release-check: version-check
	@branch=$$(git rev-parse --abbrev-ref HEAD); test "$$branch" = "release/$(VERSION)" \
	  || { echo "a release is committed on release/$(VERSION), not on $$branch"; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=all \
	    | grep -v 'CHANGELOG.md$$' | grep -v 'release-notes/$(VERSION).md$$')" \
	  || { echo "the working tree has changes besides the CHANGELOG and the notes"; exit 1; }

# Everything that has to be true before the tag.  The working tree is not
# asked about: what is tagged is a commit origin already has.
release-tag-check: version-check
	@branch=$$(git rev-parse --abbrev-ref HEAD); test "$$branch" = main \
	  || { echo "a release is tagged on main, not on $$branch"; exit 1; }
	git fetch -q origin main
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" \
	  || { echo "main is not what origin has -- merge the pull request and pull"; exit 1; }
	@header=$$(sed -n 's/^;; Version: *//p' ecc.el); test "$$header" = "$(VERSION)" \
	  || { echo "ecc.el on main says $$header, not $(VERSION)"; exit 1; }


clean:
	rm -f *.elc test/*.elc $(AUTOLOADS)

# `ci' rather than `install', so that a local build cannot quietly move the
# lockfile that the deploy workflow installs from.
docs-install:
	$(NPM) --prefix $(SITE) ci

docs-dev:
	$(NPM) --prefix $(SITE) run dev

docs-build:
	$(NPM) --prefix $(SITE) run build

# Pagefind search exists only after a build and is served by preview, never
# by the dev server.
docs-preview:
	$(NPM) --prefix $(SITE) run preview

docs-clean:
	rm -rf $(SITE)/dist $(SITE)/.astro
