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

## [0.3.2] - 2026-09-24

Verified against **Claude Code CLI 2.1.280**.

Verified against **Claude Code CLI 2.1.274**.

### Fixed

- A picture or a video that a command wrote is drawn in the transcript. The
  renderer had two sources of pictures -- the image blocks of a tool result
  and the `file_path` of a tool input -- and a Bash call has neither: its
  input carries a `command` and its result is plain text. So the one way a
  video actually comes into being here, `demo/record.sh` run through Bash,
  drew nothing, and the feature had only ever worked for a video attached to
  a prompt by hand. A command tool that names no `file_path` now has what it
  wrote worked out once, when its result lands
  (`ecc-dispatch--note-written-images`): a name found in the command or in
  the result text is kept only when the file is there and its modification
  time is at or after the start of the call, so `ls demo/` draws nothing and
  `open shot.png` draws nothing either. The renderer reads that stored list
  as its third source, which keeps the redraw path free of the disk. A
  recorded demo therefore comes up unfolded with its first frame showing.
  `ecc-dispatch-command-tools` names the tools this applies to and
  `ecc-dispatch-max-written-images` caps how many are kept.

- A Space with more sessions than its row has room for no longer comes up
  with the transcripts crushed to two columns each. The rightmost window of
  the row was widened to make room for the next split with `window-resize`
  told to ignore every minimum, which took the transcripts beside it down
  to `window-safe-min-width` one after another -- seven sessions in a
  429-column frame gave five windows of ten columns. The room now comes
  from the other session windows alone, each giving in proportion to what
  it has above `ecc-space-session-min-width` and none going under it, and
  never from the source; when that is not enough the row is full, which is
  the rule `ecc-space-session-min-width` has always stated: the sessions
  that do not fit run with no window, and the sidebar or `C-c c V` brings
  them back.

- A session window asked to be wider than the frame has room for no longer
  takes the difference out of the sidebar. `display-buffer` makes a new
  window the width it was asked for with a resize told to ignore every
  minimum and every `preserve-size`, so a column count in `ecc-window-width`
  that the source window could not give came out of the sidebar instead --
  ten columns of a 28-column sidebar, in an 80-column frame. The width is now
  capped at what the divided window has to give, which keeps the resize
  between the two halves.

- A repeating timer whose tick could not keep up took the whole of Emacs
  with it. Emacs runs due timers for as long as one is due, a timer runs
  with `inhibit-quit` bound, and a repeat timer that is late is put back
  into the past, so a tick slower than its interval was due again the moment
  it ended: no key, no `C-g`, no emacsclient got through until a SIGUSR2
  broke the tick. The sidebar's spinner took 0.39 s a tick on a 0.2 s timer
  in an Emacs that had run for 27 hours without collecting garbage. Every
  repeating timer of the package -- the spinners of the sidebar, the
  dashboard and the session buffers, the pulse and the blink of a line, the
  blink of the tab line -- now goes through `ecc-visual-repeat`, which
  cancels a timer whose tick outlasts its interval twice running, the time
  spent in garbage collection left out, and sets the variable that turns
  that effect on (`ecc-visual-enable-spinner`, `ecc-visual-enable-pulse`,
  `ecc-visual-enable-blink`, `ecc-tab-blink`) to nil with a message saying
  so. An effect that cannot keep up is worth less than an Emacs that answers.

- The spinners of the sidebar and the dashboard turn in place. A tick used
  to erase the buffer and draw every row again -- with git asked under every
  Space in the sidebar -- and every insertion walks the whole chain of
  markers of the buffer, which winner, tab-bar-history and anything saving
  match data lengthen with every command. The tick now draws the frame over
  the spinners that are there (`ecc-visual-spinner-refresh`) and touches
  nothing else; the rows change on the hooks, as before. Undo is off in
  both buffers: a redraw is nothing to undo, and the history was holding
  32,000 of them and every marker of the buffer with them.

- A block of the transcript is inserted as one string rather than a line at
  a time. Two insertions a line were four hundred walks of the marker chain
  for a block of two hundred lines, and at 40 ms a walk in a long-lived
  Emacs a single redraw took seconds; `scripts/bench-render.el` went from
  0.2--0.6 ms to 0.1--0.2 ms a redraw of the live region, and the Files
  summary from 2.5 ms to 1.6 ms.

- `ecc--truncate` and `ecc--fit` no longer save the match data. Saving it
  after a search in a buffer makes a marker per group in that buffer, and
  the sidebar was leaving seven a redraw, five times a second, in an Emacs
  that never collected them.

## [0.3.1] - 2026-09-18

Verified against **Claude Code CLI 2.1.274**.

### Changed

- `make lint` runs the package checker rather than skipping it, and fails on
  its errors. An error is a defect -- a header nothing reads, a global mode a
  user's init cannot turn on -- and a warning is a judgement, several of this
  package's being deliberate, so warnings are printed and are not fatal
  (`scripts/lint.el` carries the reasoning). `make lint-deps` installs the
  checker, and the lint job of the CI workflow now does that before running
  the target: the check was not installed on the runner, so the job was green
  whatever the state of the package, which is how the two defects above
  reached a release.

- Every source file now opens with the GPL-3.0-or-later notice the `LICENSE`
  file and the README already named, an `SPDX-License-Identifier` line, a
  `Maintainer` and a `URL`. A file is read on its own often enough -- quoted
  in a bug report, vendored into somebody's configuration -- and without a
  notice in it the terms are unknowable from the file itself.

- `Package-Requires` is written in `ecc.el` alone. The forty-two secondary
  files each carried a copy, and not one of them was ever read: an installer
  reads the main file's. Forty-two copies of a number nobody reads were
  forty-two chances to say a different Emacs than `ecc.el` says, which is the
  argument this project already makes about `Version`.

- The five global minor modes -- `ecc-pending-indicator-mode`,
  `ecc-mcp-indicator-mode`, `ecc-tab-line-mode`, `ecc-notify-mode` and
  `ecc-track-source-buffer-mode` -- carry an autoload cookie. A global mode is
  turned on from an init file before anything has loaded the file that defines
  it, and without the cookie `(ecc-notify-mode 1)` there was a void function
  and a `custom-set-variables` of the variable of the same name set a variable
  no mode was watching. Two cookies on private helpers, which nothing outside
  their own files calls, are gone.

- A `.dir-locals.el` names `ecc.el` as the file the package is declared in. A
  checker handed one file of a package spread over forty-three has no way to
  know which package it belongs to, so it read the file name as the prefix and
  called every `ecc-` name in `ecc-render.el` a name borrowed from elsewhere:
  380 complaints about nothing, and the nine real ones lost among them.

