# Tutorial recording, narration, and HTML playback

Status: implemented and locally qualified. GitHub publication is the later user
stage below. Created 2026-11-09.

Implemented tooling is described in [tutorial recording](../doc/tutorial_recording.md)
and the independent [ExplainerKit package](../packages/ExplainerKit/README.md).
Generated evidence stays under ignored `build-tutorial-media/`. Publication is a
later user action; this work creates no commits or pushes.

## Intended result

Turn the app's lessons into a narrated video assembled from timestamped images,
with a standalone HTML page that embeds the video and provides chapters and
step playback below it. The user resizes the app before recording to choose the
video's dimensions. The finished recording can later become the first item in
the GitHub README.

The completed implementation must produce a working local recording and player
before publication. This document does not authorize publishing. The repository's
[agent rules](../AGENTS.md) prohibit agent commits and pushes; all implementation
changes remain uncommitted and unpushed.

## Existing implementation to extend

| Existing part | Reuse | Change needed |
| --- | --- | --- |
| [Lesson JSON](../macos/Sources/FileCommander/Explainers) | The 28 lessons, seven chapters, captions, actions, waits, and command references | Stable step identities, narration text, and authored presentation boundaries |
| [ExplainerRunner](../macos/Sources/ExplainerKit/Runner.swift) | Action execution, state checks, pause, skip, and Watch/Guided behavior | Structured start/end events and a shared recording clock |
| [TutorialCoordinator](../macos/Sources/FileCommander/Tutorial/TutorialCoordinator.swift) | Demo world, tutorial tabs, isolated editor, setup, cleanup, and relaunch | Recording-session orchestration and narration-aware pacing |
| [Anchors and overlays](../macos/Sources/ExplainerKit/Anchors.swift) | Named controls, highlights, pointer, and keyboard badges | Stable capture framing; exclude recording controls from the image |
| [ExplainerRecorder](../macos/Sources/ExplainerKit/Recorder.swift) | ScreenCaptureKit capture, image writing, captions, and preview generation | Retained image sequence, capture timestamps, explicit geometry, and reliable errors |
| [TutorialExport](../macos/Sources/FileCommander/Tutorial/TutorialExport.swift) | Export entry point and per-lesson iteration | Remove forced 1280×800 window sizing; assemble video from images; generate HTML |

The current exporter records MP4 directly and schedules a PNG about 700 ms after
each new caption. Those images have sequence names such as `01-light.png`.
It does not save the complete image timeline, generate narration, or provide an
interactive HTML player. It currently excludes the two lessons that restart FC.

ExplainerKit already has no FC target dependency, but it lives in FC's Swift
package and imports macOS frameworks. Preserve this useful separation while
making the media pipeline usable without building the file manager.

## Deliverables and output contract

Use an ignored output directory such as `build-tutorial-media/<run-id>/`.
Keep source lesson metadata and player templates small enough for normal source
control; generated images, speech, movies, and large embedded HTML stay outside
the source tree by default.

```text
build-tutorial-media/<run-id>/
  capture/
    frames/*.png           # Retained source images with timestamps in their names
    events.jsonl           # Incremental capture and lesson events
    manifest.json          # Dimensions, clocks, frame identities, failures, provenance
  narration/
    script.json            # Authored text, voice settings, pronunciation, cue identities
    clips/*.wav            # Cached per-segment speech or imported recordings
  render/
    timeline.json          # Final chapter/lesson/step/audio/frame time mapping
    tutorial.mp4           # Video assembled from the retained images, with narration
    captions.vtt
    captions.srt
    poster.png
  standalone.html          # Self-contained deliverable with embedded video and player
  web/
    index.html             # Smaller hosting variant of the same player
    tutorial.mp4
    captions.vtt
    poster.png
  validation.json
  publication/README-snippet.md
```

Interpret “standalone HTML” strictly: `standalone.html` must open locally with
the network disabled and need no server, CDN, adjacent assets, or installed app.
Embed the muxed MP4, poster, chapter/step data, transcript, CSS, and JavaScript;
construct media and caption Blob URLs locally. Test captions under `file://`.
Also retain the ordinary MP4 and generate the external-media `web/` variant for
efficient hosting. Embedded binary data increases file size and startup memory,
so measure these separately on the full course, not only a short sample.

