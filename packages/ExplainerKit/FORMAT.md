# Media interchange format, version 1

All paths inside media manifests are relative to their owning recording root.
Assets must exist and resolve inside that root, including through symlinks. UTF-8
JSON uses `schema: 1`. Relative media times are integer nanoseconds; interval ends
are exclusive. Absolute host/UTC clocks require an integer-preserving parser;
do not round them through JavaScript's floating-point number type. The player
receives only bounded relative times, not absolute clock metadata.

## Catalog and authored steps

A catalog is a directory of lessons plus `chapters.json`, a lesson JSON list, or
`{"schema":1,"chapters":[...],"lessons":[...]}`. Chapters have stable `id` and
`title`; lessons have `id`, `title`, `order`, `chapter`, and `steps`. Host actions
are opaque to the media compiler. A presentation boundary looks like:

```json
{"id":"counter.action-show", "caption":"Add one", "presentation":{
  "id":"counter.add", "title":"Add one", "narration":"Click Add One to increase the counter.",
  "lead_in":0.12, "trailing_hold":0.35
}}
```

## Course and take

`course.json` contains `schema`, `title`, `fps`, `status`, `expected_lessons`, and
`takes`, an ordered list of `{"manifest":"capture/LESSON/manifest.json"}`.
Only a completed course can render. Each requested lesson must appear exactly
once in that order. Chapter lessons are contiguous.

A take contains `manifest.json`, `events.jsonl`, and `frames/*.png`. See
[capture-v1.schema.json](Schemas/capture-v1.schema.json). Final manifests contain
`status: "complete"`, no errors, fixed even pixel dimensions, `duration_ns`, lesson
metadata and frames. A recording checkpoint is deliberately incomplete. Failed
takes remain diagnostic evidence and cannot be rendered as successful content.

Frames have strictly increasing `pts_ns`, unique `sequence`, relative `path`, and
PNG `sha256`. The first frame starts at zero. Every image holds until the next
frame, or `duration_ns` for the final image. Exact source rational timestamps and
UTC/host clock anchors are optional provenance. Native filenames include elapsed
nanoseconds, UTC microseconds, sequence, lesson and action. UTC corrections do not
control ordering. Generated restart cards have `generated: "application_restart"`.

The JSONL journal uses `type`, `pts_ns`, and fields appropriate to the event:

| Event | Fields and meaning |
| --- | --- |
| `segment_started` | `id`, `title`, `text`; begin a presentation interval |
| `segment_completed` | matching `id`; end the interval |
| `step_started` | `id`, `action`, `lesson`; actual host action begins |
| `step_completed` | matching `id`; action and state checks finished |
| `host_relaunched` | previous/new owned process IDs; same take clock |
| `restart_card` | generated transition replaces the absent app |

Events are ordered within take duration. Action pairs may nest. Presentation
pairs cannot overlap. Missing completions, hashes, images, or inconsistent pixel
dimensions fail semantic validation. Source-sample counters distinguish retained,
pixel-identical coalesced, incomplete and intentional transition samples. Completed
native captures must account for every accepted sample as a retained source frame
or an identical coalesced image. A full
PNG queue or any write error invalidates the take; static holds are not dropped
animation frames.

## Narration and final timeline

`narration/script.json` stores `schema`, `language`, provider settings and `clips`
keyed by presentation ID. Each clip gives `path`, `text`, `duration_ns`, `sha256`,
cache identity and provenance. PCM is 48 kHz mono signed 16-bit WAV. The compiler
checks measured clip duration against its declared duration and visual interval,
adds silence at measured offsets, and rejects overlaps.

`render/timeline.json` adds take offsets and is the common source for MP4,
chapter navigation, step controls, captions, transcript and still links. See
[timeline-v1.schema.json](Schemas/timeline-v1.schema.json). Each final frame keeps
both `pts_ns` and `source_pts_ns`. `render/images.json` maps presentation stills
to final video timestamps without renaming retained source images. H.264 delivery
rounds onto its declared frame grid; source nanoseconds remain unchanged.

## External capture session handshake

The supervisor creates a private config with absolute `folder`, `session`,
`scriptPath`, optional `narration`, lesson metadata and geometry:
`x`, `y`, `pointsWidth`, `pointsHeight`, native `scale`, physical `width`, `height`.
Coordinates are macOS screen points, bottom-left origin. Output pads odd pixel
dimensions by one pixel; it never silently crops or rescales the selected window.
It launches hosts with `--record-session CONFIG`, `--record-take LESSON`,
`--profile DIRECTORY` and `--tutorial-world DIRECTORY`. Hosts may ignore bootstrap
arguments they do not use; the independent counter host only reads the config.

The host atomically writes `session/host.json` with `schema`, owned `pid`, visible
owned `window_ids`, `host_ns`, and status `ready`, `restarting`, `complete` or
`failed`. On ready, the helper starts capture and waits for its first completed PNG write,
then writes `capture_ready.json` with the matching `host_pid` and clock origin.
The host must wait for this PID-specific acknowledgement before running actions.
It appends event requests with absolute `host_ns` to `requests.jsonl`; the helper
converts them to take-relative times and orders journal writes.

On restart, the host closes current action/presentation pairs, writes
`restarting`, and exits. The helper draws a restart card, then selects only the
replacement process's announced windows and acknowledges its first new image.
The host monitors the frozen geometry and invalidates the take on resize/move or
scale change. On completion it waits for `capture_result.json` before cleaning up.
The helper drains accepted image writes before declaring success. Unexpected host
exit, capture errors, journal corruption and deadlines produce failure results.
