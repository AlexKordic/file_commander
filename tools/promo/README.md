# Promo storyboard

Tools for recording a promo video of File Commander (FC). A player drives a real
FC session through a scripted storyboard while you record the terminal with any
screen recorder. Nothing is faked: every key, click, copy and crash happens in
FC itself.

| File | Purpose |
| --- | --- |
| `storyboard.json` | The scenes: what to type, what to wait for, captions, highlights, pointer moves. |
| `make_world.py` | Builds the demo world in `/tmp/fc-promo` (demo files, a separate FC and Fresh profile) and a demo website in `/tmp/fc` on the SSH host. |
| `play.py` | Plays the storyboard in your terminal, or headless for rehearsals. |
| `runpromo.sh` | One command for a take with the overlay: builds and starts the overlay, rebuilds the world, plays, and stops the overlay on exit. |
| `overlay/` | `fc-promo-overlay`, a macOS app that draws captions, highlights, a pointer and key badges over the terminal. |
| `overlay_plan.md` | The design the overlay was built from. |

## Set up once

Build FC first ([building](../../doc/dev/building.md)). Then:

```sh
python3 -m venv build-promo/venv
build-promo/venv/bin/pip install -r tools/promo/requirements.txt
```

`pyte` is a terminal emulator library; the player uses it to read FC's screen.

## Rehearse

Rebuild the world before every run; a run copies files and leaves state behind.

```sh
python3 tools/promo/make_world.py
build-promo/venv/bin/python tools/promo/play.py --headless --speed 3 \
  --skip ssh --screens build-promo/screens
```

A headless run plays in a hidden 120x34 terminal and prints how long each
scene took. `--screens` saves a text screenshot at the end of every scene. If a
step fails, the player names the scene and step and prints the last screen.

## Record

1. Make the terminal at least 120x34 characters. A 16:9 window, an 18-20 pt font
   and Do Not Disturb give the cleanest result.
2. Rebuild the world: `python3 tools/promo/make_world.py`.
3. Start your screen recorder (macOS: `Cmd+Shift+5`), then in that terminal:

```sh
build-promo/venv/bin/python tools/promo/play.py \
  --srt build-promo/captions.srt --events build-promo/events.jsonl
```

Don't type while it plays; the player ignores the keyboard so a stray key
can't derail the take. `Ctrl+\` aborts. The player passes the terminal's own
replies to FC and drops mouse input, so moving the real mouse is harmless,
but move it out of the frame.

`captions.srt` holds every caption with its timing, ready to import into a
video editor. `events.jsonl` records what the overlay draws, for replays.

## Overlay

`fc-promo-overlay` draws the storyboard's explanations on top of the terminal
while `play.py` plays: a lower-third caption card, a glowing frame around what
a caption talks about, a pointer that glides to its target before each click,
key badges for every key pressed, and a stamp when FC is killed. It is a
transparent window over the terminal that clicks pass through, so the screen
recorder captures terminal and overlay together.

### Build

Needs Xcode or the Swift 6 toolchain:

```sh
swift build -c release --package-path tools/promo/overlay
OVERLAY="$(swift build -c release --package-path tools/promo/overlay --show-bin-path)/fc-promo-overlay"
```

### Calibrate once

The overlay must know where the terminal's text starts inside the window. In
iTerm2 the player asks the terminal for the exact cell size; only the origin
depends on the window's title bar and tab bar. Calibrate in the window you
will record in, at the size you will record at:

```sh
"$OVERLAY" > build-promo/overlay.log 2>&1 &    # keep it running for recording too
build-promo/venv/bin/python tools/promo/play.py --pattern --overlay
```

The terminal fills with a pattern of coloured edge cells and the overlay
draws its cell grid on top. Type in the terminal, which keeps the keyboard:
the arrow keys move the grid until its lines sit on the cell edges (Shift
moves 10 pt; `[` `]` and `-` `=` adjust the cell size if needed), Enter saves
and Esc cancels; `Ctrl+\` aborts. The first lines of the pattern say whether
the terminal reported its cell size; inside `screen` or `tmux` the player
wraps the request so it reaches iTerm2 (tmux needs `allow-passthrough on`).

The calibration is saved in
`~/Library/Application Support/fc-promo-overlay/calibration.json`. Calibrate
again after changing the font, the window style or the tab bar.

### Record with the overlay

Start the screen recorder, then in the iTerm2 window you record:

```sh
tools/promo/runpromo.sh
```

It builds the overlay, sets up the venv if needed, starts the overlay,
rebuilds the world, plays the storyboard and stops the overlay however the
run ends (`Ctrl+\` aborts). It calibrates first when there is no calibration
yet, or when given `--calibrate`. Other options go to `play.py`, for example
`--speed 2` or `--skip ssh`. Captions land in `build-promo/captions.srt`.

By hand, with the overlay running, rebuild the world, then:

```sh
build-promo/venv/bin/python tools/promo/play.py --overlay \
  --srt build-promo/captions.srt --events build-promo/events.jsonl
