# Music interaction repair (candidate)

This candidate is based on main `24126f586e3e098a17cb318fc240704f469f9de5`.
It is not a claim of a new release or physical-device validation.

## Reproduced code paths

- Closed playback painted two independent black accessory wings outside the original
  camera-sized quota contour. Music details additionally faded the perimeter away
  and drew interior horizontal bars. The wider black shell and quota outline were
  not one presentation shape.
- The 30 Hz pointer poll required its first inside sample to land in a 28-point edge
  strip, and rejected a completed crossing shorter than 60 ms. A legitimate path
  sampled outside → middle → outside could never arm or finish.
- Leaving the 18-point gesture band cleared its reservation even when the pointer
  remained over the appearing shell. Ordinary hover immediately took ownership of
  that same movement and targeted full details. The previous smoke helper avoided
  this by moving the pointer outside the display; that did not test natural exits.

## Narrow repair

Body, perimeter, clipping, native frame and hover now use the same music shell.
The compact artwork and playing glyph keep their existing 20-point dimensions and
positions. The immutable camera/calibration bounds and fixed gesture corridor are
separate from this presentation shell. The used edge remains black; all five
existing quota paints remain unchanged. Music quota details keep textual values
without a second interior progress bar.

Mouse-only local/global AppKit observation supplements polling. No event tap,
keyboard observation, accessibility request, or playback control is introduced.
The recognizer clips consecutive samples to horizontal entry/exit edges, accepts
fast complete paths, and rejects vertical entry, buttons, stale gaps and reversals.
A completed gesture suppresses ordinary hover until the pointer leaves the stable
full shell; a subsequent fresh hover still opens details.

Accessory appearance/disappearance and expansion use the same frame callback and
critically damped solver. Their current positions/velocities survive reversals.
There is no Boolean width jump on pause/resume or a second animation scheduler.
Raw-depth/calibration combinations that cannot contain the small accessories fail
closed, without disabling the expanded lyric perimeter.

## Verification

Local cloud checks: source/privacy preflight, 24 Music dictionary safety tests,
22 installer mock tests, 38 release-source/asset safety tests, 261 Music and 15 update native receipt-parser controls, workflow syntax, and diff whitespace.
The cloud host has no Swift/macOS toolchain; XCTest, app compilation and native
rendering must be run in macOS CI before distribution.

New XCTest coverage includes fast/sparse trajectories at 192 polling phases,
vertical/button/time negatives, gesture-to-hover ownership, and music geometry
across 1x/2x scale, global origins, calibration, and 924 blend/expansion pairs.
These are source additions pending execution, not claimed passing Swift tests.

The native Music gate now requires a real-time sampled outside → middle → outside
path, adjacent/downward exit into the visible shell, no intermediate details
retarget, multiple coherent moving paint receipts, and actual own-view perimeter
pixels for all five skins. Compact, full-detail and wing-ineligible full-detail states are checked. It writes `perimeter-<state>-<theme>.png` alongside its existing
synthetic evidence. These captures are the app's own synthetic view, not the user's
screen or proof of physical compositor smoothness. Existing quota priority,
2/4/6-second holds, pause/stale/track behavior and native gates remain required.


## v1.0.2 draft staging

The existing manual workflow keeps `publish_release=false` and `stage_draft=false`
by default and rejects both being true. For review, use only `stage_draft=true`.
After both required jobs succeed, the release job downloads that same run's
artifacts, validates the exact source and checksums, and creates a private draft.
It refuses existing v1.0.2 tags/releases and never replaces assets. The draft
contains the original ZIP/DMG, both checksums, source metadata, a complete asset
hash manifest, and 22 explicitly named synthetic PNGs. Publishing that same draft
after image review does not rebuild or replace its binaries. Only this release
job has repository write permission; checkout never persists credentials.

## Six-second notification follow-up

The user reports v1.0.0 with a six-second preference. Its unchanged-read path
published nil and immediately dismissed a visible notice; v1.0.1 already corrected
that model path. Normal successful quota polling is 60 seconds, not the one-second
UI clock. Two further early-close paths were shared by v1.0.0, v1.0.1 and main:
250ms without an exact settled paint receipt dismissed the notice before its hold
started, and a growing hover region could capture a stationary pointer, promote
to details, then close on pointer exit. These are code-confirmed failure paths,
not a diagnosis from the user's machine or logs.

The candidate reserves active notices against passive pointer entry/exit and
resets pending hover history. Slow paint acknowledgment now requests another
layout/display instead of dismissing or inventing readiness. Hidden/invalid panels
retire the presentation; ten seconds without stable paint is a logged presentation
failure rather than indefinite input reservation or a successful dwell. The full captured
2/4/6-second hold begins only after actual stable paint/viewport acknowledgment.
Explicit invalidation (disabled, failure, account/source change, lifecycle stop)
still retires stale notices. A newer eligible change has its own captured hold;
ordinary unchanged reads and settings edits do not shorten the current one.

Native regressions exercise six painted seconds with music and adjacent pointer
movement, six-second unchanged-read recovery, replacement changes, same-ID
replays, and mid-hold duration edits. A demo-only delayed-readiness hook withholds
consumption of real paint for 1.2 seconds to exercise the former 250ms cancellation
path. Actual Swift/native execution is still pending CI.