Every final chapter and step boundary comes from `render/timeline.json`. Video,
subtitles, image links, transcript, and HTML navigation must use this same data.

## Recording experience and resolution

1. Add **Record Tutorial…** alongside the existing tutorial entry points. Select
   one lesson, selected lessons, or the full course, plus appearance and narration.
2. Show a framing preview while the user resizes the app normally. Display both
   the window size in points and the resulting video size in physical pixels.
3. Default to the current complete app window, including its title bar, at native
   pixel resolution. For example, 1000×625 points at 2× produces 2000×1250 pixels.
   An explicit scale option may produce smaller output; never resize silently.
4. Freeze the agreed capture rectangle and output dimensions when recording
   starts. Report any one-pixel padding needed for even H.264 dimensions. Keep
   layout, text, images, and captions at their intended proportions.
5. If the window is resized, moved across displays with a different scale, or
   leaves the capture area mid-take, pause and require a new take or an explicit
   return to the original geometry. One movie has one resolution.
6. Include the app's sheets, tutorial annotations, menus, and relevant auxiliary
   windows inside the selected frame. Position Activity/Errors/Find windows
   within that frame when a lesson needs them. Keep the recording control panel
   outside the captured content. Avoid desktop notifications and unrelated apps.

ScreenCaptureKit separates the source rectangle from output dimensions; preserve
that distinction in the API and metadata. See Apple's
[capture configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
and [source rectangle](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)
documentation. Recording preflight checks Screen Recording permission, available
storage, output writability, installed voices, and the encoder before playback.

## Timestamped images and the recording clock

Use one capture stream, rather than repeatedly creating screenshot sessions.
Retain complete frames up to a default 30 fps so typing, scrolling, highlights,
pointer motion, and progress indicators survive reconstruction. Coalesce truly
identical frames into holds; always retain boundary/post-condition images.

An example source image name is:

```text
frame_000000012345678901ns_20261109T163012345678Z_f000184_l-copy_s-confirm.png
```

- The first field is zero-padded elapsed presentation time in nanoseconds from
  the take's origin; this example represents 12.345678901 seconds.
- The second is the UTC capture instant in a filename-safe format.
- The frame sequence breaks timestamp ties; lesson and step IDs aid inspection.
- Use capture sample timestamps, not PNG-write completion time or filesystem
  modification time. Record the mapping between sample time and the shared host
  monotonic clock. UTC is descriptive; clock corrections cannot reorder frames.
- The manifest records the exact rational timestamp, duration, dimensions,
  sequence, step ownership, relative path, and image checksum. It is authoritative
  for assembly; do not reconstruct the timeline from rounded filenames alone.
- A final image gallery uses final video-time filenames/links after lesson
  concatenation or editing. Preserve source names and an explicit source-to-final
  mapping so retiming never makes a screenshot's time label misleading.

Start lesson actions only after capture has delivered its first valid image.
Use the same monotonic origin for action events, captures, narration cues, and
overlays. Preserve both `stepStarted` and `stepCompleted`: the current runner's
single after-step callback is insufficient for accurate boundaries.

PNG compression and writing run on bounded worker queues. Drain and await every
accepted frame before closing a take. Do not silently ignore failed screenshots,
disk-full errors, or unfinished tasks. Sustained capture/write overload invalidates
the take with a clear diagnostic, rather than presenting it as a successful video.
Record source frame gaps and distinguish static holds from missing changed frames.

## Narration and pacing

Author spoken explanations for meaningful visual steps. Use existing captions as
a starting draft, but write natural sentences instead of reading every key event
or implementation detail aloud. Keep narration text and display captions separate
while linking them through stable segment IDs.

Default to English for the initial pilot, with language, stock voice, rate, and
pronunciations configurable. Start with local macOS speech synthesis, which can
write generated audio buffers using
[AVSpeechSynthesizer.write](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)).
Keep a provider interface so another TTS engine or imported human recordings can
replace it without changing lessons or the player. Store voice/provider provenance
and any required attribution alongside the outputs. Confirm the selected voice's
publication terms before releasing its generated audio.

