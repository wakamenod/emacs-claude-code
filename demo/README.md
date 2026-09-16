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

macOS only. It needs `ffmpeg`, and the terminal running it needs Screen
Recording permission (System Settings → Privacy & Security → Screen
Recording), or the video is black. The video is cropped to the rectangle
the demo frame is held in, so the rest of the screen — the other Emacs,
a browser — is not in it.

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
| `demo-frame`, `demo-float` | put the frame where the camera is, and in front |
| `demo-fresh-repository`, `demo-write`, `demo-git` | the throwaway project |

Three things it knows, all learned the hard way on 2026-09-16, and all
explained where they are done in `demo.el`:

- **The demo Emacs is not the one in front.** macOS does not let an
  application that is not frontmost raise itself, so without
  `z-group`, and without re-setting it by turning it off and on again,
  the demonstration is recorded behind the Emacs the user is working
  in — which is what happened twice.
- **The frame does not stay where it is put.** Something moves it back
  to the corner it started in some time after a scene rearranges the
  screen, so a timer holds it in place twice a second.
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

The recorder prints the ecc it loaded before it starts — check it is the
checkout you meant. A scene that hangs spoils the seconds it was given
and nothing else; `emacsclient -s ecc-demo -e '(...)'` reaches the demo
Emacs while it runs, and the recorder kills it when it is done.

The mp4s are not committed. `demo/*.mp4` is ignored.
