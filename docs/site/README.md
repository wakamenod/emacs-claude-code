# The ecc documentation site

Astro Starlight, deployed to GitHub Pages by `.github/workflows/docs.yml`.
English is served at the root and Japanese under `/ja/`, following the same
rule as the two READMEs: `README.md` is the source of record and `README.ja.md`
follows it.

This file is the working note. What is written down here was learned the slow
way; read it before changing the site.

## Commands

Run them from the repository root, not from here:

```
make docs-install   # npm ci
make docs-dev       # dev server
make docs-build     # build into docs/site/dist
make docs-preview   # serve the build (search only works here, not in dev)
make docs-clean     # remove the build output
```

These are the only targets in the repository that want Node, and none of them
is a prerequisite of `all` or `clean`: building and testing the Emacs package
must never start needing a JavaScript toolchain. A fresh checkout has no
`node_modules`, so `make docs-install` comes first.

## Where the pages are

```
src/content/docs/
  index.mdx              the English landing page (template: splash)
  start/                 Start here
  reference/             Reference
  ja/                    the same tree, in Japanese
```

Each directory is one sidebar group, declared in `astro.config.mjs`. A group is
an object with a `label`, a `translations: { ja: … }` for the Japanese label,
and `items: [{ autogenerate: { directory: '<dir>' } }]` — the autogenerate goes
**inside** `items`, not beside it. Within a group the order comes from each
page's `sidebar.order` frontmatter.

The Japanese pages are part of the site. The `docs/*.md` files one level up are
gitignored working documents, and are no part of it.

## `base` is not prepended to every link

The site is a GitHub project page, so `site` is the user site and `base` is
`/emacs-claude-code` (leading slash, no trailing one; get that wrong and the
HTML still loads while every asset 404s).

Starlight prepends `base` to sidebar and slug links. It does **not** prepend it
to hero action links in `index.mdx`, nor to a plain Markdown link written in a
page body. Both must carry the base by hand:

```md
[Configuration reference](/emacs-claude-code/reference/configuration/)
[設定リファレンス](/emacs-claude-code/ja/reference/configuration/)
```

Japanese headings make Japanese anchors — `## 最初の設定` becomes
`#最初の設定`, and that is what a link to it must say.

## Writing a page

Plain statements, in the order a reader meets the thing. What the key does,
then the one consequence worth knowing. No sentence about what is worth
knowing, what earns its place, or what the point is; no building to an effect.
One or two sentences a section is usually enough, and a table beats a
paragraph whenever the content is a list.

Say what happens, not how the reader should feel about it. "Shows the
session's window and moves point to the prompt region", not "the way back from
wherever you have wandered to".

A page that documents a group of commands links to the page that covers them
in full rather than explaining twice.

The Japanese page follows the English one and is written once the English has
settled. Until it exists, Starlight serves the English page at the Japanese
URL, so a missing translation is not a broken link.

## Two warnings that are not problems

`make docs-build` prints these every time and exits 0:

```
[WARN] [content] The collection "i18n" does not exist or is empty.
[WARN] [content] Entry docs → 404 was not found.
```

There is no `i18n` collection because the site has no UI string overrides, and
no `404.md` because Starlight's built-in 404 page is fine. Do not chase them.

A page missing from `ja/` is not an error either: Starlight falls back to the
English page at the Japanese URL, so `/ja/start/overview/` exists the moment
`start/overview.md` does. It is a fallback, not a translation — the build
output listing a `/ja/` route proves nothing about whether the Japanese page
was written.

## The pictures

There are two generators, and neither takes a picture by hand.

`scripts/docshots.sh` makes the site's own pictures, into `src/assets`. It
opens a throwaway GUI Emacs in the bottom right corner of the screen — the
rest of the screen stays yours — walks it through a scene and captures the
frame.

What is captured is a rectangle of the screen, not the window, so leave that
corner alone while it runs — a window of your own crossing it lands in the
picture, and a frame that comes up empty stops the animation dead.

