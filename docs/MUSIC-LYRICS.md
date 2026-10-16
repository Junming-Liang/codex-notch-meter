# v1.0.0-beta.1 Apple Music lyrics: setup and safety contract

Status: [v1.0.0-beta.1 is released](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v1.0.0-beta.1). The feature source passed [diagnostic Run #34](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38872606427), including 284 passing synthetic tests and 108 native Music-fixture checks. The final beta head passed [release Run #35](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38876321184), including the repeated 108-check native fixture and actual beta-identity DMG inspection. A separate anonymous request for the provider’s documented public example succeeded after a transient HTTP 503 and a backed-off retry; only schema, metadata matching and lyric presence/counts were retained. It did not exercise the shipped Swift transport. Actual Music.app reads, Automation/TCC approval and macOS-version streaming compatibility remain unverified. v0.1.9 remains available independently.

## Beta setup / 测试版使用

1. 自行打开 Music 并播放歌曲。在本应用“设置 → Apple Music 歌词”中开启“在展开详情中显示 Apple Music 歌词”；阅读说明后按意愿批准自动化访问。若需要重试，使用“请求 Music 授权…”。
2. 可为当前歌曲导入 UTF-8 LRC / 文本。也可单独开启 LRCLIB 在线匹配：它会接收歌名、歌手、专辑和时长，返回社区歌词。该选项默认关闭，社区歌词不是 Apple 官方歌词。
3. 悬停刘海或打开菜单栏详情查看歌词；额度提示仍优先。没有歌词、权限拒绝或歌曲信息不可用会显示对应状态；请勿据此假定所有流媒体歌曲受支持。

Open Music yourself and play a track. Enable the lyrics setting and choose whether to grant Automation. Import a local UTF-8 LRC/text file for that track, or separately consent to sending its title, artist, album and duration to LRCLIB. Hover the notch or open menu-bar details to view lyrics. Missing lyrics, unavailable metadata and denied permission remain explicit states. This beta is ad-hoc signed and unnotarized; actual authorization and streaming behavior need user testing.

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
