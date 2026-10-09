# Plan: native promo overlay

Status: proposal. Nothing here is built yet.

## Goal

A small macOS app, `fc-promo-overlay`, that draws explainer graphics on top of
the terminal while `play.py` drives FC through the storyboard:

- caption cards ("Copy with F5 / The destination is the other panel");
- highlights around the text a scene talks about;
- an animated mouse pointer that glides to its target and clicks;
- key badges for every key the player presses, since key-display apps can't
  see keys the player sends;
- short accents for big moments, such as the crash.

Everything animates with tweens, and the overlay is captured by the same screen
recording as the terminal. No post-production compositing is needed, and the
captions also remain available as `captions.srt` for the video editor.

## How it fits together

```text
storyboard.json ──▶ play.py ──pty──▶ fc (real session, mirrored to the terminal)
                       │
                       └─ JSON lines over a Unix socket
                              ▼
                    fc-promo-overlay  (transparent, click-through window
                                       above the terminal window)
```

`play.py` stays the only timeline. It already emits the events below, so the
overlay is a passive renderer: it never decides what happens next, which keeps
takes reproducible and lets the storyboard work without the overlay.

| Event | Fields | Overlay reaction |
| --- | --- | --- |
| `start` | `cols`, `rows`, `title` | Set the cell grid; reset all layers. |
| `scene` | `id`, `title` | Optional scene title card; clear the highlights. |
| `caption` / `uncaption` | `text`, `sub` | Show, replace or hide the caption card. |
| `highlight` | `rect` (row, col, rows, cols in cells), `style`, `label` | Draw or move the highlight frame. |
| `pointer` | `rect`, `ms`, `click` | Glide the pointer to the rect's centre in `ms`; play the click effect if `click`. |
| `key` / `type` | `label` / `text` | Pop a key badge, or a typing bubble. |
| `launch`, `crash`, `end` | | Fade in, crash accent, fade out. |

`play.py` waits `ms` itself before sending the real click to FC. So the pointer
arrives exactly when FC receives the click, without the two programs talking
back and forth.

### Changes needed in `play.py`

1. Emit `geometry` at start: the terminal's text-area origin and cell size in
   pixels, queried from the terminal (see below).
2. Set a unique window title (`OSC 2`, for example `fc-promo-3f9a`) so the
   overlay can find the terminal window.
3. Emit `clear` at every scene boundary, and `unhighlight` for steps that end a
   highlight early.
4. Optional `--overlay-sync`: after `start`, wait for the overlay's `ready`
   reply, so the first frames aren't recorded without the overlay.

## Placing graphics on terminal cells

The overlay must turn a cell rectangle into screen points. Three methods,
tried in order:

1. **Ask the terminal.** `play.py` sends `CSI 14 t` (text-area size in pixels)
   and `CSI 16 t` (cell size in pixels) to the real terminal and forwards the
   replies in the `geometry` event. iTerm2, kitty and WezTerm answer these;
   Terminal.app's support has to be tested.
2. **Find the window.** The overlay looks up the window with the marker title
   using `CGWindowListCopyWindowInfo` and takes its bounds. Cell size is the
   content size divided by `cols` × `rows`, minus the terminal's padding. Reading
   window titles needs the Screen Recording permission, which a recording
   machine grants anyway.
3. **Calibrate by hand.** `fc-promo-overlay --calibrate` shows a cell grid over
   the terminal. Arrow keys nudge the origin and cell size until the grid lines
   up, and the result is saved per terminal profile.

The overlay re-reads the window bounds about ten times a second, so moving the
terminal window doesn't break the alignment.

## Technology

- **Swift, AppKit and Core Animation**, as a Swift Package (`swift build`, no
  Xcode project). It is macOS-native, GPU-composited and smooth at 60/120 Hz,
  and needs no dependencies.
- **Window**: a borderless `NSPanel` covering the terminal's screen, with
  `isOpaque = false`, a clear background, `ignoresMouseEvents = true`, level
  `.statusBar`, and collection behaviour `.canJoinAllSpaces` and
  `.fullScreenAuxiliary`. The app runs as an accessory, so it has no Dock icon
  and never takes focus from the terminal.
- **Events**: a `DispatchSource`-based Unix socket server at
  `/tmp/fc-promo-overlay.sock`, decoded with `JSONDecoder` into an
  `OverlayEvent` enum and handed to the main thread.

## Tween engine

The overlay needs one small tween layer, about 150 lines:

