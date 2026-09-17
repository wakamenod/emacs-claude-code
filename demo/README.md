# demo/ — showing a change working, on camera

`demo/record.sh <scene>` opens a second GUI Emacs, loads
`~/.emacs.d/init.el` into it, puts **this checkout** in front of whatever
ecc that init points at, plays a scene and records it as an mp4. It is
how a branch is checked by eye when a batch test cannot see what is being
changed — a frame, a panel, a colour, a key — and how that check is
handed to somebody else.

It is not how the documentation's pictures are made. Those are
`scripts/docshots.sh` and `scripts/screenshot.sh`, which dress a
throwaway `-Q` Emacs up and replay recorded fixtures. A demo runs the
real configuration, warts and all, because that is the point of it.

```
demo/record.sh review-ediff-help            # -> demo/review-ediff-help.mp4
demo/record.sh review-ediff-help /tmp/x.mp4
```

macOS only. What is recorded is the demo frame's **own window**, through
ScreenCaptureKit (`record-window.swift`, built into `.build/` on the
first run; `swiftc` comes with the command line tools). Nothing that
covers the window is in the picture, the window does not have to be in
front, and you can carry on working on the same screen while it records.
A window that is *minimised* is not drawn and cannot be recorded; one
that is covered, on another Space or half off the edge can.

Whatever runs it needs Screen Recording permission (System Settings →
Privacy & Security → Screen Recording), or there is nothing to record.

**The Mac has to stay unlocked.** A window that is not being drawn hands
no frames over, so a display asleep or a session locked records nothing
— not a black video, nothing at all, and the demo Emacs stalls on its
own redisplay too. `record.sh` holds the display awake with `caffeinate`
for as long as it runs; a lock it cannot do anything about, and the
recorder says so and writes no file rather than leaving an mp4 that will
not open.

Everything a run owns — the server socket, the ready file, the frame
title the recorder looks for — is named after the scene, so **two scenes
can record at once**, from two checkouts and two sessions. They could
not before: each run killed every `demo/demo.el` on the machine at
startup and at exit, and all three recordings of 2026-09-17 destroyed
each other.

## A scene with more than one frame

Only the demo frame is recorded, so anything a scene puts in a **frame
of its own** is not in the picture. The one this affects is
`review-ediff-help`: on a graphical Emacs the ediff control panel is a
frame, and `demo-place-panel` used to put it above the demo frame where
the screen crop would catch it. A scene that wants a panel on camera
should keep it inside the frame instead — for ediff, that is
`(setq ediff-window-setup-function #'ediff-setup-windows-plain)` in
`demo-scene-build`, which makes the panel a window like any other.

## Writing a scene

A scene is two files:

- `scenes/NAME.el` — loaded into the demo Emacs. It defines
  `demo-scene-build`, which builds whatever the scene is of (there is a
  throwaway git repository at `demo-root` and `demo-fresh-repository`,
  `demo-write` and `demo-git` to fill it), and one function per step.
- `scenes/NAME.sh` — sourced by the recorder. It is the order of the
  steps and how long each is held, written with `say "..."` for a caption
  in the echo area and `e "(a-form)"` for a step.

`demo.el` is what both sit on. What it gives a scene:

| | |
|---|---|
| `demo-say` | a caption in the echo area |
| `demo-run-key-in BUFFER KEY [TEXT] [PREFIX]` | run what KEY is bound to in BUFFER |
| `demo-say-key-in BUFFER KEY` | say what KEY runs there |
| `demo-frame` | give the frame the size the video is taken at |
| `demo-float` | nothing, now; kept so older scenes still run |
| `demo-fresh-repository`, `demo-write`, `demo-git` | the throwaway project |

Two things it knows, learned the hard way on 2026-09-16, and both
explained where they are done in `demo.el`:

- **The frame does not stay the size it was given.** Something moves it
  back to the corner it started in some time after a scene rearranges
  the screen, so a timer puts it back twice a second. Where it sits does
  not matter any more — the window is recorded where it stands — but the
  size is the shape of the video.
- **Keys are not fed to the command loop.** `scripts/docshots.el` leaves
  them on `unread-command-events`, which works when that Emacs has the
  keyboard; here the frame Emacs selects is not the frame the keyboard
  goes to, and a `?` meant for an ediff control panel went into the
  review buffer and was answered with "Buffer is read-only". A step
  looks the key up in the buffer it belongs to and calls what is bound
  there, which is the same command through the same keymap. Text for a
  command that reads the minibuffer goes on `unread-command-events`
  just before that call, and the whole thing is scheduled on a timer:
  Emacs does not answer the server while a minibuffer is open.

## Watching it go wrong

`demo/.build/record-window --title "ecc demo: NAME" --shot /tmp/x.png`
takes one picture of the frame, which is how a run that has stopped is
looked at — including one whose Emacs is stuck at a prompt nobody can
see. It cannot be done **while the scene is recording**: a second
capture of one window interrupts the first, and the recording ends
there.

A step arrives from `emacsclient` with whatever buffer is current, which
is `*scratch*` until a scene opens a file. A buffer with no directory
behind it leaves `ecc-window-context-project-root` on
`default-directory` — the checkout the demo Emacs was started from,
which is **the real repository**. `demo.el` points that at `demo-root`
now, and a scene that asks for a worktree should check the root it
resolved before it lets git near it: a scene that asked for a worktree
cut two of them in the actual repository before anybody noticed
(2026-09-17).

The recorder prints the ecc it loaded before it starts — check it is the
checkout you meant. A scene that hangs spoils the seconds it was given
and nothing else; `emacsclient -s ecc-demo-<checkout>-<scene> -e '(...)'`
reaches the demo Emacs while it runs — everything a run owns is named
after the checkout and the scene, so two worktrees can record at the same
time — and the recorder kills it when it is done.

The mp4s are not committed. `demo/*.mp4` is ignored.
