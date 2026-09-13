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

- A plugin browser, on `/plugins` in the prompt region, `I` in the menu and
  `M-x ecc-plugin`. The CLI's
  `/plugins` is a screen the terminal client draws for itself: it is named
  neither in `slash_commands` nor in `terminal_slash_commands`, so there is
  nothing to send over stream-json (confirmed against **Claude Code CLI
  2.1.270**). ecc reads and acts through the `claude plugin` subcommands
  instead, and draws four tabs itself: Discover, Installed, Marketplaces and
  Errors. Plugins can be installed at user, project or local scope, turned on
  and off, updated and removed, and marketplaces added, updated and removed.
  Installed lists the skills beside the plugins, as the real screen does, and
  turns them on and off through `skillOverrides` in the settings, which is what
  the CLI reads and what it offers no subcommand for. `s` filters the rows as
  it is typed and `/` jumps to one by completion, which is the better way
  through a marketplace of 297. A change offers the running sessions `/reload-plugins`, since a
  session keeps the plugins it started with (`ecc-plugin-reload-sessions`).
  Nothing exports the plugin load errors of the real Errors tab, so that tab
  holds what Emacs can see itself. The real screen's fifth tab, Stats, counts
  skill tokens over a week of local sessions and is not exported at all, so
  there is no Stats tab rather than a tab of something else wearing its name;
  what one plugin brings and costs is on `RET`.

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

- `ecc-toggle` is on `C-c c w`, next to the `C-c c j` that makes hiding worth
  undoing. It was reachable only through the menu before.
- `ecc-focus-project`, on `C-c c j` and `j` in the menu, puts the frame back to
  one project: the session windows of every other project come off the screen,
  the sessions of the chosen one are dealt into the window roles in the order
  they were last used, and the main window switches to that project's source
  (a buffer of it already on the screen, else the one last worked in there,
  else the most recently used buffer of the project, else Dired on the root; a
  prefix argument asks). Nothing is killed and no process is stopped:
  `ecc-toggle` brings back one project and `ecc-toggle-all` all of them.

### Changed

- A session window's tab line lists the sessions of that window's own project
  rather than every session this Emacs has open. Working in several projects
  at once -- which is what this package is for -- filled every row of tabs
  with sessions that had nothing to do with what was on the screen. Set
  `ecc-tab-line-scope` to `all` for the old behaviour. A session outside the
  scope is still reached by `ecc-switch-session`, the dashboard and
  `ecc-next-attention`; what is given up is its tab blinking when it wants an
  answer, which the mode line count and the notifications still report.
- Which sessions belong to a project is decided by `project.el` rather than by
  comparing the root as a string, so a session started in a subdirectory is
  grouped with the rest of the tree instead of standing alone. This is what
  `ecc-toggle`, `ecc-next-attention-in-project` and the tab line all go by.
- `ecc-start` takes its directory from the buffer the user is working in --
  the current one when it visits a file or a directory, and the last one that
  did otherwise -- rather than from whichever buffer happens to be current. A
  session started from a transcript, the dashboard or the scratch buffer used
  to land wherever that buffer stood. Where the session started is now
  reported in the echo area, prefix argument or not.
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

- `ecc-focus-project` no longer leaves the same session in two windows. The
  roles are dealt out from nothing, so a session that already held one was
  drawn in its new role while the window it came from went on showing it.
- `ecc-toggle` no longer brings back session windows that another toggle hid.
  The list of hidden sessions was replaced rather than added to, and the
  restore side put back every entry in it whatever project had asked for it.

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