1. Draft and review narration for a short navigation/copy/editor pilot.
2. Render each segment to a separate PCM audio file and measure its real duration.
   Cache by text, language, voice, rate, provider version, and audio format.
3. Add an export pacing profile. A segment advances only when its real actions
   and narration have finished, plus its authored reading/settling allowance.
   A useful rule is `segment end = max(action completion, speech completion)
   + trailing hold`, with explicit speech lead-in where appropriate.
4. Extend stable visual holds when speech needs longer. Shorten unnecessary waits
   where state checks permit it. Never speed up actual file operations or trim
   speech to make an old duration estimate fit. Timeout failures remain failures.
5. Keep normal Watch/Guided behavior usable. Prefer export-specific timing
   metadata; update shared lesson holds when the change also improves teaching.
6. Produce a normalized narration track, with deliberate pauses between topics,
   and mux it into the MP4. Generate readable subtitle cues and the transcript
   from the approved narration and measured final timing. Do not invent word-level
   alignment when the provider only supplies utterance-level timing.

Narration preparation precedes the final capture, so the app can wait in the
correct visible state while speech finishes. No microphone or unrelated system
audio is needed for the generated-narration route. Browser playback speed changes
video and its muxed narration together.

## Video assembly from the images

Build the final video from saved PNGs and the manifest, rather than making a
direct screen-recorded MP4 the only source of truth. The images remain useful for
inspection, documentation, and later narration edits.

- Define explicit frame intervals. Carry identical pictures forward for their
  measured duration, including the last frame's final hold. Reject unexplained
  negative durations, missing images, or unexplained timing gaps.
