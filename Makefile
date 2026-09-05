# emacs-claude-code — build / test / lint
# `emacs` は PATH に無いので EMACS で明示する。CLAUDE.md を参照。
EMACS ?= /opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app/Contents/MacOS/Emacs
ELPA  ?= $(HOME)/.emacs.d/elpa

SRC   := $(wildcard ecc*.el)
TESTS := $(wildcard test/ecc-*-test.el)

# 依存は ~/.emacs.d/elpa から package-initialize で読む
INIT := --eval '(progn (setq package-user-dir "$(ELPA)") (package-initialize))'
BATCH := $(EMACS) -Q --batch $(INIT) -L . -L test

.PHONY: all compile test test-live lint clean

all: compile lint test

# 古い .elc が残っていると、依存先の変更が反映されないまま読み込まれて
# 「関数が未定義」の偽エラーになる。毎回消してから compile する（1〜2 秒）。
compile:
	rm -f *.elc test/*.elc
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRC)

test: compile
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (not (tag live))))'

# 実 CLI を使うテスト。手動でのみ実行する（haiku + 予算上限）
test-live: compile
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag live)))'

lint:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(foreach f,$(SRC),"$(f)"))) (checkdoc-file f)))'
	$(BATCH) --eval '(if (require (quote package-lint) nil t) (progn (setq command-line-args-left (list $(foreach f,$(SRC),"$(f)"))) (package-lint-batch-and-exit)) (message "package-lint not installed; skipping"))'

clean:
	rm -f *.elc test/*.elc
