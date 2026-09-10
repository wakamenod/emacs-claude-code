# emacs-claude-code — developer notes (for Claude Code)

This repository builds `ecc`, a package that drives the Claude Code CLI from Emacs.
`README.md` says what it is and how to use it; this file is for working on it.

The implementation is the record. Read the source and the tests; where a comment and the
code disagree, the code wins.

## Layout

- `ecc.el` — the entry points (`ecc-start`, `ecc-resume`, `ecc-kill`) and the requires.
- `ecc-core.el` — the customization group, the launch options and the log buffers. It
  depends on no other `ecc-` module.
- `ecc-protocol.el`, `ecc-proc.el` — the CLI: one line of stream-json in, an alist out,
  and the JSON sent back.
- `ecc-model.el` — the session, the Turn > Step > Tool tree, the pending-request queue,
  and the hooks everything else listens on. It knows nothing of JSON, processes or drawing.
- `ecc-render.el`, `ecc-chat.el` — the buffer: what is drawn, and the major mode that
  holds the keymaps and the movement.
- The rest is one feature per file (`ecc-perm.el`, `ecc-review.el`, `ecc-plan.el`,
  `ecc-history.el`, `ecc-mcp.el`, `ecc-tui.el`, …). `ecc-transient.el` is the menu.
- `test/` — one `ecc-<module>-test.el` per module, plus `ecc-live-test.el`.
- `scripts/` — the recorders that make the fixtures.

## Commands

```
make compile     # byte-compile (warnings are errors); wipes stale .elc first
make test        # ERT (fixture replay; no real process)
make test-live   # ERT against the real CLI (tag live); run by hand only
make lint        # checkdoc (+ package-lint when it is there)
```

`make test` needs nothing but Emacs 29.1 or later: no network, no `claude`, no API key.
The optional packages are optional here too — the one test that drives the real ghostel
backend is behind a `skip-unless`.

`EMACS` names the Emacs to use, and defaults to the one on `PATH`:
`make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs`. `ELPA` names the package
directory the dependencies are read from, and defaults to `~/.emacs.d/elpa`.

`make test-live` starts real sessions. It takes a few minutes and a little under $1 for
the whole set at the model it pins. To run a single one, narrow it with a selector:
`$(BATCH) -l test/ecc-test-helpers.el -l test/ecc-live-test.el --eval '(ert-run-tests-batch-and-exit (quote ecc-test-live-plan))'`

## Rules for starting the CLI

- **Never use `--safe-mode`.** It drops MCP servers, skills, custom commands and agents
  altogether, which takes away the very things this package wants to show: `/` completion,
  the agent list, the MCP tools. There is no `ecc-safe-mode`; `--safe-mode` is passed only
  by a session that carries `:safe-mode` among its options.
- **Cost belongs in the Claude Code settings, not here** (decided 2026-09-06). `ecc` has
  no budget option: `scripts/record-*.sh` pass a cheap model and a cap of their own, and
  the live tests pass theirs in `:extra-args`.
- **There is no setting that names a model, and `--model` is passed only for a session
  that carries one.** The model comes from the Claude Code settings for a new session,
  and from the last real assistant message of its recording for a resumed one; passing
  `--model` overrides that for good, which would undo every `/model` made since -- in the
  terminal of a hand-off above all. A model that belongs to one session goes in its
  `:model` option, which is passed either way (`ecc-proc--model`; 2026-09-06, revised
  2026-09-08 when `ecc-model` was removed).
- stream-json needs `--verbose`, `--permission-prompt-tool stdio` and
  `:connection-type 'pipe`.
- **Plugins whose hooks would land in a recording are turned off while recording.** A
  plugin installed on the machine fires its hooks into the session, which puts hook
  events, a second or two of delay, and its own MCP servers and system prompt into a
  fixture that is supposed to show the CLI alone. `scripts/record-*.sh` take
  `--disable-plugin name@marketplace` for this, and it is per session, so your own
  interactive sessions are unaffected. On the Elisp side the same list is
  `ecc-disabled-plugins`, a plain variable to `setq`, or a session's `:disabled-plugins`.

## Coding rules

- `lexical-binding: t`. The prefix is `ecc-`, and internal functions are `ecc--`.
- JSON is touched only by `ecc-protocol.el` and `ecc-proc.el` (plus the two that speak
  to a process of their own, `ecc-mcp.el` and `ecc-inline.el`). The transcript is drawn
  by `ecc-render.el` alone, with text properties (`ecc-node`, `ecc-depth`,
  `ecc-heading`, `keymap`, `read-only`) and fold overlays; `ecc-chat.el` holds the
  major mode, the keymaps and the movement. The model never sees the buffer. The prompt
  region lives after `ecc-render--prompt-start` in the same buffer, and no redraw deletes
  past it.
- Arrays for `json-serialize` are vectors. `nil` is `{}`. `null` is `:null` and false is
  `:false`.
- No font-lock in a session buffer. Faces are put on at insertion time.
- Never swallow an error. A failed dispatch is left in the log and in an `unknown` node.
- Code, comments, docstrings and user-facing messages are written in English.
- **`defcustom` is for what a user chooses**: a taste, a difference between
  machines (font, screen, PATH), or a judgement about safety and cost. There
  are 30 of them. A stand-in the CLI overwrites, a sentence sent to the
  model, a table of the CLI's own quirks and an internal constant are
  `defvar`, reachable with `setq` and bindable in a test all the same.
  Adding a `defcustom` means making that case.

## Tests

- New behaviour gets an ERT of its own. Nothing is done until `make test` passes.
- Fixtures are `test/fixtures/*.jsonl`, recorded from the real CLI by
  `scripts/record-fixture.sh`.
- Session registry fixtures are `test/fixtures/registry/*.json`, copied from
  `~/.claude/sessions`.
- History fixtures (the jsonl of `~/.claude/projects`) are `test/fixtures/history/*.jsonl`,
  recorded by `scripts/record-history.sh`: it talks for a few turns with persistence on and
  takes the jsonl that was written. Do not put them in the same directory as the stream
  fixtures, because `ecc-dispatch-test-no-fixture-line-is-unknown` feeds every fixture
  through as a stream.
- A recording carries the paths and session names of the machine it was made on. Look at
  a new fixture before committing it.
- Keep rendering snapshots to the main cases.
- Anything that spans sessions (the dashboard, answering from anywhere) is tested with two sessions or
  more: the destructive sort in `ecc-model-pending-all` did not show up with one.
- `format-mode-line` returns an empty string in batch. Check the `:eval` of a mode-line by
  calling its function directly.
- Japanese prompts in the tests are input data. They match what the fixtures recorded, and
  they cover multibyte text, so leave them in Japanese.

## Where a session lives

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

- One piece of work per session, roughly. Report once it is done and `make test` passes,
  and get the user's word before moving on.
- Commit in meaningful steps rather than one lump at the end. Messages follow Conventional
  Commits (`feat(proc): ...`, `fix(render): ...`, `test: ...`, `docs: ...`).
- Something learned about the CLI that the code has to work around belongs in a comment
  next to the workaround, with the date it was confirmed. Tell the user too.
- `README.md` is the source of record and `README.ja.md` follows it. A change to the
  English one is not done until the Japanese one matches. The code blocks, the command
  and `defcustom` names and the factual cells of the comparison table are identical in
  both; only the prose, the table headings and the code comments are translated.