```swift
struct Tween {
    var keyPath: String          // "position", "opacity", "bounds", "strokeEnd", ...
    var from: Any?, to: Any      // from == nil: start at the current presentation value
    var duration: TimeInterval
    var delay: TimeInterval = 0
    var easing: Easing           // .linear, .outCubic, .inOutCubic, .outBack, .spring(...)
}
// Timeline.sequence([...]) and Timeline.parallel([...]) compose tweens and
// call a completion handler.
```

- Bézier easings map to `CABasicAnimation` with
  `CAMediaTimingFunction(controlPoints:)`, springs to `CASpringAnimation`, and
  paths (the pointer's arc) to `CAKeyframeAnimation`. Core Animation runs them
  on the render server, so they stay smooth while the app's main thread is busy.
- **Retargeting**: a new event starts its tween from the layer's current
  *presentation* value, so a highlight that moves mid-animation glides instead
  of jumping.
- Durations and easings come from a theme file (`overlay-theme.json`) with
  per-step overrides through the storyboard's `style`, so they can be tuned
  without rebuilding.

## Visual elements

| Element | Look | Motion |
| --- | --- | --- |
| Caption card | Lower third: a frosted card (`NSVisualEffectView`), bold title and lighter subtitle. | Rises 24 pt and fades in (`outBack`, 380 ms); fades out in 200 ms. A replacement crossfades. |
| Highlight | Rounded frame 4 pt outside the cell rectangle, accent colour, soft glow. `spotlight` style dims the rest of the screen. | Frame draws in (`strokeEnd` 0→1, 300 ms) and morphs between targets (`inOutCubic`, 350 ms). |
| Pointer | Vector macOS-style arrow (`CAShapeLayer`) with a shadow. | Follows a slight arc to the target in `ms` (`inOutCubic`); click: presses to 90 % and back, with a ripple ring that expands and fades. |
| Key badges | Rounded key caps ("F5", "Ctrl+B") stacked bottom-right. | Pop in (scale 0.6→1, `outBack`), fade out after 1.2 s; repeated keys stack as "Down ×3". |
| Typing bubble | Shows what `type` steps enter. | Grows with the text, fades after the step. |
| Scene title card | Optional full-screen card between scenes. | Fade in, hold, fade out. |
| Crash accent | Brief red vignette and a "killed" stamp on the `crash` event. | 150 ms flash, 600 ms fade. |

The real mouse cursor stays out of the frame. Screen recorders can hide it
(the macOS recorder's options, OBS's "capture cursor" setting).

## Replay mode

`fc-promo-overlay --replay build-promo/events.jsonl --grid 120x34` replays a
recorded event stream against a plain cell grid, with real timing or faster.
Layouts and animations can then be tuned in seconds, without rebuilding the
world or running FC. Using the `--screens` snapshots from a rehearsal as the
background would make the replay look like the real take; that is optional.

## Project layout

```text
tools/promo/overlay/
  Package.swift
  Sources/PromoOverlay/
    main.swift            app setup, command-line options
    EventSource.swift     socket server and replay reader
    Events.swift          Codable OverlayEvent
    Geometry.swift        cell → point mapping, window tracking, calibration
    Tween.swift           Tween, Easing, Timeline
    Theme.swift           overlay-theme.json
    Layers/               CaptionCard, Highlight, Pointer, KeyBadges, TitleCard, CrashAccent
  Tests/PromoOverlayTests/
    TweenTests.swift      easing values and timeline ordering
    GeometryTests.swift   cell rect → point rect for known cell sizes and insets
```

## Milestones

| # | Deliverable | Rough size |
| --- | --- | --- |
| 1 | Transparent click-through window, socket server, caption card with tweens. Replay mode. | 1 day |
| 2 | Geometry: terminal queries in `play.py`, window tracking, calibration grid. Highlights. | 1–2 days |
| 3 | Pointer with arc motion and click effect, timed to `play.py`'s real clicks. | 0.5 day |
| 4 | Key badges, typing bubble, crash accent, scene title cards. | 1 day |
| 5 | Theme file, polish pass on a full take, README section. | 0.5–1 day |

About 800–1,200 lines of Swift in total.

## Risks and open questions

- **Terminal padding and Retina scaling** differ between terminals. Calibration
  covers the gap; the terminal queries have to be checked in the terminal
  actually used for recording.
- **Full-screen terminals** live in their own Space; the panel's collection
  behaviour should follow them. Test this, or record in a normal window.
- **Linux** would need an X11 or Wayland overlay, a separate project. This plan
  is macOS-only because the recording happens on a Mac.
- **Which terminal** the promo is recorded in decides the font and colours.
  Choose it before tuning the overlay theme.
