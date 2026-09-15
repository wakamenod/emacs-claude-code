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

Verified against **Claude Code CLI 2.1.270**.

### Added

- The footer under the prompt names the model before the session has answered.
  The CLI says which model ran on every assistant message and says it nowhere
  earlier, so a session that had just been started -- the one moment the model
  is worth knowing, before the first prompt goes out -- had nothing on the
  right of its footer. What the CLI is about to resolve is worked out here
  instead: the `:model` of the session, then `ANTHROPIC_MODEL` in the
  environment it is started with, then the `model` of the Claude Code settings
  files -- the project's uncommitted file, then the project's, then the user's,
  with the managed settings of the machine above all three. The first answer
  replaces it, as a `/model` does.

  `ANTHROPIC_MODEL` beats a `model` in the settings files, which is the other
  way round from what the precedence of the settings suggests (verified on
  2026-09-14: `ANTHROPIC_MODEL=haiku` against a settings file naming `opus` ran
  haiku).

  The footer is drawn after every command and the answer lies in files, so the
  settings files are stat'ed and read again only when one has been written to.
  A remote project root is left out: its settings are on the other machine.

### Changed

- Where the Claude Code settings files live moved from `ecc-hooks` to
  `ecc-protocol`, which is what reads and writes them:
  `ecc-hooks-settings-files`, `ecc-hooks-user-directory` and
  `ecc-hooks-managed-files` are now `ecc-protocol-settings-files`,
  `ecc-protocol-user-directory` and `ecc-protocol-managed-files`. Nothing a
  user sets changes name.

- **Breaking:** `ecc-review` (`C-c c D`) reviews everything that changed since the
  session started, rather than the files the CLI reported editing or writing. The
  old review read the tool stream, so a file changed by a shell command, a script
  or anything else that is not an Edit or a Write was not in it -- and that is now
  most of what a session does, which left the review empty in the sessions that had
  the most to show. What the working tree held is recorded when the session starts
  (and again when one is resumed, since what came before belongs to the session that
  made it), and the review compares the tree as it stands against that. A change is
  shown whatever made it.

  The two reviews are now one review with one argument between them: `D` against
  where the session started, `G` against the last commit. So `D` still shows work
  the session committed along the way, which `G` loses, and neither cares how a file
  was changed.

  The base is a moment rather than an author, so work in progress from before the
  session is left out, but another session working in the same directory is not --
  separate git worktrees keep those apart. A project outside git has no tree to
  compare against and is reviewed from the session's own record, as before.

  The baseline is a git tree written through a throwaway index: no stash entry is
  made, `refs/stash` is not touched, and neither is the real index or any file. It
  costs about 25 ms over 206 files (measured 2026-09-15).

- `ecc-review-untracked-max-bytes` is now `ecc-review-max-bytes`, since the limit
  covers the files a session changed as well as the untracked ones -- a lock file a
  package manager wrote again is the usual one. The old name still works as an
  obsolete alias.

### Fixed

- `ecc-review-worktree` opens in a repository that has no commit yet, which is
  where the first code of a project is written and the moment there is most to
  read. It diffs against `HEAD`, and git calls an unborn `HEAD` a bad revision
  rather than an empty diff, so the command stopped at `Git cannot diff against
  "HEAD" (exit 128)` three lines before the half that lists the files git does
  not track -- which on its own would have shown the whole project. When
  `HEAD` names nothing, the diff is taken against the empty tree instead: a
  file already added shows as a new file and the untracked ones follow, as
  they always did. Only the bare `HEAD` stands in this way; `main...HEAD` in
  such a repository really is unresolvable and still says so. The empty tree
  is asked of git rather than written out, because a repository whose object
  format is SHA-256 does not have the 4b825dc of every SHA-1 one. What the
  buffer is named and what its header line says are unchanged, and the test is
  made afresh on every draw, so the first commit puts the real `HEAD` back
  without a refresh having to know anything about it.

## [0.2.0] - 2026-09-14

Verified against **Claude Code CLI 2.1.270**.

### Added