- The Commentary of `ecc.el` names the four commands a session is reached by
  and says that the CLI is a separate program, rather than ending in a
  `\[ecc-start]` that only a docstring substitutes. Three file summaries begin
  with a capital and two no longer say "Emacs" to a reader who is in Emacs;
  `ecc-resume` quotes its key sequences as keys; a docstring in
  `ecc-review-ediff` no longer opens a line with an unescaped parenthesis in
  column 0; and two messages in `ecc-tui` begin with a capital.

### Fixed

- The comparison table in the README said two of the four other projects are
  published in a package archive. Neither is: `claude-code-ide.el` and
  `claude-code.el` are both installed from GitHub, by their own READMEs and by
  the absence of a recipe for either, and the archive name `claude-code` belongs
  to a different project altogether. The table also listed `eca` among the
  dependencies of `eca-emacs`, which is that package itself. Each project's
  `Package-Requires` was read again while correcting this (2026-09-18); the
  dependency and Emacs-version cells were right, and the table now says what
  the dependency column means -- `transient` is part of Emacs 28.1 and up, so
  the packages that name it need a newer one than their Emacs ships, and ecc
  uses `posframe` and `nerd-icons` only when they are installed.

- A session whose CLI was told to keep its state somewhere else was read from
  `~/.claude` regardless. `CLAUDE_CONFIG_DIR` moves the whole of that
  directory -- the recorded conversations, the running sessions, the settings,
  the skills, the plugins and the credentials with them; a `claude doctor`
  under it reports a machine that is not signed in (confirmed against CLI
  2.1.274). ecc starts the CLI with the environment of this Emacs, so the
  directory the CLI uses is the one this Emacs names, and reading `~/.claude`
  anyway meant reporting on a directory the session never touched: no
  conversations to resume, no sessions listed as running elsewhere, and the
  wrong settings file edited. The six directories now come from
  `ecc-config-directory`, which reads `CLAUDE_CONFIG_DIR` from
  `ecc-extra-environment` first -- that is what ecc puts in front of what
  Emacs inherited -- and from the environment of this Emacs after it. The
  `.claude.json` the projects are listed in follows the same move:
  `~/.claude.json` beside the default directory, and inside the directory
  `CLAUDE_CONFIG_DIR` names. Each of the six is still an ordinary variable, so
  an Emacs that has to say otherwise sets one.

- Closing the tab of the session a window was showing took the window with it.
  The `x` of a tab stops the session behind it, and the window of a session
  that is stopped is deleted so that a row of transcripts is not left holding
  `*scratch*`. With a tab line the window is one of a row of tabs, though, and
  losing one tab is no reason to lose the window: it now moves to the tab
  beside the one that closed -- the tab to its right, or the one to its left
  when it was the rightmost. A tab another window of the frame is showing
  already is passed over, so that the transcripts of a Space, which stand
  side by side under one row of tabs, are not doubled up; the window is
  deleted when nothing is left for it to show. With `ecc-tab-line-mode` off
  nothing changes.

- Quitting an ediff review with `q` left the Emacs it came back to with no
  cursor drawn anywhere until something was clicked. On a graphical Emacs the
  control panel is a frame of its own and holds the keyboard while the review
  is read; `ediff-cleanup-mess` deletes it and selects the frame the two sides
  were shown in, but within Emacs only -- the window system is never told, and
  no frame is the one it considers focused. A frame that is not focused draws
  its cursor the way a window that is not selected does, which where
  `cursor-in-non-selected-windows` is nil is no cursor at all. The review now
  remembers the frame it opened in and gives it the input focus back once the
  panel has been taken down. Plain `ediff-buffers` does the same thing, and
  this fixes it for the reviews ecc opens.

- An ediff review marks the difference it is standing on apart from all the
  others.  `ecc-review-ediff-diff-faces` gives every other difference the
  colours of `diff-removed` and `diff-added`, and a theme is free to paint
  `ediff-current-diff-A` and `-B` in exactly those colours -- modus-vivendi
  gives both `#4f1119` on the left and both `#00381f` on the right -- so
  every difference of the review looked like the one being read and nothing
  said where `n` had just arrived.

  Two marks now, in the two buffers of the review alone.  The colour of the
  current difference is carried five points of lightness away from the
  frame's background, from the shade the theme itself gave it and in bold
  (`ecc-review-ediff-current-diff-faces`, `ecc-review-ediff-current-diff-step`);
  and a bar is drawn in the fringe beside every line of it, which is not a
  colour to compare -- a line has it or it does not
  (`ecc-review-ediff-current-diff-mark`, `ecc-review-ediff-current-mark-face`).
  The refinement within a line keeps `ediff-fine-diff-A` and `-B`.

  A frame can be set up with no fringe at all -- `left-fringe` 0 in
  `initial-frame-alist` -- and the bar then has nowhere to be drawn, so the
  review gives its own two windows a fringe of
  `ecc-review-ediff-fringe-width` when the frame shows none.  The windows are
  the review's own and go back with the rest of the arrangement when it
  quits; every other window of the frame is left as the user set it.

## [0.3.0] - 2026-09-18

Verified against **Claude Code CLI 2.1.274**.

### Added

- `ecc-space-reset-windows`, `C-c c V` and `V` in the menu: put this Space back
  to the arrangement a new tab gets -- the source of the project on the left,
  the transcripts beside it, most recently used first, stopping where the row
  has no room for another column of `ecc-space-session-min-width`. It runs the
  same code a new tab is dealt with, so the two cannot drift apart.

  The windows of a Space are the user's and nothing rearranges them on its own,
  which left no way to say start again: a tab that had been split, zoomed,
  filled with a review or given over to transcripts had to be unpacked by hand.

  The sidebar keeps its place and its width, being a side window that asked not
  to be deleted, and a sidebar that was hidden comes back -- a new tab has one.
  The zoom of the tab is forgotten as it goes, the arrangement it was the way
  back to having just gone. A `spaces` command: under `classic` the roles are
  `ecc-focus-project`'s to deal out.

- `ecc-worktree-menu`, `W` in `ecc-menu`: `c` makes a worktree and starts a
  session there, `o` starts one in a worktree that exists, `k` removes one.
  Three commands that belong together, and that are used in a week what the
  keys beside them are used in an hour.

- `ecc-prompt-history-insert` (`C-c C-r` in the prompt region, `H` in
  `ecc-menu`) picks a past prompt from a list and inserts it at point.  The
  history holds two hundred prompts and `M-p` walks it one entry at a time,
  replacing the whole region as it goes, which is no way to reach the fiftieth
  entry back.  The list shows each prompt flattened to a line, most recent
  first, and what goes in is the whole of the one chosen -- next to whatever
  was already being written, rather than in place of it.

