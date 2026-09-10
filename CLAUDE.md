# emacs-claude-code — developer notes (for Claude Code)

This repository builds `ecc`, a package that drives the Claude Code CLI from Emacs.

## Read these first

1. `REQUIREMENTS.md` — the requirements of record (110 of them: the original 106, plus FR-OUT-15, the FR-UI pair of phase 9 and the four FR-BTW of 2026-09-09, less FR-TUI-2 which was dropped on 2026-09-06 and the FR-HINT pair withdrawn on 2026-09-09 — the automatic `/recap`, implementation and all). Refer to them by id (FR-xxx-N, NFR-N).
2. `IMPLEMENTATION_PLAN.md` — the implementation plan. Follow the instructions of §0 and the phase order of §7.
3. `docs/verified.md` — CLI behaviour confirmed against the real thing. Add to it whenever something open in §10 is settled.
4. `docs/decisions.md` — the record of findings that clash with the requirements, and what was decided.
5. `docs/phase9-ui-redesign.md` — the phase 9 revision of the transcript and prompt UI. It
   overrides §5.2, §5.3 of `REQUIREMENTS.md` and §5, §6.1, §6.2 of the plan; where they
   disagree, it wins. **Phase 9 is done in full** (9a; 9b: one buffer, `ecc-chat-mode`,
   no magit-section; 9c: the visual finish, 9c-1..9c-7, confirmed on a real frame
   2026-09-08).

Those five documents live in the working directory but are not in the repository: they
are listed in `.gitignore`, and a clone does not carry them. They are written in Japanese
and stay that way; the code, the tests and this file are in English.

## Environment

- Emacs: `emacs` is not on PATH. It is `/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app/Contents/MacOS/Emacs` (the Emacs 32 development build), already named by the `EMACS` variable of `Makefile`.
- The dependencies live in `~/.emacs.d/elpa` (markdown-mode, nerd-icons, spinner, ghostel; posframe is optional and only `ecc-usage-display` uses it); `transient` ships with Emacs itself. magit-section is no longer used (phase 9b). `package-initialize` finds them. `package-lint` is not installed, and lint skips it on its own.
- The terminal of the hand-off is **ghostel** (libghostty-vt), and the only one: neither vterm nor a terminal outside Emacs is supported (see `docs/decisions.md`). ghostel loads and runs in batch, so `ecc-tui-test` drives the real backend.
- Claude Code CLI: `claude` 2.1.265.

## Commands

```
make compile     # byte-compile (warnings are errors); wipes stale .elc first
make test        # ERT (fixture replay; no real process)
make test-live   # ERT against the real CLI (tag live); run by hand only
make lint        # checkdoc (+ package-lint when it is there)
```

`make test-live` takes a few minutes and a little under $1 for the whole set. To run
a single one, narrow it with a selector:
`$(BATCH) -l test/ecc-test-helpers.el -l test/ecc-live-test.el --eval '(ert-run-tests-batch-and-exit (quote ecc-test-live-plan))'`

## Rules for starting the CLI

Development and testing **always** start `claude` with:

```
--settings '{"enabledPlugins":{"emacs-bridge@emacs-gravity-marketplace":false}}'
```

- `enabledPlugins` in `--settings`: this machine carries the hooks of the emacs-gravity
  plugin (emacs-bridge 4.6.2). They **do not hang** (confirmed twice on 2026-09-05: the
  hook answers `{"reason":"no_capable_terminal"}`, withdraws, and the CLI falls back to
  `--permission-prompt-tool stdio`), but keep them off while recording fixtures, so that
  hook events, one or two seconds of delay, and gravity's own MCP and system prompt stay
  out of the recording. It is per session, so the user's own interactive sessions are
  unaffected.
- **Never use `--safe-mode`.** It drops MCP servers, skills, custom commands and agents
  altogether, which takes away the very things this package wants to show (`/` completion
  of FR-INP-1..3, the agents of FR-DASH, FR-MCP). See D2 in `docs/verified.md`.
- **Cost belongs in the Claude Code settings, not here** (2026-09-06, see
  `docs/decisions.md`).  `ecc` has no budget option, and no rule says to force a model
  on it: `scripts/record-*.sh` pass a cheap model and a cap of their own, and the live
  tests pass theirs in `:extra-args`.