```

The overlay follows the iTerm2 window that is in front when the run starts,
and logs to `build-promo/overlay.log`. Stop it with `kill %1`. To follow a
window that may not be in front, such as one driven from another window,
pass `--window-id N`; `--verbose` logs the ID of the window it follows.

Turn iTerm2's window transparency off for recording (View > Use
Transparency); otherwise windows behind the terminal show through FC.

### Preview without FC

`--replay` plays a recorded `events.jsonl` in a stand-in window, and
`--snapshot` renders one moment to a PNG; both are quick ways to tune the
theme. `--backdrop` draws a `--screens` text screen behind the overlay.

```sh
"$OVERLAY" --replay build-promo/events.jsonl --speed 2
"$OVERLAY" --replay build-promo/events.jsonl --snapshot build-promo/ssh.png --at 25 \
  --backdrop build-promo/screens/03-ssh.txt
```

### Theme

`tools/promo/overlay/theme.json` lists every value with its default: colours,
font sizes, the caption's width and position, durations, how long highlights,
the pointer and badges linger, and the crash text. Copy it, change what you
like (a theme file may list only the values it changes) and pass it with
`--theme FILE`. `"sceneTitles": "chip"` also shows each scene's title briefly.

`"$OVERLAY" --help` lists every option. `--verbose` logs the followed window
and every event, which helps when something is drawn in the wrong place.

## Scenes

| # | Scene | Shows |
| --- | --- | --- |
| 1 | `opening` | Two panels, type-to-filter, select by pattern (`+`), `Ctrl+P` copies the selected paths |
| 2 | `background_copy` | `F5` copy with a progress bar while you keep browsing |
| 3 | `ssh` | Connect SSH from the palette, upload a folder to the server |
| 4 | `editor` | `F4` into Fresh, `F10` back and forth, unsaved text survives |
| 5 | `code` | Paste the copied paths into a JavaScript array, select their common prefix with the mouse, then `Ctrl+D` cursors remove it and `End`/`Home` quote every name |
| 6 | `quick_tour` | Bookmarks, browsing a 7z archive, `F3` find, mouse sorting, single-panel mode |
| 7 | `job_control` | A large copy; pause and resume it in the job list (`F9`) |
| 8 | `crash_recovery` | FC is killed mid-copy, restarts with everything restored, the copy resumes |
| 9 | `closing` | Closing caption |

At real speed the storyboard runs for about two and a half minutes, SSH
included; cut it down to a shorter edit in the video editor.

`Ctrl+P` puts the photo paths on the system clipboard (`pbcopy`), so a run
replaces whatever you had copied. The world's Fresh profile turns off
auto-closing brackets and quotes and auto-indent, so the `code` scene types
every character itself and pasted lines start in the same column.

The world sets `transfer_rate_limit` to 12 MiB/s so that copies run long enough
to see. Change it with `make_world.py --rate`.

### The SSH scene

The SSH scene connects to a real machine: the host alias `dev` from your
`~/.ssh/config`. `make_world.py` writes a small demo website to `/tmp/fc` on that
host, and the scene uploads the local website project next to it.

- The host must accept `ssh dev` without asking for a password or host key, and
  have `python3`. `make_world.py --check-ssh` checks both.
- `--ssh-host` and `--remote-dir` choose another host or directory.
- The remote directory is only ever replaced when the marker
  `/tmp/fc.promo-world` beside it shows that `make_world.py` created it.
- `--no-remote` builds only the local world; then play with `--skip ssh`.

The alias appears on screen (`ssh://dev/tmp/fc`), so pick one you are happy to
show in the video.

## Storyboard format

A storyboard has `terminal` (minimum size), `pace` (default key gap, typing
speed range and random seed, so every take types at the same speed), and
`scenes`. Each scene has an `id`, a `title` and `steps`. Each step does one
thing:

| Step | Effect |
| --- | --- |
| `{"launch": {"args": [...]}}` | Start FC. `{home}` and `{server}` expand to world paths. |
| `{"shell": "fc ."}` | Show a shell prompt and type a command, for the viewer only. |
| `{"keys": ["F5", "Ctrl+A"]}` | Press keys. `gap` overrides the pause between them. |
| `{"type": "*.jpg"}` | Type text at human speed. |
| `{"wait": "regex"}` | Wait until the screen matches. `timeout` defaults to 15 s. `fallback` lists keys to press once before waiting again. |
| `{"wait_gone": "regex"}` | Wait until the screen no longer matches. |
| `{"pause": 1200}` | Hold for the viewer, in milliseconds. |
| `{"caption": "Title", "sub": "Line"}` | Start a caption; it lasts until the next one or `uncaption`. |
| `{"highlight": {"text": "regex"}}` | Mark the matching text for the overlay. |
| `{"point": {...}}`, `{"click": {...}}` | Move the overlay pointer to the matching text; `click` also clicks there in FC. |
| `{"drag": {"text": "/tmp/\\S+/"}}` | Select the matching text with the mouse: press on its first character, drag past its last, release. The overlay pointer follows. `ms` sets the drag time. |
| `{"crash": {"message": "..."}}` | Kill FC with `SIGKILL` and restore the terminal. |
| `{"quit": true}` | Quit FC with `Ctrl+C`. |
| `{"clear": true}`, `{"print": "text"}` | Clear the terminal, or print text, for the viewer only. |

Any step can add `hold` (milliseconds to wait afterwards). Targets for
`highlight`, `point` and `click` take `text` (a regex), and optionally `nth`
(which match, from 0) and `half` (`left` or `right` panel).

Wait for text on screen instead of using fixed pauses wherever FC is doing
work. That keeps takes reliable on slower machines and over SSH.
`play.py --check` validates the storyboard without running it.