Take one scene rather than all of them: taking all runs the real CLI four
times and takes about five minutes, which is five minutes of that corner.

```
SCENES="menu resume" scripts/docshots.sh
```

The scenes are `switch`, `menu`, `capabilities`, `send-region`, `fix-error`,
`inline`, `rewrite`, `at-cursor`, `context`, `image`, `suggestion`,
`sessions`, `prompt`, `handover` and `resume`.

What it knows, and what is worth not learning again:

- **A scene that reads from the minibuffer is scheduled inside Emacs**, as one
  chain of timers (`shot-script`), not driven a keystroke at a time from the
  wrapper. Emacs does not reliably answer the server while a recursive edit is
  running: the same scene worked three times and hung the fourth. Keys are left
  on `unread-command-events` rather than fed with `execute-kbd-macro`, which
  quits there. Every step is behind a 25s timeout, so a scene that does hang
  spoils one picture rather than the run.
- **Anything that asks a question blocks the same way.** `ecc-answer-allow`
  confirms before answering, so the scene that allows an edit uses
  `ecc-perm-allow`, the transcript's own `a`.
- **The frame is asked where it is again before every picture**: the menu
  resizes it, and a frame that would grow past the bottom of the screen is
  moved. The title bar is left out of the rectangle, because macOS writes the
  new size into it when a frame is resized and nothing in Emacs clears that.
  The echo area is cleared before a still, or an early one carries Emacs's own
  greeting.
- **A scene runs to the end.** A permission left waiting goes on blinking, and
  every picture taken after it has a blinking corner.
- **The demo layout is made with ecc's own window commands**, not with
  `split-window-right`: a session window carries a role, and the commands that
  move a session between windows look for it. `ecc--enable-session-modes` is
  called too, or the pictures have no tab line — which every real session has.
- **The scenes that need an answer run the real CLI**, with `--model haiku` and
  a budget. The hand-off one needs a conversation the CLI can `--resume`
  (recorded into `/tmp/greet` on the first run and kept), the demo folder
  trusted in `~/.claude.json`, and every `CLAUDE*` variable unset before
  anything starts — macOS `open` passes the environment on, and
  `CLAUDE_CODE_CHILD_SESSION` puts "Transcript saving is off" across the top of
  the picture.
- **The picture the image scene asks about is a chart**, kept beside the
  script in `scripts/docshots-image.png`. It was a screenshot of Emacs first,
  and a screenshot of Emacs inside a screenshot of Emacs reads as nothing: the
  model answers about the thing the reader is already looking at. An image is
  sent by path, so the file is opened in the window beside the session too, or
  the scene is one line of text appearing in the prompt region.
- **Do not put a real session's capabilities in a picture.** They are the
  skills, agents and plugins of whoever runs this. The capabilities scene
  replays a fixture, which carries a recorded one.
- **Hold each state for one or two frames, and keep changing.** Repeated frames
  are merged into one long frame when Astro converts the animation, and a scene
  held four ways becomes a slideshow that reads as a still.

`docs/images/session.gif` and `session.png`, the ones README.md carries, are
generated by `scripts/screenshot.sh`, not taken by hand. It opens a throwaway GUI Emacs,
replays recorded fixtures through the real dispatch and renderer, and drives
the frame through `emacsclient` one step at a time, capturing a frame after
each. No CLI, no network, and the same output every time.

It is macOS only. It needs `ffmpeg`, and the terminal running it needs Screen
Recording permission (System Settings → Privacy & Security → Screen Recording);
without that, `screencapture` says "could not create image from display" and
the frames come out empty.

Those two live outside the Astro project, so the site does not reference them.
The site's own pictures are in `src/assets` and are linked from a page with a
relative path (`../../../assets/menu.png`). Astro rewrites them: a PNG becomes
a `webp` under `_astro/` with the base already in the URL, and an animated GIF
becomes an animated webp -- check for `ANMF` chunks in the output if an
animation ever looks still.
