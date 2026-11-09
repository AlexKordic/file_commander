# Record a narrated tutorial

Use **Help › Record Tutorial…** in a build containing the tutorial recorder.
Resize the main app window to the frame you want to show. The panel previews its
aspect ratio and reports its size in points and the resulting native video
pixels. For example, 1100×730 points on a 2× display produces 2200×1460 video.
No fixed video width is enforced. Odd pixel dimensions receive one pixel of
padding for H.264.

Choose all lessons, the navigation/copy/editor pilot, or individual lessons. Pick
an appearance, narration voice/language/rate and an output folder, then start.
Keep the recording window at its agreed size and position; changing geometry
invalidates that take with a request to start a new one. Native recording jobs
take turns so their keyboard focus cannot interfere. Avoid using other app
windows while a lesson is capturing. Narration preparation and media builds can
run independently. Recording controls are
outside the captured demo process. Stop preserves diagnostic output.

The exporter requires a normal logged-in macOS desktop with Screen Recording
permission, Python 3.11+, FFmpeg with `libx264`, and `ffprobe` on PATH. Stock voice
narration uses local macOS `say`; list available voices with `say -v '?'`. No
microphone or unrelated system audio is recorded. FFmpeg is not installed or
bundled by FC.

The recording runs real lessons in a separate app process, private FC profile,
disposable demo world and private Fresh editor session. It does not use the
current workspace or editor as a fixture. Demo clipboard lessons replace the
system clipboard with demo paths. Quit/crash lessons target only the owned app;
the external recorder inserts a labeled restart card and continues the same
clock. Interrupted transfers return paused and require the lesson's explicit
Resume action.

## Outputs and local playback

Open **Open Player** when recording finishes, or open `standalone.html` directly.
It embeds video, audio, captions, poster, transcript and controls; copying that
one file to another folder or machine needs no server or neighboring assets.
The ordinary H.264/AAC MP4 is in `render/tutorial.mp4`. The smaller hosted variant
is `web/index.html` with its media beside it.

Chapters sit below the video. Chapter/lesson buttons continue playback from their
start. **Play this step** stops at the selected narrated step's end. **Replay
current step** repeats that bounded interval. **Previous/Next** select and show
the start frame without playing. **Continue automatically** enables continuous
playback. Captions, transcript links, speed controls, native video controls and
stable `#step=ID` / `#chapter=ID` links use the same final timeline. These controls
replay media; they do not execute app commands.

`capture/LESSON/frames/` retains the source PNGs. Names contain elapsed nanoseconds,
UTC, sequence, lesson and action. The manifests and `events.jsonl` retain exact
timing and checksums. Pixel-identical frames become measured holds; changed
frames are retained up to the chosen rate. A bounded write queue fails the take
if storage cannot keep up. Any capture/write failure prevents a successful render.
`render/images.json` maps useful stills to final video time. Source captures and
narration remain available for later editing.

## Command line and reconstruction

From the repository root, with FFmpeg on PATH:

```sh
python3 tools/tutorial_media.py record \
  --app 'build-macos/File Commander.app' \
  --capture-bin 'build-macos/File Commander.app/Contents/MacOS/tutorial-capture' \
  --catalog macos/Sources/FileCommander/Explainers \
  --out build-tutorial-media/my-recording \
  --geometry '{"x":50,"y":50,"pointsWidth":1100,"pointsHeight":730,"scale":2}' \
  --lessons navigate,copy,editor_basics --appearance dark --voice Samantha

python3 tools/tutorial_media.py validate build-tutorial-media/my-recording
python3 tools/tutorial_media.py build build-tutorial-media/my-recording
python3 tools/tutorial_media.py qualify build-tutorial-media/my-recording
python3 tools/tutorial_media.py handoff build-tutorial-media/my-recording
```

Omit `--lessons` for the full course, including both recovery lessons and Markdown
Compose. Use a new output directory, or `--resume` to retain verified completed
takes and retry incomplete ones. Add `--retake find,background_jobs` with `--resume`
to replace specific completed lessons while preserving the full course order.
Previous and failed takes are renamed and retained. Keep the same lesson content
and chosen geometry when resuming. Rebuild
needs only the completed captures and narration, with the file manager closed.
`--silent` omits voice; `--import-audio FOLDER` imports a WAV named `ID.wav` for
each presentation ID. `prepare` can generate narration separately. Speech cache
keys include text, resolved installed voice, language, engine version, rate,
normalization and audio format. Real measured clip durations pace each segment.

## Qualification and reuse

Run `python3 test/test_tutorial_media.py`, the standalone package's `swift test`,
and `node test/test_tutorial_player.cjs PATH/standalone.html` after installing
Playwright in a separate tools directory. Browser qualification copies the HTML
alone to a temporary folder and disables networking. It checks decode, captions,
chapter layout, keyboard operation, race-safe seeking, replay and bounded end
timing. Reports identify actual engine versions. Use `TUTORIAL_CHROME_BIN` to
select Chrome for Testing rather than its headless shell. A WebKit result alone
is not an installed-Safari release test. With existing macOS Accessibility
permission, run the real Safari check without changing its WebDriver or Apple
Events settings:

```sh
python3 test/test_tutorial_safari.py build-tutorial-media/my-recording/standalone.html \
  --out build-tutorial-media/safari-check
```

It adds a read-only observer to an isolated copy, presses actual page controls
through Accessibility, and leaves the local preview open. The original player
code and media stay unchanged. Reports distinguish this observational copy from
the original page checksum.

For manual real capture faults, build the independent package and run:

```sh
python3 test/test_tutorial_capture.py \
  --example build-tutorial-kit/debug/tutorial-example \
  --capture build-tutorial-kit/debug/tutorial-capture \
  --out build-tutorial-media/capture-faults
```

This checks blocked frame output, geometry changes and a real full disposable
APFS image. It never changes the user's privacy permissions. Permission denial
must stop preflight before host launch. Full-course review should check early/late
audio drift, readable text, captions, chapter order, startup memory and file sizes.
`qualify` checks PNG structure/checksums and complete native frame accounting,
decodes every movie packet, and measures early/middle/late audio alignment against
source PCM. Pass `--browser-report ROOT/browser-qualification/results.json` to
attach results for the exact page checksum. Startup time, JavaScript heap and the
sum of owned Chrome process RSS are measured separately; RSS includes shared
pages and is not peak or unique physical memory. `handoff` retains the complete
source capture and narration in `capture-source.tar.gz`, alongside the standalone
HTML, MP4, captions, poster, timeline, validation and checksums. It excludes app
profiles, helper configs and debug logs. Extracted sources rebuild without FC.

Other projects can use the independent MIT package and the same media compiler.
See [`packages/ExplainerKit/README.md`](../packages/ExplainerKit/README.md) and its
language-neutral format. The included counter host and synthetic Python image
fixture demonstrate reuse without FC, Fresh or their dependencies.

## Later GitHub publication

The generated `publication/README-snippet.md` is intended as the literal first
README content, above the project heading. Supply real player/video/poster URLs
using `tutorial_media.py publication ROOT --player-url URL --video-url URL
--poster-url URL` after uploading and checking them. The tool only writes a
snippet; it never uploads, publishes, commits, pushes, or deploys.

GitHub README rendering cannot execute the interactive controls. Host `web/` as
a static page, link its poster first in the README, and provide the offline HTML
as a download. Check current GitHub upload/site limits against measured assets
and test real URL seeking/range requests before choosing the movie location.
Review the final narration and selected voice's publication terms before release.
