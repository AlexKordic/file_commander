# ExplainerKit

MIT-licensed tutorial runtime, image capture adapter, narration compiler, and
offline video player. The Swift package targets macOS 14 or later and has **no
File Commander, Fresh, C++ engine, terminal, or remote Swift package dependency**.
The Python media compiler is portable; capture adapters on other platforms can
write the same JSON/image format.

## Build and try another host

From this repository's root:

```sh
swift build --package-path packages/ExplainerKit --scratch-path build-tutorial-kit
swift test --package-path packages/ExplainerKit --scratch-path build-tutorial-kit
python3 tools/tutorial_media.py record \
  --app build-tutorial-kit/debug/tutorial-example \
  --capture-bin build-tutorial-kit/debug/tutorial-capture \
  --catalog packages/ExplainerKit/Sources/TutorialExample/Lessons \
  --out build-tutorial-media/counter \
  --geometry '{"x":50,"y":50,"pointsWidth":1000,"pointsHeight":650,"scale":2}' \
  --voice Samantha --title 'A tutorial in another application'
```

Recording needs a normal logged-in macOS desktop, Screen Recording permission,
Python 3.11 or newer, FFmpeg with `libx264`, and `ffprobe` on PATH. Generated voice
uses the installed macOS `say` engine; `say -v '?'` lists voices. The example is a
real counter and text-field app with its own anchors, actions, predicates, and
narration. It does not launch the file manager or editor.

The compiler lives in `Sources/ExplainerKit/MediaTools`; `tools/tutorial_media.py`
is only FC's convenience entry point. Copy this package to another project and
use `MediaTools/tutorial_media_cli.py` directly, or use a local Swift package
dependency and `TutorialMediaTools.command` to locate its bundled entry point.
Keep generated output outside the source tree.

## Integrating a host

1. Implement `ExplainerHost` for input, conditions, custom actions, setup, and
   cleanup. Register named controls through `AnchorRegistry` or an
   `AnchorResolver`. Supply JSON lessons and chapter titles.
2. Give each raw action a stable `id`. Add `presentation` metadata to meaningful
   teaching boundaries: `id`, `title`, `narration`, optional `lead_in` and
   `trailing_hold` in seconds. Metadata is separate from the single action in
   each step. `with_presentations` in `authoring.py` can seed authoring metadata;
   review the spoken text before production. Its `speech_transform` callback
   keeps project-specific terminology and pronunciation in the host adapter.
3. In `--record-session CONFIG` mode, create your own disposable profile and demo
   files. Set the window to `configuration.geometry.frame`. Create
   `TutorialCaptureClient`, announce the ready window, wait for the external
   recorder, connect its hooks, run the lesson, and call `finish` before cleanup.
   Use `prepareCaptureWindows` to arrange auxiliary windows inside the agreed
   frame before they enter capture. Normal Watch/Guided runs need no capture client.
4. For intentional relaunch, call `prepareRelaunch` before exit, retain the config
   and lesson progress, then repeat the ready handshake in the replacement
   process. The external helper keeps the clock and inserts a labeled restart
   card. Never target another running application instance.

The protocol is described in [FORMAT.md](FORMAT.md). Swift-specific capture is
isolated in `FrameRecorder.swift` and `TutorialCapture`. Another language can
produce `course.json`, completed takes, PNGs, events and normalized narration
without implementing the Swift runner. The synthetic Python reconstruction test
demonstrates that path.

## Rebuild and qualify media

```sh
python3 tools/tutorial_media.py validate build-tutorial-media/counter
python3 tools/tutorial_media.py build build-tutorial-media/counter
python3 tools/tutorial_media.py qualify build-tutorial-media/counter
python3 tools/tutorial_media.py handoff build-tutorial-media/counter
python3 test/test_tutorial_media.py
```

No host app is required to rebuild. Outputs include `standalone.html`, ordinary
H.264/AAC MP4, VTT/SRT, a poster, timestamped stills, and the smaller hosted `web/`
variant. The HTML embeds its video, captions, poster, data, CSS and JavaScript and
works from `file://` without adjacent files or network access. Chapter buttons
play continuously; step buttons play a bounded interval. Previous/Next select
without playing; replay repeats the current step. Keyboard and native video
controls remain available.

For real browser qualification, install Playwright and its browsers outside the
app, then run:

```sh
node test/test_tutorial_player.cjs build-tutorial-media/counter/standalone.html
```

Use `TUTORIAL_PLAYWRIGHT_PATH` and `PLAYWRIGHT_BROWSERS_PATH` for a private tools
installation. Reports name the actual engine/version; testing Playwright WebKit
does not by itself qualify a particular installed Safari release.
Use `TUTORIAL_CHROME_BIN` to run an actual Chrome for Testing executable. Merge
its browser report with `qualify ROOT --browser-report ROOT/browser-qualification/results.json`.
The report's page checksum must match. Qualification decodes every movie packet,
checks retained-source accounting and PNG integrity, and measures narration
alignment near the start, middle and end. Unchanged qualified media reuses those
measurements when attaching a new browser report. `handoff` whitelists source
assets into a rebuildable archive and copies the HTML/MP4/captions with checksums;
profiles, helper configs and debug logs are excluded.

## Narration and publication

`prepare --language en --voice Samantha --rate 180` renders measured, normalized
PCM clips before capture. `--import-audio FOLDER` instead reads one WAV per
presentation ID, named `ID.wav`. A provider supplies settings/provenance and
renders PCM; its cache identity includes text, language, voice, engine version,
rate, normalization and format. The runner waits for both real actions and
measured speech, then the authored trailing hold. Captions use utterance timing,
not fabricated word alignment. Export requires no microphone or system audio.

FFmpeg is an export/development dependency and is not bundled in the app. Its
build/version is recorded in validation output. Check the chosen speech voice's
applicable publication terms before distributing its audio; the package's MIT
license does not grant rights to third-party voices or footage.

`publication` only prepares a README snippet with supplied URLs. Recording and
building never upload, publish, commit, push, or install anything. README scripts
cannot run on GitHub; put the interactive player on a static page and link its
poster as the first README item after publication.