- **There is no setting that names a model, and `--model` is passed only for a session
  that carries one.**  The model comes from the Claude Code settings for a new session,
  and from the last real assistant message of its recording for a resumed one; passing
  `--model` overrides that for good, which would undo every `/model` made since -- in the
  terminal of a hand-off above all.  A model that belongs to one session goes in its
  `:model` option, which is passed either way (`ecc-proc--model`; 2026-09-06, revised
  2026-09-08 when `ecc-model` was removed).
- stream-json needs `--verbose`, `--permission-prompt-tool stdio` and
  `:connection-type 'pipe` (plan §2.1, §9).

On the Elisp side there is no `ecc-safe-mode`: `--safe-mode` is passed only by a
session that carries `:safe-mode` among its options. Plugins to turn off go in
`ecc-disabled-plugins`, a plain variable to `setq` (2026-09-10, see below).

## Coding rules

- `lexical-binding: t`. The prefix is `ecc-`, and internal functions are `ecc--`.
- JSON is touched only by `ecc-protocol.el` and `ecc-proc.el` (plus the two that speak
  to a process of their own, `ecc-mcp.el` and `ecc-inline.el`). The transcript is drawn
  by `ecc-render.el` alone, with text properties (`ecc-node`, `ecc-depth`,
  `ecc-heading`, `keymap`, `read-only`) and fold overlays; `ecc-chat.el` holds the
  major mode, the keymaps and the movement. The model never sees the buffer (plan §0,
  NFR-9). The prompt region lives after `ecc-render--prompt-start` in the same buffer,
  and no redraw deletes past it (FR-UI-2).
- Arrays for `json-serialize` are vectors. `nil` is `{}`. `null` is `:null` and false is
  `:false` (plan §2.3).
- No font-lock in a session buffer. Faces are put on at insertion time.
- Never swallow an error. A failed dispatch is left in the log and in an `unknown` node.
- Code, comments, docstrings and user-facing messages are written in English.
- **`defcustom` is for what a user chooses**: a taste, a difference between
  machines (font, screen, PATH), or a judgement about safety and cost. There
  are 30 of them, and `docs/defcustom-inventory.md` says which and why. A
  stand-in the CLI overwrites, a sentence sent to the model, a table of the
  CLI's own quirks and an internal constant are `defvar`, reachable with
  `setq` and bindable in a test all the same. Adding a `defcustom` means
  making that case.

## Tests

- Each phase gets the ERT of plan §8. A phase is not done until `make test` passes.
- Fixtures are `test/fixtures/*.jsonl`, recorded from the real CLI by
  `scripts/record-fixture.sh`.
- Session registry fixtures are `test/fixtures/registry/*.json`, copied from
  `~/.claude/sessions`.
- History fixtures (the jsonl of `~/.claude/projects`) are `test/fixtures/history/*.jsonl`,
  recorded by `scripts/record-history.sh`: it talks for a few turns with persistence on and
  takes the jsonl that was written. Do not put them in the same directory as the stream
  fixtures, because `ecc-dispatch-test-no-fixture-line-is-unknown` feeds every fixture
  through as a stream.
- Keep rendering snapshots to the main cases.
- Anything that spans sessions (the dashboard, answering from anywhere) is tested with two sessions or
  more: the destructive sort in `ecc-model-pending-all` did not show up with one.
- `format-mode-line` returns an empty string in batch. Check the `:eval` of a mode-line by
  calling its function directly.
- Japanese prompts in the tests are input data. They match what the fixtures recorded, and
  they cover multibyte text, so leave them in Japanese.

## Where a session lives (from the phase 5 investigation; details in docs/verified.md)

- Live sessions: `~/.claude/sessions/<pid>.json`, read by `ecc-registry.el`. Headless ones
  are there too. `claude agents --json` is not used: it returns the same thing through a
  subprocess.
- The recording: `~/.claude/projects/<cwd with every non-alphanumeric turned into ->/<session-id>.jsonl`.
- The recording is a tree. Editing, interrupting and resuming twice all grow branches, so
  `ecc-history-abandoned` drops only the branches hanging off the current line (`/compact`
  starts a new root, and must not be dropped).
- **A second process running `--resume` on a live session forks the conversation, with no
  lock to stop it.** Stop it before resuming; `ecc-history-resume` asks first.

## How the work goes

- One phase per session, roughly. Report once the acceptance criteria of the phase are met,
  and get the user's word before moving on.
- Commit in meaningful steps within a phase too. Messages follow Conventional Commits
  (`feat(proc): ...`, `fix(render): ...`, `test: ...`, `docs: ...`).
- A finding that clashes with the requirements goes in `docs/decisions.md` and to the user.
  Never change a requirement on your own.
