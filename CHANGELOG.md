# Changelog

All notable changes to ecc are recorded here.  The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version
numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
while ecc is below 1.0, a breaking change -- a command or key binding that
goes away, a `defcustom` that changes its meaning -- bumps the minor
number, and everything else bumps the patch number.

Every entry names the Claude Code CLI it was verified against.  Nearly
everything this package knows about the protocol belongs to one version of
that CLI, and the CLI moves without anybody upgrading ecc.

## [Unreleased]

### Added

- `/login`, `/logout` and `/auth-status` in the prompt region, and
  `ecc-auth-login`, `ecc-auth-logout` and `ecc-auth-show-status` as commands.
  The CLI names neither `login` nor `logout` in `slash_commands`, nor in
  `terminal_slash_commands`: the terminal client catches them in its own input
  layer, so a headless client is told nothing about them and `/login` typed
  into a prompt would have gone to the model as a sentence (confirmed against
  **Claude Code CLI 2.1.268**). Emacs answers them itself, on the `claude auth
  login|logout|status` subcommands. `/login` hands the OAuth flow to a terminal
  — ghostel when it is installed, `term` otherwise — and offers afterwards to
  restart the sessions still running on the credentials they started with
  (`ecc-auth-restart-sessions`).

### Changed

- The header line of a session names the project it runs in, right after the
  state: `○ idle  emacs-claude-code`.  The name is the one `project.el`
  gives the tree above the directory the CLI works in, so a session started
  in a subdirectory says the name of the whole project; a directory in no
  project says its own name.  Several sessions look alike from a distance,
  and a window with no mode line shows the buffer name nowhere.  What the
  header line holds is parted by spaces rather than by `·`, on the right of
  it too: the marks carry symbols of their own, and a row of separators on
  top of those read as noise.
- A running turn is redrawn from the block that is still changing, not from
  its start.  Every change used to delete and draw the whole turn again, ten
  times a second while it arrived, so a turn of hundreds of tool calls
  stuttered: one redraw of an 800-call turn took 81 ms without redisplay,
  and takes 0.2 ms now.  A block that changes after all (an agent that ends
  long after its turn did) is drawn again, which it was not before.
- The Files summary diffs a file again only when it changed again, rather
  than every hunk of every file on every redraw.

### Fixed

- The menus work in an Emacs where nothing of ecc has been loaded yet.
  `ecc-menu`, `ecc-resume-menu` and `ecc-slash-menu` are autoloaded, which
  brings in `ecc-transient.el` alone, while the commands they run live all
  over the package and nothing required `ecc` itself: `C-c c r r` from a
  fresh Emacs answered `Symbol's function definition is void:
  ecc-read-session`, and the menus worked only once some other ecc command
  had loaded the package.  Each menu now loads the package on its way to
  the buffer it draws.  `ecc-tui-open` called from `M-x` in the same cold
  Emacs was void for the same reason, and `ecc-tui.el` now requires
  `ecc-window.el` rather than only declaring what it takes from it.

- A running session is no longer dropped from the dashboard and the session
  list on GNU/Linux.  The registry checks a session's recorded `procStart`
  against the process table, and on Linux `process-attributes` works the start
  time out from the uptime it reads on each call, so it dates the same process
  a little either side of itself; comparing the two as text called a live
  session dead whenever that crossed a second boundary.  The times are now
  compared as times, with two seconds of slack.

## [0.1.0] - 2026-09-11

The first release.  Verified against **Claude Code CLI 2.1.268** and
Emacs 29.1, 29.4 and 30.1.

### Added

- Sessions: `ecc-start`, `ecc-resume` and `ecc-kill` run `claude`
  headless over its stream-json protocol and draw the conversation in one
  ordinary buffer -- the transcript above, the prompt below -- with no
  terminal emulation.
- Transcript: a Turn > Step > Tool tree that folds, with built-in
  rendering of Markdown, tables and diffs, and faces put on at insertion
  time so that search, `occur`, narrowing and copying all work as they do
  anywhere else.
- Permissions: tool requests are answered from the session buffer or from
  any other buffer, and default to deny.
- Review: `ecc-review` collects a session's changes into one `diff-mode`
  buffer whose hunk comments are sent back as a single prompt; a proposed
  edit can be changed before it is approved; plan mode opens the plan in a
  writable buffer.
- Sessions across Emacs: a dashboard of every session, including those
  another process is running, read from `~/.claude/sessions`; recorded
  conversations are read back from `~/.claude/projects`, searched by what
  was said in them, and resumed.
- Context: the region, the buffer and the project are quoted into a prompt;
  `/btw` asks a side question beside a running turn.
- Handing over: `ecc-tui-open` gives a live session to a terminal and takes
  it back afterwards.
- Extras: a loopback MCP server inside Emacs (off by default, and
  evaluating Elisp is a separate opt-in), usage reports, desktop
  notifications, and a `transient` menu on `ecc-global-map`.
- `ecc-version` reports the ecc, Emacs and CLI versions a bug report needs.

[Unreleased]: https://github.com/wakamenod/emacs-claude-code/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.1.0
