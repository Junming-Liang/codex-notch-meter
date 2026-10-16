# v1.0.0 Apple Music lyrics: optional integration and safety contract

Status: local implementation draft, synthetic core/native fixtures and source review in progress. This is not part of the v0.1.9 quota-notification repair or its release. No Music access, Automation prompt, network lyric request, provider enrollment, or user-machine validation has been performed.

## Product boundary

- Add an optional Music.app companion. The quota meter continues to work when Music support is disabled, denied, unavailable, or failing.
- Preserve the approved notch contour, calibration, stroke widths, animation and quota-refresh behavior. The existing collapse visibility treatment is preserved.
- Show line-synced lyrics only when actual line timestamps are available. Plain text is explicitly unsynced; instrumental, no match, offline, permission denied and unavailable playback metadata are distinct states.
- Do not call community or imported text “Apple's official lyrics.” Public MusicKit exposes `hasLyrics`, not the lyric text or synchronization payload.
- The initial UI adds a bounded row inside the existing expanded content and opt-in Settings controls. It does not automatically expand the notch for music.

## Implemented module boundaries

1. `MusicSnapshotProvider`: a single bounded read of the already-running Music application using public Apple Events. Capture title, artist, album, duration, position and playback state; validate individual fields. No Music launch, playback control, library edits, private MediaRemote APIs, cache/token extraction, microphone, Accessibility or screen recording.
2. `LyricsProvider`: local user-selected LRC/text first. A separately consented LRCLIB provider uses the reviewed public API and strict metadata matching. No automatic fallback across websites.
3. `Lyrics` core: bounded original LRC parser, cue data and a deterministic timeline. Preserve Unicode, multiple timestamp tags, explicit gap cues and seek behavior. Never fabricate word timing.
4. `MusicLyricsController`: one pending IPC read and one pending lyric lookup at most; reject retired generations, canceled results and wrong-track results. It owns all timers/tasks and shuts them down when disabled, sleeping, session-inactive or stopped.
5. Existing island presentation: consume a read-only lyric state with explicit priority. Quota notifications and active hover/settings/menu interaction supersede passive lyrics. Music results cannot dismiss an active quota notice or restart its dwell timer.

## Consent and privacy

- Music support is off by default. The enable action explains that the app will read Music's current song and playback position; only that action may initiate the first Automation consent request.
- The packaged app includes `NSAppleEventsUsageDescription`. Preserve the current signing model. Any future sandbox/hardened-runtime entitlements need a separate exact review; Automation approval is not a sandbox exemption.
- Denial is recoverable through a clear settings explanation. Never repeatedly prompt, accept permissions automatically, or change system security settings.
- Optional online lookup is independently off by default. Before enabling, name the provider and explain transmission of track title, artist, album and duration to that provider. No account ID, Apple token, playlist history, user files or quota data is sent.
- Local imports use an explicit file picker and bounded file access. No library-wide filesystem scan. Private song/lyric data stays out of diagnostics, crash-like dumps, test artifacts and repository fixtures.
- The public API explicitly supports anonymous application lookup; its identifying User-Agent, request spacing and Retry-After requirements are enforced. The provider's server-code license does not license every submitted lyric. Community-content rights remain uncertain; do not bundle a lyrics database, persist provider text or label it copyright-free.

## Scheduling and stale-data contract

- Do not add quota polling. Music IPC is independent and off the UI's synchronous path.
- While enabled and Music is running, target one bounded sample followed by a one-second wait while playing or three-second wait otherwise. This is a scheduling budget, not a measured energy guarantee.
- Advance a verified playhead with monotonic elapsed time between authoritative samples, then schedule line-boundary changes. Stop interpolation when paused or stale; seek replaces the anchor immediately in either direction.
- A new track invalidates the old lyrics before lookup begins. Late lookup results require an exact current generation/track match before display.
- Missing/error/stale metadata must clear the old lyric, rather than attach it to an unknown song. If Music reports a stale but internally plausible identity, the adapter cannot prove correctness; known API limitations must remain visible in compatibility notes.
- Bound IPC deadline, payload, outstanding work, retries/backoff and any cache. Do not create an unbounded task per timer tick. A blocked or denied read cannot delay Quit, quota refresh, hover or sleep.

## Initial UI

- Use the existing connected, top-anchored compact island treatment for one current lyric (up to two visual text lines). Keep all text below the system-reported camera exclusion area.
- Preserve the full-U quota contour and its true remaining fraction. Lyrics do not recolor consumed quota or turn song duration into quota progress.
- Quota update > active quota details/settings/menu > passive lyrics. Hover retains the existing details behavior; a music mode/setting must be explicit if it changes idle presentation.
- Reduce Motion uses the existing reduced-motion policy. Do not copy animations or geometry from an unrelated app.

## Verification before any release

- Pure tests: malformed/oversized/Unicode/multi-timestamp LRC, offset convention, duplicate timestamps, empty cues, unsynced/plain text, before-first cue, pause/resume, seek both directions, stale samples and track-generation replacement.
- Adapter mocks: Music absent, denied Automation, missing properties, timed-out IPC, malformed result, metadata change during a read and stale results after stop. CI must not request real Music permission or access an account.
- Provider mocks: no request before consent, exact supported host/method/fields, bounded response/timeouts, mismatch/ambiguous results, instrumental/unsynced states, cancellation and cache limits. Use only original synthetic song/lyric fixtures.
- Native synthetic UI: quota-notice priority, hover hold, settings/menu priority, clipping, nonactivation, Quit and teardown. Repeat all retained quota/geometry/motion/packaging gates on the final source.
- Actual Music.app/TCC behavior, macOS-version streaming compatibility and physical-notch rendering require separately authorized integration evidence. Cloud synthetic tests cannot establish them.

## Primary references checked 2026-10-16

- Apple MusicKit Song / `hasLyrics`: https://developer.apple.com/documentation/musickit/song and https://developer.apple.com/documentation/musickit/song/haslyrics
- Apple Scripting Bridge: https://developer.apple.com/documentation/scriptingbridge
- Apple Events usage description: https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription
- Hardened-runtime Automation entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events
- Sandbox boundary: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
- Apple DTS discussion of Tahoe current-track/streaming failures: https://developer.apple.com/forums/thread/798267 . The thread acknowledges the issue and recommends catching errors; it does not establish universal resolution.
- LRCLIB API policy and request contract: https://lrclib.net/docs . Anonymous application access is supported; this does not establish copyright permission for all community lyrics.
- LRCLIB provider architecture: https://github.com/tranxuanthang/lrclib/blob/main/ARCHITECTURE.md . Metadata-based community matching is not authoritative Apple lyric identity.
- MusicLy (MIT) as a public implementation reference only: https://github.com/cbbtoagi/MusicLy . No source is copied into this project.

No private API backend or third-party source dependency is approved by this document. Any later provider/API policy change requires a fresh source and permission review.
