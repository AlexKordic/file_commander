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
| `overlay_plan.md` | Plan for a native app that draws captions, highlights and a pointer on top of the recording. |

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
video editor. `events.jsonl` is the stream the overlay app will draw from.

## Scenes

| # | Scene | Shows |
| --- | --- | --- |
| 1 | `opening` | Two panels, type-to-filter, select by pattern (`+`) |
| 2 | `background_copy` | `F5` copy with a progress bar while you keep browsing |
| 3 | `ssh` | Connect SSH from the palette, upload a folder to the server |
| 4 | `editor` | `F4` into Fresh, `F10` back and forth, unsaved text survives |
| 5 | `quick_tour` | Bookmarks, browsing a 7z archive, `F3` find, mouse sorting, single-panel mode |
| 6 | `job_control` | A large copy; pause and resume it in the job list (`F9`) |
| 7 | `crash_recovery` | FC is killed mid-copy, restarts with everything restored, the copy resumes |
| 8 | `closing` | Closing caption |

At real speed the storyboard runs for about two minutes without the SSH
scene; cut it down to a shorter edit in the video editor.

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
| `{"crash": {"message": "..."}}` | Kill FC with `SIGKILL` and restore the terminal. |
| `{"quit": true}` | Quit FC with `Ctrl+C`. |
| `{"clear": true}`, `{"print": "text"}` | Clear the terminal, or print text, for the viewer only. |

Any step can add `hold` (milliseconds to wait afterwards). Targets for
`highlight`, `point` and `click` take `text` (a regex), and optionally `nth`
(which match, from 0) and `half` (`left` or `right` panel).

Wait for text on screen instead of using fixed pauses wherever FC is doing
work. That keeps takes reliable on slower machines and over SSH.
`play.py --check` validates the storyboard without running it.