- Images and video are drawn in the transcript.  Four things put one there:
  an `image` content block on an assistant or a user message, an image block
  inside a `tool_result` (a `Read` of a `.png`, a screenshot from an MCP
  tool), an image file named by a tool's `file_path` where the result carried
  no picture of its own, and the images a prompt attached as `@path`.

  None of it reaches the buffer as base64.  The payload is decoded where the
  message is dispatched and written into the session's image directory under
  the sha1 of its bytes, and only the path, the media type and the size are
  kept on the node.  The same image arriving twice -- once in the block that
  streams and once in the message that closes it -- is one file and one node.

  Before this, an image block on a message became an `unknown` node and was
  drawn as two thousand characters of base64, a streamed one opened no node
  at all and its deltas were dropped, and an image in a tool result was
  serialised back to JSON and drawn as a wall of text that the twelve-line
  result clip could not cut, because base64 is one line.

  Each picture sits on a line that names the file, so a copy of the region, a
  search through it and a snapshot of it all find the name; a terminal frame,
  a build without the library for that type and a batch Emacs are left with
  that line.  The images of a tool call are drawn inside its body, so a fold
  hides them with it, and after the result clip rather than through it, so a
  long result is not what decides whether a screenshot is seen; at most
  `ecc-image-max-per-node` of them, the rest counted.  A tool call that
  brought one comes up open, whatever tool nodes do in general: a `Read` of a
  `.png` and an MCP tool that answers with a screenshot are the two
  commonest ways a picture arrives at all, and both drew a heading with the
  picture behind the fold.  `TAB` folds it away again, and with
  `ecc-image-inline` off there is nothing to open for.  An image the CLI named
  by URL is drawn as the URL and never fetched: the renderer does not go to
  the network.

  A video cannot be drawn in a buffer, so where `ffmpeg` is on `PATH` its
  first frame is pulled out and shown instead, in a subprocess
  that is never waited for -- the line naming the file stands until the frame
  lands.  A video ffmpeg cannot read is tried once, not once per redraw.

  A GIF starts moving as soon as it is drawn and loops for as long as it is
  on screen, at one timer each and a redisplay of 0.25 ms for ten of them
  against 0.10 ms still.  It stops itself: `image-animate` is given the
  position the picture sits at and gives up once the text there is no longer
  that image, which is what a redraw of the live region does to it.  Without
  that position every redraw left the timer of a picture no longer in the
  buffer turning its frames -- three GIFs and ten redraws left thirty such
  timers and animated none of them.  Scrolling away does not stop it: the
  test is on the text, not on the window.

  `I` in the transcript stops the picture at point moving, or sets it moving
  again, and does nothing else: `RET` is what opens one, a still in
  `image-mode` and a video in whatever the machine plays one with.
  `ecc-image-inline`, also `I` in the menu, turns the drawing off.  It is
  the one setting this adds: the height a picture is drawn at, whether a
  GIF moves by itself and which ffmpeg is used are `defvar`s, reachable
  with `setq` and bindable in a test, and not choices to put in front of
  somebody.  A drawn image is limited in height and its width follows
  `ecc-chat-text-width`.

  There is no cache of image descriptors: `create-image` conses a list and
  reads nothing, about a third of a microsecond a call, and two equal
  descriptors share one entry of the image cache Emacs keeps of its own.
  `scripts/bench-render.el` sees nothing at 800 tool calls with a fifth of
  them carrying an image.  It now also sweeps before each measurement --
  adding a case to it had moved an untouched number from 1.7 ms to 4.3, which
  was the heap the new case left behind rather than the renderer.

  New module `ecc-image.el`, a leaf below `ecc-render`.  `ecc-prompt-save-image`
  moved there as `ecc-image-save` and `ecc-prompt--image-extension` as
  `ecc-image--extension`, with `ecc-image-dir`, `ecc-image-cleanup`,
  `ecc-session-image-dir` and `ecc-image-cleanup-session`: `ecc-prompt`
  requires `ecc-render`, so the helpers that write an image to disk could not
  stay there and be called from the renderer as well.

