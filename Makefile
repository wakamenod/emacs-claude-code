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
# old number and nobody notices.  Write the CHANGELOG.md section first --
# nothing here writes prose -- and then
#   make release VERSION=0.2.0
# which checks, bumps the header, commits the two files and tags.  Pushing
# is left to you, because pushing the tag is what publishes the release:
#   git push --follow-tags
release: release-check all
	sed -e 's/^;; Version: .*/;; Version: $(VERSION)/' ecc.el > ecc.el.new
	mv ecc.el.new ecc.el
	git commit -m "chore(release): $(VERSION)" ecc.el CHANGELOG.md
	git tag -a "v$(VERSION)" -m "ecc $(VERSION)"
	@echo
	@echo "tagged v$(VERSION).  Publish it with: git push --follow-tags"

# Everything that has to be true before a release, checked ahead of `all'
# so that a missing VERSION does not cost a test run first.
release-check:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.2.0"; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' \
	  || { echo "VERSION must look like 0.2.0"; exit 1; }
	@branch=$$(git rev-parse --abbrev-ref HEAD); test "$$branch" = main \
	  || { echo "a release is tagged on main, not on $$branch"; exit 1; }
	@test -z "$$(git status --porcelain | grep -v CHANGELOG.md)" \
	  || { echo "the working tree has changes other than CHANGELOG.md"; exit 1; }
	@grep -q '^## \[$(VERSION)\]' CHANGELOG.md \
	  || { echo "CHANGELOG.md has no '## [$(VERSION)]' section"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null \
	  || { echo "v$(VERSION) is already tagged"; exit 1; }


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