- The skills of a session, in a buffer of their own: `/skills` in the prompt
  region or `S` in the dashboard lists them with what each is for and where it
  came from. `RET` and `SPC` cycle what a skill is set to --
  `on`, `name-only`, `user-invocable-only`, `off` -- `o` opens its `SKILL.md`,
  `a` lists the skills the CLI came with as well, `g` reads the settings again,
  `r` asks the session to scan, and `q` writes the changes and buries the
  buffer.

  The CLI answers none of this for a headless client. `/skills` is its own
  command but is dispatched back to the client and is named in neither
  `commands` nor `slash_commands` -- 57 commands in the initialize answer,
  `reload-skills` and `skill-doctor` among them and no `skills` -- so Emacs
  names the command itself and draws the list. The singular `/skill` is
  answered as well but is not offered: one command under two names is two rows
  in every menu.

  What the terminal client's own dialog does is what this does, measured
  against **Claude Code CLI 2.1.270**. It lists the skills that came from a
  folder -- the project, the user, a plugin, claude.ai -- and leaves out the
  CLI's own bundled skills and its dynamic workflows, which are twenty of the
  twenty-one on a plain setup; those are counted in the header and drawn when
  `a` asks. It works from the commands of the initialize answer as well as from
  the `skills` of `system/init`, so the list is there before the first turn.
  The settings are read localSettings, projectSettings, userSettings, the most
  specific winning, and a skill settled by a policy, a flag or a plugin is
  locked rather than overridden. `RET` walks the four settings and nothing is
  written until `q`, which writes them in one edit and asks the session to scan
  once, however many were made. The state is drawn in the client's marks and
  colours -- `✔ on`, `● name-only`, `◯ user-only`, `✘ off`, `🔒` for one settled
  elsewhere -- in front of the name, where it puts them. A skill is not run
  from the buffer, because that dialog runs none; `/<name>` from the prompt is
  what runs one, and the skills of the session now come first there, in a
  Skills group of their own.

  A change is written to the project's `.claude/settings.local.json`, the file
  the client saves to -- from the Skills buffer and from the plugin browser
  alike, as in the CLI, where the plugin screen and `/skills` share one write: `update_settings` takes the localSettings source alone
  and, in it, the key `outputStyle` alone, so the file is written directly. A
  prefix argument to the save offers the project and user settings instead,
  which is the one thing the client cannot do. The session is then sent
  `/reload-skills`, which it answers with a `system/commands_changed` that no
  longer names the skill; since a skill that is off is named nowhere the CLI
  reports, the list keeps a row for every name the settings mention.

- A plugin browser, on `/plugins` in the prompt region and `M-x ecc-plugin`. The CLI's
  `/plugins` is a screen the terminal client draws for itself: it is named
  neither in `slash_commands` nor in `terminal_slash_commands`, so there is
  nothing to send over stream-json (confirmed against **Claude Code CLI
  2.1.270**). ecc reads and acts through the `claude plugin` subcommands
  instead, and draws four tabs itself: Discover, Installed, Marketplaces and
  Errors. Plugins can be installed at user, project or local scope, turned on
  and off, updated and removed, and marketplaces added, updated and removed.
  Installed lists the skills beside the plugins, as the real screen does, and
  turns them on and off through `skillOverrides` in the settings, which is what
  the CLI reads and what it offers no subcommand for; the reading and the
  writing are `ecc-skill`'s, so the browser and the Skills buffer cannot say
  two different things about the same skill. `s` filters the rows as
  it is typed and `/` jumps to one by completion, which is the better way
  through a marketplace of 297. A change offers the running sessions `/reload-plugins`, since a
  session keeps the plugins it started with (`ecc-plugin-reload-sessions`).
  Nothing exports the plugin load errors of the real Errors tab, so that tab
  holds what Emacs can see itself. The real screen's fifth tab, Stats, counts
  skill tokens over a week of local sessions and is not exported at all, so
  there is no Stats tab rather than a tab of something else wearing its name;
  what one plugin brings and costs is on `RET`.

- `ecc-review-worktree` (`G` in the menu) reviews the git diff of the whole
  project, not only the files the session touched: every uncommitted change,
  staged or not, plus the untracked files `.gitignore` does not exclude. A
  prefix argument asks what to diff against, so `main...HEAD` reviews a branch.
  The hunks are commented and sent as one prompt the way `ecc-review` does, and
  the two live in separate buffers.  It is on `C-c c G` as well as on the menu,
  because the buffer it is meant to be run from is a file of the project, not a
  transcript: the project is the one of that buffer, and the comments go to a
  session of that project, which is started when there is none.  An untracked
  file that is binary, or larger than `ecc-review-untracked-max-bytes`, is named
  rather than printed: git compares a new file against /dev/null, and an empty
  side is text, so without the check the bytes of a PNG land in the review
  buffer (confirmed with git 2.51).  A revision git refuses -- a typo in the
  range -- says so instead of showing a tree that looks clean but for its
  untracked files.
- `ecc-hooks-show`, on `/hooks` in the prompt region, lists every Claude Code
  hook that would run for a project: the managed settings,
  `~/.claude/settings.json`, `.claude/settings.json`,
  `.claude/settings.local.json` and the `hooks.json` of every plugin
  `enabledPlugins` leaves on, grouped by the event that fires them and marked
  with where each came from. What stops hooks from running is said at the top:
  managed settings in force, or `disableAllHooks`. `RET` opens the file a hook
  is defined in, `a` adds a command hook, `k` removes one and `t` switches one
  off and on again. The CLI's own `/hooks` is declared ink-only, so it is in
  neither `slash_commands` nor `terminal_slash_commands` and a headless client
  is never offered it; Emacs answers the name itself, the way it answers `/btw`
  and `/plugins`. That menu is read-only besides — "To add or modify hooks,
  edit settings.json directly or ask Claude" (confirmed against **Claude Code
  CLI 2.1.270**).

  Nothing is written without a confirmation naming the command, the event, the
  matcher and the file, and the file offered first is the one that is not
  committed. Matchers are read one at a time until an empty answer ends the
  list, and written as the `|` list the CLI reads. The CLI has no field for a hook that is there but switched off, so
  switching one off takes the entry out of its settings file and keeps it whole
  in `~/.claude/ecc-disabled-hooks.json`; switching it on again puts it back. A
  settings file the CLI reads never carries anything ecc invented. Hooks from a
  plugin and from managed settings are listed and never edited.

  A session already running keeps the hooks it started with: the CLI watches
  only the directories that held a settings file when it started, so an edit
  here takes effect the next time that session is started. Every message says
  so.

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