- Assemble with FFmpeg, using an explicit image/duration timeline or equivalent
  timestamp-aware input. Do not feed an irregular image sequence to a fixed input
  rate and accidentally change its speed. The
  [concat demuxer](https://ffmpeg.org/ffmpeg-all.html#concat) supports explicit
  durations; handle the final image's duration explicitly.
- Produce a browser-tested H.264/AAC MP4, with the chosen dimensions, a compatible
  pixel format, and streaming-friendly metadata. A 30 fps delivery file may repeat
  static images without storing duplicate source PNGs. Keep audio timing on its
  sample clock and round video boundaries consistently to presentation frames.
- Preserve readable application text. Qualify size and quality on a real lesson
  before encoding the full course. Make resolution, frame rate, and quality
  explicit rather than reducing resolution silently to meet an upload target.
- Concatenate lessons using their measured durations; derive chapters and step
  offsets after assembly. Re-encode or normalize inputs where stream settings
  differ, and measure the resulting file rather than trusting duration estimates.
- Permit rebuilding video, captions, and HTML from a completed capture directory
  without launching FC or repeating file operations.

Use FFmpeg as a development/export dependency, with version and build information
recorded. Do not add it to the installed FC app or redistribute an encoder build
without reviewing its applicable distribution requirements.

## HTML player and step controls

The video is the first element of the generated page. Put chapter navigation
immediately below it, grouped as **chapter → lesson → presentation step**. Include
titles, start times, durations, and a current-position indicator.

Presentation steps group related low-level actions into useful explanations, such
as “Choose files” or “Resume the transfer.” Keep every underlying runner action
indexed for diagnosis; do not force viewers to navigate separate caption, key,
and wait events as hundreds of unlabeled chapters.

| Control | Required behavior |
| --- | --- |
| Play tutorial | Continuous playback from the current location |
| Chapter or lesson | Seek to its start and continue playback |
| Play this step | Seek to that step's start, play its complete narrated interval, then pause at its end |
| Replay current step | Restart the selected/current step without continuing into the next one |
| Previous / Next | Select the neighboring step and show its start frame; the play button starts it |
| Continue automatically | Explicit toggle between bounded step playback and continuous playback |
| Pause / Resume | Native video controls and an accessible page control |
| Captions / transcript | Toggle captions; select transcript text to seek to the corresponding interval |

Mirror the useful behavior of the in-app tutorial controls, including showing a
step on demand. The HTML button replays recorded media; it does not rerun file
operations. The app currently has pause/skip/Show Me support, not a general safe
rewind of arbitrary state-changing actions.

Wait for metadata and seek completion before starting bounded playback. Use video
frame callbacks where supported to watch the presented media time, with a tested
fallback and a boundary guard, rather than relying only on coarse `timeupdate`
events. Cancel stale callbacks when the user seeks or selects another step.
[MDN documents the frame callback and its timing limitations](https://developer.mozilla.org/en-US/docs/Web/API/HTMLVideoElement/requestVideoFrameCallback).
Do not promise sample-exact browser pausing; measure end-boundary behavior.

Add stable fragment links for chapters and steps, keyboard-operable buttons,
visible focus, responsive layout, and accessible current-step announcements.
Playback begins on a user gesture. Escape lesson text safely when embedding JSON
or HTML. The standalone page must make zero network requests and work in Safari,
Chrome, and Firefox; the hosted variant uses the same controls and timeline.

## All lessons, including quit and crash recovery

The first vertical slice records navigation, a background copy, and native editor
interaction. Expand to all 28 lessons after it passes capture, narration, and
player checks. Inventory captions and add narration/presentation boundaries to
each lesson, including a narrated view of rich Markdown Compose as a subsequent
content addition where the current editor lessons lack it.

For **Quit and come back** and **Crash recovery**, move take ownership to a small
external recording supervisor. It survives FC's exit, keeps the session clock,
records relaunch boundaries, and reconnects capture to the new process. Preserve
the selected frame and dimensions across relaunch. If a gap needs a transition,
render a clearly labeled card into the image sequence and account for its time.
Do not silently omit these lessons from an “entire tutorial” result.

Use a disposable FC profile, demo world, and tutorial editor session for production
recordings, separate from the user's normal app session. The crash lesson targets
only that owned FC process. Preserve its teaching point: interrupted transfers
start paused and continue only after an explicit Resume action.

## Reuse in other projects

Keep the FC adapter small and move general recording/publication responsibilities
behind stable interfaces. Start within this repository; a separate public package
or repository is not required to prove reuse.

| Reusable component | Contract | FC-specific responsibility |
| --- | --- | --- |
| Lesson model and runner | Versioned lessons, step events, state predicates, narration boundaries | FC commands, file/job conditions, key labels |
| Host adapter | Window, anchors, input, preparation, cleanup, completion/failure | Demo files, tabs, Fresh, remote stand-in, restart handling |
| Capture adapter | Timestamped image frames plus geometry and lifecycle events | Selection and arrangement of FC windows |
| Narration provider | Text/settings in; audio, measured duration, and provenance out | FC terminology and pronunciation overrides |
| Media compiler | Versioned capture manifest and assets in; video/timeline/captions out | Course title, chapter order, branding |
| HTML publisher | Video, final timeline, transcript, and poster in; standalone/web outputs | Project name, logo, and publication URLs |

Keep AppKit/ScreenCaptureKit in the macOS adapter. Use a language-neutral JSON
manifest so web, Linux, or Windows tutorial runners can later feed the same media
compiler and HTML player through their own capture adapters. Extract a small
independent package for the reusable Swift parts so a second macOS host does not
need FC's C++ engine, Fresh, SwiftTerm, or their build flags. Preserve ExplainerKit's
existing public facade where practical.

Prove the boundary with a tiny second host, such as a counter/text-field app with
its own three-step lesson, anchors, and predicates. It must generate a narrated
video and the same standalone player without importing FCKit or FreshKit. Also
feed a synthetic non-Swift capture manifest through the compiler to test the
language-neutral contract. Keep reusable original tooling under FC's MIT terms;
preserve dependency licenses separately.

## Implementation order and completion gates

### 1. Timeline contract and pilot content

- [x] Add a versioned capture/final-timeline schema and stable IDs for chapters,
  lessons, raw actions, and presentation steps.
- [x] Extend lesson decoding and the checker for any new metadata keys. Preserve
  the existing rule that each JSON action object has exactly one action.
- [x] Draft narration for navigation, copy, and editor pilot segments.
- [x] Confirm naming, resolution preview, and the intended step playback behavior
  through a local sample artifact before extending the whole course.

### 2. Recording controls, clock, and image capture

- [x] Add the current-window sizing mode and an accurate pixel preview.
- [x] Add runner start/end events, one shared clock, and a journaled manifest.
- [x] Save timestamped PNGs through a bounded queue; capture annotations and
  auxiliary windows; drain writes and report failures.
- [x] Verify text clarity, Retina scale, static holds, pointer motion, and resizing
  behavior in the pilot at two user-selected resolutions.

### 3. Narration and deterministic media build

- [x] Implement local speech generation plus imported-audio/provider interfaces.
- [x] Measure/cache clips and add narration-aware export pacing.
- [x] Build the pilot MP4 solely from its images and measured timing; add narration,
  subtitles, poster, and final timeline.
- [x] Rebuild successfully from saved artifacts without launching FC.

### 4. Standalone HTML player

- [x] Generate embedded-media `standalone.html` and the external-media web variant.
- [x] Implement chapter/lesson jumps, Play this step, replay, previous/next,
  continuous mode, captions, transcript, and fragment links.
- [x] Test offline `file://` playback, keyboard navigation, seeking, and bounded
  step playback in Safari, Chrome, and Firefox.

### 5. Full course and reusable-host qualification

- [x] Author and record every existing lesson; add needed explanations for new
  editor presentation features without claiming them covered by old lessons.
- [x] Support both recovery lessons with the external supervisor.
- [x] Prove second-host and non-Swift-manifest reuse.
- [x] Qualify the complete standalone file for startup time, memory, output size,
  audio consistency, readable text, and correct chapter offsets.
- [x] Produce a local handoff containing the standalone page, MP4, frame archive,
  captions, source narration, final manifest, and validation report.

### 6. GitHub presentation, as a later publishing step

GitHub sanitizes README HTML and removes scripts, so the interactive chapter and
step player belongs on its standalone page. See
[GitHub's rendering pipeline](https://github.com/github/markup/blob/master/README.md).
GitHub Pages can serve the HTML/CSS/JavaScript version; see
[What is GitHub Pages?](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages).

- [x] Prepare a README snippet with the tutorial as the literal first content,
  above the project heading: a clickable poster linked to the HTML player.
- [ ] Add the supported GitHub video presentation after an actual upload test.
- [x] Preserve the poster/player link as the reliable entry point. Custom chapter
  controls cannot execute inside the repository README itself.
- [ ] Select GitHub Pages for the player and evaluate the measured MP4 size before
  choosing Pages, an attachment, or a release asset for the movie. Check seek/range
  behavior and cross-origin caption/media access on the selected real URL.
- [ ] Recheck publication limits at that time. Currently, GitHub's attachment docs
  distinguish 10 MB free-plan video uploads and 100 MB paid-plan uploads; Pages
  documents a 1 GB published-site limit and soft bandwidth quotas. A full narrated
  course may need a different movie location or a shorter optional README preview.
  Sources: [attachments](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files),
  [Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits).
- [ ] Generate the final README snippet and publication instructions with actual
  URLs, checksums, sizes, and a downloadable standalone HTML asset.
- [x] The user performs commits, pushes, uploads, and deployment. Tooling must
  not publish as a side effect of recording or rendering.

## Local qualification result

Generated outputs are ignored and remain local under `build-tutorial-media/`.
The completed deliverable is `fc-course/handoff/standalone.html`, with the ordinary
MP4, captions, poster, timeline, validation, checksums and source archive beside it.
`fc-course/publication/README-snippet.md` is ready for verified publication URLs.

| Check | Result |
| --- | --- |
| Full course | All 28 original lessons plus Markdown Compose: 29 lessons, 167 narrated steps, 15:20 at 2200×1460 |
| Retained images | 11,909 timestamped PNGs; exact capture/event clocks and final-time mapping preserved |
| Frame accounting | 25,665 accepted samples: 13,952 identical coalesced and 11,713 retained source images, plus 196 boundary/transition images; zero incomplete samples |
| Resolution | Navigation/copy/editor pilots passed at 2200×1460 and 2000×1400; independent counter also produced 2002×1302 with explicit odd-pixel padding |
| Recovery | Real quit/relaunch and SIGKILL/relaunch recorded; labeled restart cards; interrupted transfer paused before explicit Resume |
| Media integrity | Every movie packet decoded; image checksums/chunks verified; measured early/middle/late audio offset was zero samples |
| Browsers | Chrome for Testing 158.0.8127.18, Firefox 159.0, WebKit 27.2, installed Safari 26.6.2; 43 checks passed |
| Step boundaries | Observed stop error before final-frame clamping: maximum 60.2 ms; timer fallback also passed the 100 ms target |
| Startup | Full standalone to metadata: Chrome 395 ms, Firefox 445 ms, WebKit 1554 ms on the qualification machine |
| Startup memory | Chrome owned-process RSS sum about 1.06 GB, including shared pages; JS heap about 1.5 MB and backing storage about 71.4 MB; these are post-metadata measurements, not peak memory |
| Files | MP4 71,408,608 bytes; standalone about 96 MB; retained source archive 5,782,429,158 bytes |
| Faults | Blocked frame output, resize and actual ENOSPC on a disposable APFS volume rejected; permission-denial and interrupted PNG contracts passed |
| Reuse | Independent counter host captured/narrated without FC/Fresh dependencies; synthetic non-Swift manifest rebuilt; source archive extracted and revalidated |
| App build | Signed debug bundle built; original bundle ID and signing team verified; installed app unchanged; no signing details in changed source files |

The installed-Safari check used existing Accessibility permission with a read-only
observer on an isolated copy. Player code and embedded media were unchanged;
Safari privacy settings were not modified. The report records the source page
checksum and the observed-copy checksum separately.

Publication still requires content/voice-rights review, the hosting/upload test,
actual URLs, and the user's Git/upload/deployment actions. No publication,
commits or pushes were performed by this implementation.

## Verification and definition of done

Use focused tests for the new contracts and a small real capture for integration;
run the full recording only once the pilot is sound.

| Area | Required evidence |
| --- | --- |
| Timestamps | Filename uniqueness and ordering; UTC clock changes do not affect media order; cross-lesson and restart mappings are correct |
| Capture | Two manually chosen sizes produce the displayed exact output dimensions; overlays/dialogs are visible; no recording controls leak into output |
| Failure handling | Unwritable/disk-full output, interrupted writes, capture denial, and sustained backlog cannot produce a false success |
| Reconstruction | Video rebuild needs only retained images/audio/manifest; first and final holds survive; static deduplication does not change timing |
| Narration | Long speech extends the correct visible state; fast/slow I/O stays synchronized; no clipped speech or overlaps; cache invalidates when text/voice changes |
| Timing accuracy | Validate segment boundaries against the rendered file, within one video frame plus codec audio priming tolerance; check early and late course segments for drift |
| Step player | Rapid selection/seeking cancels old boundaries; Play this step pauses at its declared end within a measured target of 100 ms on supported desktop browsers |
| Offline delivery | Single HTML plays video/audio/captions with network disabled and no neighboring files; web variant behaves equivalently |
| Recovery | Owned FC exits/relaunches without ending the take; interrupted copy is shown paused and resumed explicitly; normal user sessions remain separate |
| Reuse | Second host and synthetic external manifest produce the same outputs without FC engine/editor dependencies |
| Publication readiness | README entry and player links are prepared; asset size/quality report exists; all publishing actions remain deferred to the user |

Completion means a real narrated recording is playable from `standalone.html`,
its image files contain usable timestamps, chapters below the video seek correctly,
and a button plays only the selected step. The resized application determines the
recording resolution. Publishing the result to GitHub is the subsequent handoff.
