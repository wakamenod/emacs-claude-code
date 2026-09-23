# emacs-claude-code — developer notes (for Claude Code)

This repository builds `ecc`, a package that drives the Claude Code CLI from Emacs.
`README.md` says what it is and how to use it; this file is for working on it.

The implementation is the record. Read the source and the tests; where a comment and the
code disagree, the code wins. This file carries only what the code, the Makefile and the
CHANGELOG cannot say for themselves: a rule whose reason belongs next to a mechanism goes
in a comment there, and this file names the rule alone.

## Layout

One feature per file, `ecc-<feature>.el`, with `test/ecc-<module>-test.el` beside it.
`ecc.el` holds the entry points, `ecc-transient.el` the menu. The boundaries that are
rules:

- `ecc-core.el` depends on no other `ecc-` module.
- JSON is touched only by `ecc-protocol.el` and `ecc-proc.el`, plus the two that speak to
  a process of their own (`ecc-mcp.el`, `ecc-inline.el`).
- `ecc-model.el` — the session, the Turn > Step > Tool tree, the pending-request queue
  and the hooks — knows nothing of JSON, processes or drawing, and never sees the buffer.
- `ecc-render.el` alone draws the transcript; `ecc-chat.el` holds the major mode, the
  keymaps and the movement. The prompt region lives after `ecc-render--prompt-start` in
  the same buffer, and no redraw deletes past it.
- `ecc-window.el` does not require `ecc-space.el`: the Spaces are built on top of the
  windows, not inside them. `ecc-window.el` branches on `ecc-use-spaces` at the head of
  the four functions that care and loads `ecc-space` at run time, and with that setting
  off nothing reaches `ecc-worktree.el`, `ecc-space.el` or `ecc-sidebar.el`.

Each script in `scripts/` says in its own header what it is and how to run it. Run
`scripts/bench-render.el` before and after touching the renderer. The documentation site
is `docs/site/`, documented by `docs/site/README.md`; the `docs/*.md` beside it are
gitignored working documents.

`demo/` is the other kind of picture: `demo/record.sh <scene>` opens a second GUI Emacs
with the user's own `init.el`, puts this checkout in front of the ecc that init points
at, plays a scene and records it as an mp4. It is for what a batch test cannot see -- a
frame, a panel, a colour, a key -- and for handing that check to somebody else; the
site's pictures are `scripts/docshots.sh` and stay a dressed-up `-Q`. A scene is
`demo/scenes/NAME.el` (what it builds, one function per step) and `demo/scenes/NAME.sh`
(the order and the pauses). `demo/README.md` says how to write one and what it costs to
learn again: what is recorded is the demo frame's own window, through
`demo/record-window.swift` and ScreenCaptureKit, so nothing that covers it is in the
picture and the recording does not have to be in front; a step runs the command a key is
bound to in the buffer it belongs to rather than feeding keys to a command loop that is
reading somewhere else; and a step arrives with `*scratch*` current, so a scene that
means a directory has to say which one -- `ecc-window-context-project-root` falls back to
the checkout the demo Emacs was started from, which is this repository.

## Commands

The Makefile's comments document the targets and the `EMACS`/`ELPA` variables. What they
do not say:

- `make test` needs nothing but Emacs 29.1 or later: no network, no `claude`, no API key.
- On a machine where `emacs` is not on `PATH`, `$EMACS` is already exported into the
  environment by the gitignored `.claude/settings.local.json` and `make test` picks it up
  on its own, so read `$EMACS` before concluding there is no Emacs here.
- `make test-live` starts real sessions: a few minutes and a little under $1 for the whole
  set. To run one, narrow it with a selector:
  `$(BATCH) -l test/ecc-test-helpers.el -l test/ecc-live-test.el --eval '(ert-run-tests-batch-and-exit (quote ecc-test-live-plan))'`
- Building and testing the Emacs package must never start needing a JavaScript toolchain:
  the `docs-*` targets are the only thing here that wants Node.

## Rules for starting the CLI

- **Never use `--safe-mode`**: it takes away the MCP servers, skills, commands and agents
  this package exists to show. There is no `ecc-safe-mode`, nor a setting that names a
  model, an effort or a budget — all of them belong to the Claude Code settings, and a
  session that wants its own carries it among its options (`ecc-core.el`, and
  `ecc-proc--model` for why `--model` is never passed on its own account).