- `ecc-hook-events-enabled` is now `ecc-show-hook-events`, and a `defcustom`.
  The old name read as though it decided whether hooks ran at all; what it
  decides is whether the transcript draws them. A session's hooks run either
  way, and one that leaves with exit 2 blocks its tool call either way. The old
  name still works as an obsolete alias.

- A slash command Emacs answers itself and that needs no argument runs the
  moment it is chosen from the `/` question: `/hooks`, `/skills` and `/plugins`
  open their buffer, and neither the name nor the slash is left in the prompt
  region. `/btw` and `/login`, whose argument is the point of them, are written
  out as before (`ecc-prompt-immediate-commands`).

- In the Hooks buffer, `RET`, `a`, `k`, `t` and `TAB` answer to the line point
  is on rather than to the character under it, and the keys are listed under
  the title.

- A hook event in the transcript shows what the hook printed, rather than the
  raw message cut at 400 characters: the event, the exit code, and stdout and
  stderr, the latter in the face that means something went wrong. The heading
  carries the exit code when it is not zero, since exit 2 is the one that
  blocks a tool call. Turn hook events on with `ecc-show-hook-events`.

- `ecc-review-context-lines` now reaches the diffs git makes for a review as
  well as the ones ecc builds itself: it is passed as `-U`.  It is an argument
  of the git ecc runs, not a `git config`: nothing outside the review changes.

- **Breaking:** `ecc-review-context-lines` is a `defvar` rather than a
  `defcustom`, and its default is 0 rather than 3.  A comment on a review is
  attached to a whole hunk, so the hunks want to be the size of the change and
  no larger; a `setq` still widens them for reading.  A `custom-set-variables`
  entry for it keeps working, but it is no longer in the Customize interface.
  The review of one proposal is not part of this: it keeps three lines through
  `ecc-review-proposal-context-lines`, because allowing a change is a judgement
  about what it overwrites as much as about the change.

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

- Typing in another buffer while a session streams is no longer held up by
  the session's bookkeeping.  Every line the CLI sent was written to the
  session's log buffer and the buffer then trimmed to `ecc-log-max-lines`,
  which walked back over all 5000 kept lines and moved the whole buffer down
  by one line each time: 88% of what a streamed delta cost once a session
  had been running a while, and paid whether or not the session was on
  screen.  The log now grows a fifth past the limit and is cut back once.
  The text of a streaming block was also joined again on every delta, so a
  long reply copied itself thousands of times over and made ten garbage
  collections -- each of which stops every buffer, not just the session's.
  The deltas are kept as they come and joined when the block is redrawn.
  One reply of 8000 deltas went from 1260 ms with 11 collections to 69 ms
  with one (measured 2026-09-13).

- A session that Remote Control announced itself in before the first prompt
  no longer redraws its whole transcript on every change.  Those notes go
  under a turn that has no prompt and never ends, and the renderer judged a
  turn finished by its end time alone, so the live region -- the part drawn
  again whenever a block starts or stops or a tool returns -- began at the
  top of the transcript for the life of the session: in one of 380 KB,
  every redraw took 30 to 60 ms and left 1.6 MB of garbage, which is what
  typing in another buffer felt as a stutter every couple of seconds.  A
  turn that is not the current one and has nothing running under it is
  finished too.

- A redraw of the live region no longer lays the Files summary out again
  line by line, nor fontifies a reply again that stands behind a call still
  running.  The diff of each file is now kept as it is drawn, with its
  prefix and wrap, until the file changes again, and the Markdown of a
  reply, a prompt and a plan is fontified once per node while its text
  stays the same.  In a session with three edited files a redraw went from
  5.7 ms to 1.5 ms (measured 2026-09-13); `scripts/bench-render.el` puts the
  Files summary of 60 files at 3.6 ms, from 5.3.

- A redraw that fails half way no longer leaves the transcript inside the
  prompt region.  The live region is deleted before it is drawn again, and
  the marker that opens the prompt region collapses onto the deletion; a
  draw that signalled before moving it past what it drew left that text in
  the prompt region, where the next send took it for the draft.  The
  markers are now moved whether the draw finishes or not; the error itself
  still reaches the log.

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

[Unreleased]: https://github.com/wakamenod/emacs-claude-code/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.2.0
[0.1.0]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.1.0