- `ecc-review-style` opens `ecc-review` (`D`) and `ecc-review-worktree` (`G`)
  in ediff instead of the one `diff-mode` buffer. `'diff`, the default, is
  what both did before; `'ediff` lays what the files held on the left and what
  they hold now on the right.

  Every file of the review is in one ediff session, not one session per file:
  the two sides are concatenated, each file under the same `═══ path ═══`
  separator line with a blank line in front of it, so `n` and `p` walk every
  difference of the review across the file boundaries.  The two sides are put
  left and right rather than one above the other: `ediff-split-window-function`
  is set in the control buffer of the review alone, which is where ediff reads
  it from, so no other ediff is touched, and the windows are laid out again
  there and then -- ediff runs a session's startup hooks after it has already
  set the windows up, so the review would otherwise open in ediff's own layout
  and turn into this one at the first keystroke.  Both are `defvar`s --
  `ecc-review-ediff-split-window-function` (nil leaves ediff's own layout) and
  `ecc-review-ediff-file-spacing`.  Where the control panel goes is ediff's own
  `ediff-window-setup-function`, which this package does not touch. A binary file, or one larger than `ecc-review-max-bytes`, is
  its separator line alone, saying why, and is no difference at all. ediff's own
  session groups were not used: they walk files rather than differences, and
  reach for internal functions, file names and a non-recursive directory scan.

  Both sides are read-only, and so `a` and `b` -- ediff's own copy commands --
  say what a review is instead of doing anything: a review reads, comments and
  sends, and what changes the files is Claude, from the prompt the comments go
  out as. Left to ediff they signalled `buffer-read-only` against a buffer the
  user had not asked about, from a key the review's own help does not offer.

  The comments are the same comments. `c`, `d` and `l` sit on differences
  rather than hunks, but they carry the same file and the same line numbers
  inside it, and `C-c C-c`, `C-u C-c C-c` and `C-c C-k` are the same commands
  sending the same prompt. Quitting -- by `q`, by `C-c C-k` or by sending --
  puts back the windows that were on the screen before the review opened.
  There is no `g`; quit and open the review again.

  `?` shows a help written for the review rather than ediff's own.  ediff's
  is the one a two-way comparison usually wants: it offers `a` and `b`, `rx`,
  `wx`, `wd` and `~`, none of which do anything where both buffers are
  read-only and each side is every file of the review at once, and it says
  nothing of `c`, `d`, `l`, `C-c C-c` and `C-c C-k`, nor that `q` closes a
  review without asking.  The help is ediff's own three-column layout with
  only the commands a review really has on it, and the brief message the panel
  carries with the help off names them too.  It is set through
  `ediff-long-help-message-function` and `ediff-brief-help-message-function`,
  which ediff reads out of the control buffer of each session, so no other
  ediff's `?` changes; the messages are composed again in the startup hook,
  because ediff writes the help into the panel before it runs them.  Clicking
  a line of the help, and `RET` on it, do nothing now: they looked the command
  up in the ediff manual, which has no entry for `c`, `d` or `l` and answered
  them with "Undocumented command!".

  Both reviews now always compare two git trees: the session's baseline, or
  `HEAD`, against a snapshot of the working tree, and for a range the two trees
  of the history. `ecc-review-snapshot` takes a `no-add` argument for the one
  side that is neither, the index, which is what a review of what is not staged
  yet compares against.

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

  What the session was really started with is kept on it as it starts, and
  that is what stands until the CLI names one.  Both answers can change under
  a session that is already running -- a `model` written into the settings
  files, an `ANTHROPIC_MODEL` bound around the start alone -- and working them
  out again on every footer had it name a model the CLI was not running.

  The footer is drawn after every command and the answer lies in files, so the
  settings files are stat'ed and read again only when one has been written to.
  A remote project root is left out: its settings are on the other machine.

- A second way to lay the windows out, chosen with `ecc-use-spaces`, **and it is
  the default**. Off, the windows are what this package has always done: a
  transcript goes into a side window with a role -- main, sub-1, sub-2 -- and
  `ecc-focus-project` deals the roles out again for one project. There are then
  no tabs, no sidebar and no worktree commands.

  On, every project gets a tab of the tab bar instead -- a Space -- and the
  windows inside it are left alone. The transcripts stand side by side and
  are never stacked: the first opens as an ordinary window beside the source,
  every one after it divides the rightmost of them, and from there they are the
  user's to split, move and enlarge. A tab is a window arrangement, so going to
  another Space and back brings the whole of it back the way it was left. A
  worktree is a Space of its own, drawn under the repository it came from and
  named by its branch; a session started in one goes by that branch as well,
  rather than by its directory, which is a slug of the branch and says
  nothing more.

  Which tab a Space lives in is kept on the frame it was opened on, so a
  Space may have one on each. A tab belongs to a frame -- Emacs can only
  find one by name on the frame that is selected -- and a table for the whole
  Emacs said a Space had a tab that the frame in front could not see: the
  record was dropped, a second tab opened here, and the frame it came from
  was left with one nothing pointed at. Closing a Space now closes its tab on
  every frame that has one, its sessions being stopped wherever they were
  shown (verified on two frames, 2026-09-17).

  The bar itself is the user's. A tab is a named window arrangement of the
  frame and `tab-bar-mode` only draws the strip above it, so nothing here
  turns that mode on: `tab-bar-new-tab` does it where `tab-bar-show` is `t`,
  its default, and leaves it alone where the user set that to `nil`. With the
  bar hidden the tabs are made, named, switched and closed all the same, and
  quietly -- `tab-bar.el` announces every one of those in the echo area when
  it has no bar to show them on, which would be each move between Spaces
  reported twice. The sidebar is the list of Spaces either way, and it holds
  more about each than the strip can.

  How many transcripts stand abreast is `ecc-space-session-min-width`, the
  columns one may not go under (`window-min-width` is a floor under it). A row
  with no room for another column does not grow a narrower one: the session
  worked in longest ago hands its window over and goes on running without one,
  which the sidebar and `ecc-space-reset-windows` bring back.

  A Space whose tab has to be made comes up with its sessions already dealt
  out, most recently used first, until the row has no room for another column.
  Opening a worktree opens the repository it was checked out from behind it,
  so that the worktree has something to hang under and the sidebar can draw
  the tree git describes; the worktree is what is left in front.

  `ecc-space-always-session` says whether a Space always holds a session, and
  it is what a Space is made of rather than a detail. On, the default, going to
  a Space with nothing running in it starts a session there -- a tab with a
  file in it and no way to say anything is a Space that looks broken, and going
  to a Space is asking to work there -- and a Space closes itself when its last
  session goes, taking the user to the Space beside it. Off, opening a Space
  starts nothing and shows the source of the project, and the Space stays until
  the last buffer of the project is killed as well. A session whose process
  exited is not a session that has gone: it keeps its place, so `/resume` has
  somewhere to come back to.

  A session that is killed takes its window with it rather than leaving it to
  Emacs, which would put whatever was there before the transcript -- usually
  `*scratch*` -- in the middle of a row of transcripts. The last window of a
  tab cannot be deleted and is given the source of the project instead.

  `ecc-space-close` on a repository closes the worktrees drawn under it too,
  stopping everything running in the group after one question; a worktree
  closed on its own leaves the repository where it is. No checkout is touched
  either way -- `ecc-remove-worktree` is still what undoes one -- and a
  repository that was only opened to hold a worktree goes when the last
  worktree under it does. With `ecc-space-always-session` on, `ecc-kill` on the
  last session of a Space now closes that Space before it offers to remove the
  checkout.

  `ecc-space-goto` also reaches a project there is nothing left of but its
  recordings, so a project worked in before can be gone back to. Those are
  deliberately kept out of the sidebar and out of the numbering: putting them
  there would move the numbers the `1`-`9` keys take under the user's feet.
  Finding them reads every recording once for the directory it was made in
  (0.12s over 244 of them here, and nothing after that): the directory a
  recording sits in does not answer the question -- its name is the working
  directory with everything that is not a letter or a digit turned into a dash,
  which is not invertible, and one repository is named by as many directories
  as it has worktrees and truenames.

  A question, a plan, a log or an agent transcript opens beside the session it
  came out of, in that session's Space and with the transcript still on the
  screen. It takes the widest window that holds no transcript -- in a Space,
  the one the code is read in -- and that window goes back to what it held
  when the buffer is quit. Only where every window on the tab is a transcript
  is one of them divided; none is ever taken away. Left to `display-buffer`,
  that is what happened: the session windows of a Space are narrower than
  `split-width-threshold`, so none could be divided and
  `display-buffer-use-some-window` handed over whichever window had been used
  longest ago -- the transcript of another session, which then vanished, or a
  leftover window that fell back to `*scratch*` when the buffer was closed.

  `C-c c j` (`ecc-space-goto`) and `ecc-space-jump` go to a Space,
  `ecc-space-close` closes one and stops what is running in it, and `C-c c z`
  (`ecc-space-zoom`) fills the tab with the window point is in and puts the
  windows back again.

- A sidebar, `C-c c b` (`ecc-sidebar-focus`): a narrow window down the left of
  the frame with the Spaces at the top -- every project and worktree, numbered, each
  marked with what it is doing and what branch it is on -- and the sessions at
  the bottom, with what each is waiting for. It stays on the screen while you
  work, which is the one thing the dashboard does not do, and it never takes
  the selected window.  How wide it is drawn is `ecc-sidebar-width`, a
  setting for the reason `ecc-space-session-min-width` is one: twenty-eight
  columns of a laptop at a large font and of a 34-inch display are not the
  same fraction of the frame.

  The same key goes in and comes back out: the window is `no-other-window`, so
  `C-x o` never lands there by accident while working, and `C-c c b` is the way
  in. `ecc-sidebar-toggle` shows and hides it without going in.

  `RET` goes to what the row stands for, `n` and `p` move, `TAB` folds a
  repository's worktrees away, `1`-`9` go to a Space by its number, `c` starts
  a session there, `W` makes a worktree of it, `a` and `d` answer what that
  session is waiting on, `k` stops it, `K` removes a worktree, `X` closes a
  Space -- each a step larger than the one before -- `g` asks git again and
  `q` hides the sidebar.

  `a` and `d` answer whatever kind the session is waiting on -- a permission,
  a question, a plan -- and ask before they do, and they leave the tools of
  `ecc-answer-exclude-tools` alone, which is `Bash`: a shell command is read
  where it was asked, and a row carries a summary cut to twenty-eight columns.
  `RET` is the way to where it can be read. What a row may answer is
  `ecc-answer-session-request`, which the dashboard asks as well, so the two
  lists cannot drift apart.

  The marks, the colours and the beat of the blink are the tab line's, so a
  session says the same thing wherever it is drawn, and the spinner turns only
  while something is running where it can be seen. With `spaces` the sidebar
  comes up with every Space; with `classic` it can be toggled on all the same,
  and `RET` on a Space focuses the project the way it always has.

- `/resume`, typed in a session, carries that window on with another recorded
  conversation of the project: the CLI is stopped, the session is emptied, its
  id becomes the recording's, the recording is read into the same buffer and
  the CLI is started again with `--resume`. The window, the tab, the buffer,
  the session name and the review baseline do not move -- what changes is which
  conversation is in them, which is what the terminal client's own `/resume`
  does. The name is Emacs's own: the CLI names no `resume` in `slash_commands`
  and none in `terminal_slash_commands` (checked against 2.1.270), so nothing
  is shadowed and nothing of ours reaches the CLI.

  It is what makes an automatically started Space worth starting: going to a
  project with nothing running opens a fresh session, and `/resume` is how the
  conversation that was there is picked up. `/resume <session-id>` takes one by
  id without asking.

  A session held in a terminal is refused; a recording another process is
  running, a conversation that already holds turns and prompts still queued are
  each asked about before anything moves. The conversation walked away from is
  left exactly where it is, and `ecc-history-open` reads it again.

  A recording whose `cwd` sat past the first 8 KiB used to be dropped from a
  project-filtered `ecc-history-recordings` -- the picker's list, among other
  things. It is now looked for further in.

- Worktrees, as somewhere a session can live: `ecc-start-worktree` -- `W c` in
  the menu --
  checks a branch out beside the repository and starts a session there,
  `ecc-start-in-worktree` starts one in a checkout that exists already, and
  `ecc-remove-worktree` stops the sessions working in a checkout and undoes
  it. The branch is never deleted with the checkout on its own -- what is
  undone is a checkout, and the work is on the branch -- but once the checkout
  is gone the branch is offered, as a question of its own, to whoever has just
  undone it. Saying yes runs `git branch -d`, and a branch whose commits are on
  no other branch takes a second yes before `-D`. Nothing is asked for a
  detached checkout, which had no branch, or for a branch another worktree
  still holds, which git would refuse anyway.

  Stopping the last session working in a worktree offers to undo the checkout
  there and then, which is the moment anybody is thinking about it: from
  `ecc-kill` asked for by hand, the dashboard's `k`, the sidebar's `k` or the
  tab's close button. Stopping one of two sessions in the same checkout offers
  nothing, and neither does `ecc-space-close` or `ecc-remove-worktree`, which
  stop several sessions in a row. Buffers still visiting the checkout are
  counted in the question rather than closed.

  A checkout that goes takes its Space with it: the tab is closed and the key
  forgotten, under `spaces`, before the directory is removed -- read
  afterwards, the project key of a directory that is no longer there need not
  be the one its sessions grouped under. Without this the Space stayed in the
  sidebar and in `1`-`9`, a row with nothing under it pointing at nowhere.

  A branch that is checked out somewhere already is gone to rather than
  refused: one branch lives in one worktree at a time, so asking for it can
  only mean the checkout that has it. The branch is what is looked up, not the
  directory, so a checkout named by somebody else is found all the same --
  Claude Code's own worktrees turn a `/` into a `+` where this turns it into a
  `-`.

  A piece of work can be handed to a session in a worktree of its own without
  anybody leaving the conversation it came up in. With the Emacs MCP server on
  (`ecc-mcp-enabled`), the model is offered `start_worktree_session`: asked for
  something to be done in a worktree, on a branch or in a session of its own,
  it names the branch and writes the brief, and Emacs makes the checkout, opens
  it as a Space, starts a session there and sends it that brief. The new
  session is told where it is and who sent it, because it cannot read the
  conversation it came from. Left to itself the CLI runs `git worktree add` and
  carries on in the same session, which leaves one conversation working in two
  checkouts. `ecc-worktree-delegate` is the same thing from Lisp.

  The brief carries what Emacs knows as well as what the model wrote: the files
  the conversation touched, by the name the new checkout has for them, the
  plans it wrote, the path of its recording to read only if the brief leaves a
  question open, and the changes that are uncommitted in the repository -- a
  checkout is made from `HEAD`, so a brief leaning on one of those sends the new
  session looking for an edit that is not there.

  The two other ways to a worktree are turned back. `EnterWorktree`, which a
  stream-json session carries, and `git worktree add` in Bash are refused with a
  sentence naming the tool, through `ecc-request-refuse-functions`: a
  can_use_tool request whose answer is settled without a person is answered
  before anybody is asked, and the transcript keeps the note. Nothing is refused
  in a session that has not got the tool. In an `auto` permission mode the CLI
  asks Emacs nothing -- it runs `git worktree add` and no can_use_tool arrives
  (measured against CLI 2.1.272, 2026-09-16) -- so a draft that says worktree,
  in English or Japanese, is sent with one line reminding the model of the tool,
  which in that mode is the whole backstop --
  `ecc-prepare-prompt-functions`, which is where a module adds a word of its own
  to a prompt.  Every way a prompt is sent runs it -- the prompt region,
  `ecc-send` and its neighbours, and `ecc-inline-prompt` -- because a line
  that is there to keep the CLI from doing the wrong thing is no backstop if
  it is only on the prompts typed in the prompt region. That line is sent but not written by anybody, so the transcript
  does not draw it inside the user's own band: what a module adds is marked
  with `ecc-aside`, and the renderer parts it from the prompt and shows it
  under the band as a folded heading ("1 line Emacs added") that opens like
  any other. What was sent stays in the buffer -- a sentence in the
  conversation that the user did not write is worth a mark, not a
  disappearance.

  Where a checkout goes is `ecc-worktree-directory`, `.claude/worktrees` by
  default, which is where Claude Code's own worktrees go. A relative name hangs
  off the repository; an absolute one is a directory every repository shares,
  and a checkout lands at `<directory>/<repository>/<branch-slug>`.

  What the repository says about a worktree is read as well -- which repository
  a checkout belongs to, what branch it is on, how far ahead of and behind its
  upstream it is -- and the answers are kept for ten seconds, so that whatever
  asks on every redraw costs no process.

  `ecc-worktree-removed-hook` is run with a worktree that has gone, by every
  way one goes: the command, the offer the last session leaving makes, and the
  one question a group closed together is asked. The sidebar draws a row per
  worktree and nothing about a session says that one has been removed, so that
  is what it redraws from.

- A `Spaces` column in `ecc-menu`, and four keys in `ecc-global-map`: `j` goes
  to a Space, `b` opens the sidebar, `z` zooms the window point is in and `V`
  puts the tab back in order.  They have the lower-case keys because the Spaces
  are where the day is spent; what each of those keys meant before is under
  **Changed**.  Nothing here makes or removes a worktree -- the three commands
  that do are `ecc-worktree-menu`, under `?` then `W`.

### Changed

- The dashboard answers and stops the way the sidebar does, the two being one
  list in two forms. `a` and `d` ask before they answer, where they used to
  answer the row without a word; neither answers a tool of
  `ecc-answer-exclude-tools` -- `Bash` -- which is what `ecc-answer-allow` and
  `ecc-answer-deny` have always skipped wherever they are called from, a shell
  command being something to read where it was asked rather than from a column
  of a table; and `k` asks before it stops a session, which takes its window
  and its transcript with it. What a row may answer is one function now,
  `ecc-answer-session-request`.

- **Breaking.** The Spaces have the lower-case keys of `ecc-global-map` and of
  `ecc-menu`, being where the day is spent: `C-c c j` goes to a Space (it was
  `C-c c J`), `C-c c b` opens the sidebar (it was `C-c c B`), `C-c c z` zooms
  and `C-c c V` puts the tab back in order. `C-c c B` is the dashboard, which
  was `C-c c b` -- the same list as the sidebar, in the form that does not stay
  on the screen.

  `spaces` arrived with its keys beside the older ones rather than instead of
  them, and the result was two vocabularies for one idea: `j` focused a project
  and `J` went to a Space, `w` hid session windows while `z` zoomed a Space,
  `V` put one window back while the tab's whole arrangement had no command at
  all. Seven keys stood in the Spaces column of the menu, three of them
  worktree management.

  Of these, `C-c c b` is the one to watch: both it and `C-c c B` are still
  bound, to commands that both make sense, so a wrong press is silent rather
  than an error.

- `w` in `ecc-menu` rewrites the region (`ecc-rewrite`), which was `W`. `W` is
  the worktree menu now, and `w` was free.

- **Breaking.** The interrupt in a session buffer is `C-c C-z`, comint's key
  for stopping the process, and `C-c C-g` is unbound on purpose. Pressing
  `C-c` and then `C-g` to take the prefix back is the reflex of every other
  mode, where it is harmless; here it stopped the turn. Unbound, the sequence
  falls through to `keyboard-quit`, which is what the finger meant. `C-c c i`
  and `i` in the menu are unchanged.

  `C-c C-k` in the transcript no longer interrupts either: it falls through to
  `ecc-prompt-clear`, so that the key discards the draft wherever point is, as
  `C-c C-c` sends it from wherever point is. One key did two different
  destructive things in one buffer, and which one depended on where point
  happened to be.

- **Breaking.** One letter, one meaning, across the maps and not only within
  one: the keys a buffer spelled differently from `ecc-global-map` and
  `ecc-menu` now spell them the same way.

  In the dashboard `r` resumes and `R` renames, as `C-c c r` and `C-c c R`
  do; they were the other way round. In the transcript `F` goes to the Files
  section (it was `f`), beside `P`, `T` and `L`, which were capitals already;
  `v` goes to the prompt, as `C-c c v` does from anywhere, and `i` stays
  beside it for the finger that starts writing with it. Capabilities are `C`
  in the menu, the key the dashboard already used; it was `y`, which meant
  nothing.

- The choice of layout is `ecc-use-spaces`, a boolean that defaults to `t`,
  where it was `ecc-layout` with the values `classic` and `spaces` defaulting to
  `classic`. A Space per project is what the package is for -- several projects
  at once, each where it was left -- so it is what a fresh install does, and
  `(setq ecc-use-spaces nil)` is the way back to side windows with roles.
  `ecc-layout` is gone rather than deprecated: it never appeared in a release.

- `make compile` compiles each file in an Emacs of its own rather than the
  package in one process, in parallel. In one process a file is compiled with
  whatever an earlier file had loaded, so a macro used above its `defmacro`
  becomes a function call and a variable used above its `defvar` a free
  reference, and the build says nothing: the `.elc` in the tree came out right
  while the one a fresh Emacs builds did not. `ecc-space--quietly` was shipped
  that way and signalled `invalid-function` the first time a Space was closed
  from a second frame; three more files -- `ecc-dispatch.el`,
  `ecc-protocol.el`, `ecc-skill.el` -- would not compile on their own and now
  do. It is not slower: the startups run at once.

- Removing a worktree is offered wherever the last session working in one
  leaves, and not only where a person stopped it by hand.  The offer now hangs
  off the session leaving the model rather than off a handful of commands, and
  is made a moment later from a timer, a session being able to leave from
  inside the process that was running it.  The commands that stop several
  sessions in a row -- `ecc-space-close', `ecc-remove-worktree' -- say nothing
  during the loop and ask for the group themselves afterwards.  Before this a
  worktree whose session went any other way was left on disk with nothing
  running in it.

- `ecc-space-close' offers the worktrees that closed with the Space, in one
  question naming them.  Closing a repository takes its worktrees with it, and
  the directories used to stay behind with no Space and nothing running in
  them; answering no still leaves them where they are.

- A worktree git does not find clean takes a second question before it is
  removed -- the refusal git gives, naming the directory -- and that is now
  the whole of what stands between yes and the removal, the branch never being
  touched.

- The word for the directory is "worktree" everywhere the package speaks:
  questions, messages, docstrings and both documentation sites.  git's own
  noun is "working tree" and "checkout" is its verb; the package used
  "checkout" for the directory in one place and "worktree" in the next, and a
  question that says one thing and a table that says another is one word too
  many.

- `C-c c r` runs `ecc-resume` itself rather than opening `ecc-resume-menu`,
  and `C-u C-c c r` forks the conversation.  Resuming is the commonest thing
  reached from that key and it took two presses -- `C-c c r r` -- with the
  menu in between showing a `-f` switch almost nobody was there for.  The
  menu keeps its form: `r` in `ecc-menu` still opens `ecc-resume-menu`, where
  the fork is a switch seen before it is pressed, which is what a fork is
  worth.  From the key, the prompt says `Fork: ` instead of `Resume: ` when
  the prefix argument is there, so the choice is visible where it is made.
- The Spaces half of the sidebar is laid out the way herdr lays its own out.
  The mark that says what a Space is doing opens the row, the number the
  `1`-`9` keys take follows it in brackets, and a worktree hangs on a tree
  line (`├─`, `└─` on the last one) under the repository it came from rather
  than sitting two spaces in.  A repository with worktrees carries `▾` at the
  right end of its row and `▸` once they are folded away; `TAB` still turns
  it, and so does a click on the arrow.  A folded repository now answers for
  its worktrees as well -- its mark is the loudest of the whole group, which
  is the only thing left to say that one of the folded rows is waiting for an
  answer (herdr's `displayed_workspace_status`).

- `C-c C-c` in a review sends the comments instead of opening a buffer to
  confirm them in.  The comments are the prompt -- each one carries the hunk it
  sits on and the sentence written about it -- so what stood in between was a
  second `C-c C-c` over a text nobody had anything to add to, while the header
  line said `send` and did not send.  `C-u C-c C-c` opens that buffer,
  unchanged, for the times there is something to say about the change as a
  whole, and the header line says which key does which.  `ecc-review-send`
  takes the prefix argument as its optional EDIT.

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
  the most to show. What the working tree held is recorded when the session starts,
  and the review compares the tree as it stands against that. A change is shown
  whatever made it. Resuming keeps the baseline -- it restarts the CLI, not the
  work -- so nothing the session had already done drops out of its own review; a
  session read back from a recording in a fresh Emacs takes its first one then.

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

### Removed

- **Breaking.** `ecc-toggle` and `ecc-toggle-all`, with `C-c c w` and `w` in the
  menu. Hiding a project's session windows and bringing them back was the
  `classic` answer to a frame full of other people's transcripts; under `spaces`
  the windows of a tab are the user's, and what puts a session back on the
  screen is dealing the arrangement again -- `ecc-space-reset-windows` -- or
  going to the session, from the sidebar, the dashboard or `C-c c v`.

  The per-tab record of what was hidden goes with them: the `ecc-hidden-sessions`
  frame parameter and the four functions that kept it, which nothing but
  `ecc-toggle` ever read back. `ecc-window-forget-session` was that record's
  housekeeping and is gone too. The hiding itself stays --
  `ecc-window-hide-on-review` and `ecc-focus-project` both want it -- and the
  docstring of `ecc-window-hide-on-review` says what the way back is now.

- **Breaking.** `ecc-window-focus-source` as a command, with `C-c c V` and `V`
  in the menu. It showed this project's source in the main window because
  nothing else put the code back; `ecc-space-reset-windows` does that and more,
  and has taken the key. What is left is `ecc-window--focus-source`, the half of
  focusing a project that `ecc-focus-project` and the `classic` side of
  `ecc-space-select` are built on.

- **Breaking.** `C-c c j` no longer focuses a project, `C-c c C` no longer makes
  a worktree, and `S` has left `ecc-menu`. `ecc-focus-project` is `M-x` now --
  under `spaces` it only goes to the Space -- worktrees are `C-c c ? W`, and
  switching a window to another session keeps `C-c C-t` in a session buffer,
  which is where it is asked for.

- The offer to delete the branch after a worktree is removed, and with it
  `ecc-worktree-delete-branch' and `ecc-worktree-offer-branch-removal' -- the
  only path in the package that reached `git branch -d', and on a second yes
  `git branch -D'.  A worktree is a directory; the work is on the branch, and
  the branch now always outlives it.  That is what makes an offer arriving on
  its own safe: removing a worktree can lose nothing that was committed.
  Deleting a branch is `git branch -d', by hand, when it is wanted.

- `ecc-worktree-kill-session', which was `ecc-kill' followed by the offer.
  The sidebar, the dashboard and the session tab's close button call `ecc-kill'
  now; the offer follows on its own wherever a session goes.

- `ecc-prompt-resend-last` and its `C-c C-r`, which sent the last prompt
  again after a yes-or-no question.  `C-c C-r` is now
  `ecc-prompt-history-insert`, which puts that same prompt in the region
  where it can be read and edited before `C-c C-c` sends it; `M-p C-c C-c`
  is the two keys that did exactly what the command did.

### Fixed

- What is kept per tab is keyed per tab again on a frame with one tab or
  none -- the zoom of `ecc-space-zoom`, and the list of hidden sessions while
  there was one. The key is the name of the current tab, and that
  name was asked for through `tab-bar--current-tab`, which invents a tab
  named after whatever buffer is showing when the frame has no tabs of its
  own -- so with `tab-bar-mode` on and a single tab the key moved with the
  buffer, and what was stored under it could not be found again. The frame's
  own `tabs` parameter is read instead, and a lone tab
  counts only when it was named on purpose (confirmed on Emacs 32.0.50,
  2026-09-17).

- `ecc-remove-worktree` stops every session working in the checkout, not
  only the ones whose project is the checkout itself. A session started in
  a directory inside it that is a project of its own -- a submodule, a
  repository nested in the tree -- answers `project-current` with that
  directory, so it was in none of the checkout's sessions: the checkout
  was removed from under it and it stayed in the model, a row in the
  sidebar's Sessions list pointing at a directory that is gone. The sessions
  are now those of the project plus any whose own root lies inside the
  checkout; a session of another project that merely ran a command in
  there is still left alone, its cwd being what the CLI reports and not
  where it works. The same set decides whether
  `ecc-worktree-offer-removal` asks at all.

- A notice the CLI wrote itself is no longer drawn as a prompt the user
  typed. A CLI that resumes a session whose previous process left a
  background task behind injects a `<task-notification>` into the
  conversation as a plain `user` message -- no `isMeta`, not a sidechain,
  not the record of a local command -- so the round trip of `t` and `/exit`
  came back with `〉 <task-notification>...` at the head of a turn of its
  own (confirmed 2026-09-17 against CLI 2.1.271 from the terminal and
  2.1.273 from a stream-json client).

  What tells such a message apart is `origin.kind`: `human` for what
  somebody typed, and the name of the injection otherwise. A message whose
  origin is not `human`, or whose text begins `<task-notification>` in a
  recording written before the CLI had the field, is now no prompt
  anywhere -- not in the transcript, nor as a session's last prompt in the
  resume list and the dashboard, nor in the paging index, nor in the
  search. It is kept as a folded system note headed `background task --
  <summary>`, with the notice itself under the fold; it opens no turn, the
  way an unrecognised message does not, since a notice can arrive between
  turns. The live stream agrees: an echoed notification is not taken for a
  prompt from elsewhere.

- A session stays in the directory it was started in. It used to follow the
  cwd the CLI reports on every `system/init`, which the docstring explained
  as a `/cd`. It is not: CLI 2.1.272 reports whatever directory the last
  Bash tool call left it in, so a model that runs `cd somewhere && ...`
  moved the session -- under `spaces`, out of its Space and its tab line,
  into a project nobody started it in, where the sidebar and `C-c c j` could
  not find it and started a second session instead (confirmed 2026-09-16).

  Where a session lives is now the root it was started in, asked by the
  transcript's `default-directory`, by the header line, by the tab line, by
  the Spaces and by a terminal hand-off alike. The only thing that moves it
  is a `/cd <dir>` typed into the prompt region, which moves the root and the
  buffer with it and says where the session went -- or, when the directory is
  not there, that it stayed. The cwd the CLI
  reports is still read, and is what the dashboard's Project tooltip adds
  when the two have come apart.

- A session whose CLI never started is no longer left behind. `make-process`
  fails when the root is not there -- a worktree deleted since the session
  was asked for -- and the session stayed in the list as `starting` with no
  process, in the sidebar and the dashboard, with nothing that would ever
  take it out. It is now said in terms of the session and the directory, and
  forgotten; one that had been running before and is being started again is
  left alone.

- The ediff review is read as code now, and takes the frame it opens in.
  Three things were wrong with how it looked, all reported 2026-09-16.

  It shared the frame with whatever else was on the screen -- under `spaces`
  the sidebar and a transcript or two -- which left each of the two texts too
  narrow to read a line of code in.  It now puts those windows away and hands
  them back when the review is quit (`ecc-review-ediff-full-frame`).

  Nothing was coloured.  The buffers hold many files at once, so no one major
  mode fits them and they were left in `fundamental-mode`; each file is now
  fontified by its own mode as it goes in, and the faces are carried as text
  properties, which is how everything else in this package is coloured.
  Neither were the differences: ediff marks the ones it is not standing on
  with `ediff-odd-diff-A' and its relatives, which the theme this was found on
  paints a shade of the background with no foreground at all.  In the two
  buffers of the review alone those faces are remapped to `diff-removed` and
  `diff-added`, the ones the diff review already reads by, so the colours are
  the theme's own (`ecc-review-ediff-diff-faces`).

  And `q` did nothing.  It is ediff's `ediff-quit`, which asks "Quit this
  Ediff session?" -- a question that goes to a minibuffer the control frame of
  a graphical Emacs does not have, leaving a small frame sitting there that
  looked like a key that had failed.  `q` is the review's own quit now, the
  same as `C-c C-k`: there is nothing to save in a review and nothing to ask.

- A Space whose tab had nothing but transcripts left in it comes up with a
  window for the code again. Under `spaces` the windows of a tab are the
  user's and are left where they were put, which is the point of laying the
  sessions out that way -- but `delete-other-windows` on a transcript leaves a
  tab that is nobody's arrangement, and going to that Space brought back a tab
  with nowhere to read the code and no command to say so (reported
  2026-09-16). A window pointed at another project's file is still left alone:
  that one is the user's doing, and `ecc-space-reset-windows` is the way back.

- A file the CLI wrote in the same second as the last commit, and to the same
  number of bytes, could drop out of the review. The snapshot the review
  compares against copies the repository's index in for its stat cache, and it
  copied it with the time of the copy rather than the time of the index. git
  re-reads a file whose cached stat is no older than the index holding it --
  the case a stat one second wide cannot settle -- and trusts the stat
  otherwise; an index stamped now is newer than every stat in it, so nothing
  was ever re-read and a same-second, same-length change read as no change at
  all. The copy now carries the time of the index it was made from. Measured on
  2026-09-15 (macOS, git 2.x): 7 misses in 900 runs of write-then-snapshot
  before, none in 900 after. It was also what made a test fail about once in
  sixty runs.

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

- A session that is stopped and started again is no longer declared dead by
  the CLI that went. Emacs runs a sentinel when it next waits for output, and
  that is regularly after the next CLI has been started: `/resume`, `ecc-resume`
  and a hand-off taken back all stop one process and start another within the
  same command. The exit of the old one was then taken for the session's own --
  the process was set to nil, the state to `exited`, the pending requests were
  closed and the turn the new CLI had just been given was aborted as "left open
  by the exit". The prompt had gone out, so the answer arrived in a session
  nothing was listening to: the transcript showed a prompt with nothing under
  it, and the session looked stopped while its CLI was running.

  An exit now only closes a session down when it belongs to the process the
  session is running (`ecc-proc--stale-exit-p`); any other is left alone with a
  line in the log. Measured on CLI 2.1.274 by resuming a recorded conversation
  and sending one prompt: 5 of 10 came back with an empty turn before, 0 of 10
  after (2026-09-17). It is what `ecc-test-live-history-resume` had been failing
  on.

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

[Unreleased]: https://github.com/wakamenod/emacs-claude-code/compare/v0.3.2...HEAD
[0.3.2]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.3.2
[0.3.1]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.3.1
[0.3.0]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.3.0
[0.2.0]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.2.0
[0.1.0]: https://github.com/wakamenod/emacs-claude-code/releases/tag/v0.1.0