- stream-json needs `--verbose`, `--permission-prompt-tool stdio` and
  `:connection-type 'pipe`.
- **Plugins whose hooks would land in a recording are turned off while recording**: a
  plugin on the machine fires its hooks into the session and puts its events, its delay
  and its own MCP servers into a fixture meant to show the CLI alone. `scripts/record-*.sh`
  take `--disable-plugin name@marketplace`; the Elisp side is the `ecc-disabled-plugins`
  setting, or a session's `:disabled-plugins`.

## Coding rules

- `lexical-binding: t`. The prefix is `ecc-`, and internal functions are `ecc--`.
- Arrays for `json-serialize` are vectors. `nil` is `{}`. `null` is `:null` and false is
  `:false`.
- No font-lock in a session buffer. Faces are put on at insertion time.
- Never swallow an error. A failed dispatch is left in the log and in an `unknown` node.
- Code, comments, docstrings and user-facing messages are written in English.
- **`defcustom` is for what a user chooses**: a taste, a difference between machines
  (font, screen, PATH), or a judgement about safety and cost. A stand-in the CLI
  overwrites, a sentence sent to the model, a table of the CLI's own quirks and an
  internal constant are `defvar`, reachable with `setq` and bindable in a test all the
  same. Adding a `defcustom` means making that case.

## Tests

`test/ecc-test-helpers.el` says where the fixtures live, what each kind is and which
recorder makes it. Beyond that:

- New behaviour gets an ERT of its own. Nothing is done until `make test` passes.
- A recording carries the paths and session names of the machine it was made on. Look at
  a new fixture before committing it.
- Keep rendering snapshots to the main cases.
- Anything that spans sessions (the dashboard, answering from anywhere) is tested with
  two sessions or more: a bug in `ecc-model-pending-all` did not show up with one.
- Japanese prompts in the tests are input data. They match what the fixtures recorded, and
  they cover multibyte text, so leave them in Japanese.

## Where a session lives

The Commentary of `ecc-registry.el` describes the live sessions, and `ecc-history.el`
the recording and its branches. The one rule to carry in: **a second process running
`--resume` on a live session forks the conversation, and there is no lock to stop it.**

## How the work goes

- `develop` is where the work gathers; `main` is what people install, and it takes no
  direct push. A piece of work branches off `develop` and goes back into it through a
  pull request. `main` sees a release and nothing else, and
  `.github/workflows/base-branch.yml` refuses a pull request into `main` from anything
  but `release/*` or `hotfix/*` — the base of a pull request defaults to `main`, and a
  fix that goes there instead of into `develop` is a fix nobody runs (PR #70).
- **A hotfix is not finished until `main` is merged back into `develop`.** `hotfix/*` is
  the one branch that goes straight into `main`, for what cannot wait for a release, and
  it leaves `main` ahead of `develop` until somebody carries it back.
- A pull request carries its own entry in the `## [Unreleased]` section of
  `CHANGELOG.md`. That section is a draft until the release dates it, so a bug that
  both appeared and was fixed before any release is not an entry under `Fixed` — it is
  a correction to the entry that introduced it. Nobody outside ever saw it.
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

## How a release goes

The sequence and every check are in the `Makefile` header and the `release*-check`
targets; the version rule and the rule that an entry names the CLI it was verified
against are in the `CHANGELOG.md` header; the tag is the release, and what refuses a
bad one is `.github/workflows/release.yml`. Two things none of them says:

- The version is written in exactly one place, the `Version:` header of `ecc.el`.
  `ecc-version` reads it back, and there is no hand-written `ecc-pkg.el` — a second copy
  of the number is a release that says two different things.
- `CHANGELOG.md` and `release-notes/<version>.md` are written for different readers. The
  CHANGELOG section is the record: every change, in the detail somebody debugging a year
  from now needs. The release note is the release page, read by somebody deciding whether
  to upgrade — the headline changes grouped by what they are for, the breaking ones named,
  the rest left to the CHANGELOG. A screen or two (2026-09-14).
