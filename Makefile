# emacs-claude-code — build / test / lint
# Override EMACS if the one you want is not the `emacs` on PATH, e.g.
#   make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
EMACS ?= emacs
ELPA  ?= $(HOME)/.emacs.d/elpa

SRC   := $(wildcard ecc*.el)
TESTS := $(wildcard test/ecc-*-test.el)

# The dependencies are read from ~/.emacs.d/elpa by package-initialize
INIT := --eval '(progn (setq package-user-dir "$(ELPA)") (package-initialize))'
BATCH := $(EMACS) -Q --batch $(INIT) -L . -L test

.PHONY: all compile test test-live lint clean

all: compile lint test

# A stale .elc is loaded without the changes of what it depends on, which
# shows up as a bogus "function is not defined".  Wipe them every time
# before compiling; it costs a second or two.
compile:
	rm -f *.elc test/*.elc
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRC)

test: compile
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (not (tag live))))'

# Tests against the real CLI.  Run by hand only (haiku + a budget cap)
test-live: compile
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag live)))'

lint:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(foreach f,$(SRC),"$(f)"))) (checkdoc-file f)))'
	$(BATCH) --eval '(if (require (quote package-lint) nil t) (progn (setq command-line-args-left (list $(foreach f,$(SRC),"$(f)"))) (package-lint-batch-and-exit)) (message "package-lint not installed; skipping"))'

clean:
	rm -f *.elc test/*.elc
