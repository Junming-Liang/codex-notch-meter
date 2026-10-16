# Apple Music lyrics: setup and safety contract

Released: [v1.0.0](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v1.0.0). [Release Run #41](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38890633568) passed all required gates on the exact final source. Directly read native Music evidence contains 350 synthetic checks in 80.601 seconds, actual light/dark own-view text, 6.047/4.083/2.087-second priority holds, pause/hover/reversal/lifecycle handling and cleanup. Actual final DMG identity and both checksums also passed. See [validation and archive identity](VALIDATION.md). Beta 1 and v0.1.9 remain available.

The user reported that beta1 displays lyrics in their setup. This is configuration-specific feedback; CI injects Music, permission, provider and file boundaries. A separate anonymous request for LRCLIB's documented public example returned HTTP 200 after a transient 503 and backed-off retry, with matching schema/metadata and synchronized-lyrics presence; no lyric text was retained, and that check did not exercise the shipped Swift transport. Cross-version Music/TCC, streaming compatibility and physical appearance remain unverified.

## v1.0.1 development candidate

Native validation is pending; the published v1.0.0 links and evidence above remain the released baseline.

The revised default is a closed, hardware-depth music indicator with tiny real artwork or a neutral placeholder. No playback controls or artwork network requests are added. Move the pointer completely across the fixed top band from left to right without pressing a mouse button to select the lyric view; reverse direction to close it. A crossing with no usable current lyric is ignored. Merely hovering, moving vertically, resizing the panel or jittering near an edge does not select a mode.

The selected mode starts off each app session and survives pause, track changes and display recreation. Those events immediately hide old content and reset a partial crossing; lyrics return only when the selected mode has fresh usable current text. Disabling the feature clears the selection. Quota notices temporarily take priority without changing it. Ordinary hover still opens quota details.

The approved lyric hierarchy is a small 10pt title, left-aligned 18pt current cue and subdued 12pt actual adjacent next cue. Current text can use two lines; missing next text reduces the target height through the existing spring. Blank gaps, before-first cues, instrumental/unmatched/error states cannot create empty lyric cards or fabricated next lines. Plain text stays explicitly unsynchronized.

Artwork uses the existing read-only, PID-scoped public Music Apple Events permission. Its optional raw-data response has a separate 4MiB budget and 150ms event wait, preserving a 1s reserve for the final track-identity read. Only bounded single-frame PNG/JPEG data is considered; source dimensions are inspected before a thumbnail of at most 64×64 pixels is decoded. The same process/track/state bracket applies before publication. Images remain in memory, are never logged, and no alternate network source is used. Installed dictionary and synthetic decoder/own-view checks are required; they do not establish all live Music artwork compatibility.

## Playback and quota priority

Fresh playing music automatically opens compact lyrics. Pause, stop or stale/error metadata hides music; manual hover may retain ordinary quota details. Quota notices temporarily replace passive music without restarting their painted 2/4/6-second dwell, then return to current playback or idle. Settings/menu/popover suppression also applies to recreated displays.

The existing shape, calibration, 3.5/4pt strokes and spring remain. The black body stays visible while its global contour is displaced from idle, then smoothly fades within the final four points using the same Canvas/progress as the rail. Native coverage and old-fade negative controls passed; fixture pixels do not establish physical hand-feel. Displayed island captions use “当前额度” and “主额度”.

## Setup / 使用

1. 自行打开 Music 并播放歌曲。在本应用“设置 → Apple Music 歌词”中开启“播放时自动展开 Apple Music 歌词”；阅读说明后按意愿批准自动化访问。若需要重试，使用“请求 Music 授权…”。
2. 可为当前歌曲导入 UTF-8 LRC / 文本。也可单独开启 LRCLIB 在线匹配：它会接收歌名、歌手、专辑和时长，返回社区歌词。该选项默认关闭，社区歌词不是 Apple 官方歌词。
3. 播放时自动显示紧凑歌词，暂停后隐藏音乐内容并收起。额度变化提示结束后，仍在播放就返回歌词，否则回到静止状态；悬停可保留普通额度详情。没有匹配歌词时显示歌曲和对应状态，信息失效则停止显示旧内容。

Open Music yourself and play a track. Enable the lyrics setting and choose whether to grant Automation. Import a local UTF-8 LRC/text file for that track, or separately consent to sending its title, artist, album and duration to LRCLIB. Fresh playing opens compact lyrics automatically; pause hides music, and an active quota notice finishes before returning to music or idle. Hover can retain ordinary quota details. Missing lyrics, unavailable metadata and denied permission remain explicit states. Builds remain ad-hoc signed and unnotarized; authorization and streaming behavior vary by setup.

## Product boundary

- Add an optional Music.app companion. The quota meter continues to work when Music support is disabled, denied, unavailable, or failing.
- Preserve the approved contour, calibration, stroke widths, spring and quota-refresh behavior. The body visibility staging now follows geometric distance from idle during both opening and closing.
- Show line-synced lyrics only when actual line timestamps are available. Plain text is explicitly unsynced; instrumental, no match, offline, permission denied and unavailable playback metadata are distinct states.
- Do not call community or imported text “Apple's official lyrics.” Public MusicKit exposes `hasLyrics`, not the lyric text or synchronization payload.
- The same existing island automatically opens its compact content while fresh playback is playing. Paused lyrics are hidden even inside manually hovered details; local import and provider consent remain separate controls.

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

## Presentation priority

- Use the existing connected, top-anchored compact island treatment for one current lyric (up to two visual text lines). Keep all text below the system-reported camera exclusion area.
- Preserve the full-U quota contour and its true remaining fraction. Lyrics do not recolor consumed quota or turn song duration into quota progress.
- Active hover shows ordinary details; quota notices replace passive music until their existing dwell expires. Settings/menu/popover suppress passive expansion. None of these creates another panel or motion clock.
- Reduce Motion uses the existing reduced-motion policy. Do not copy animations or geometry from an unrelated app.

## Verification before any release

- Pure tests: malformed/oversized/Unicode/multi-timestamp LRC, offset convention, duplicate timestamps, empty cues, unsynced/plain text, before-first cue, pause/resume, seek both directions, stale samples and track-generation replacement.
- Adapter mocks: Music absent, denied Automation, missing properties, timed-out IPC, malformed result, metadata change during a read and stale results after stop. CI must not request real Music permission or access an account.
- Provider mocks: no request before consent, exact supported host/method/fields, bounded response/timeouts, mismatch/ambiguous results, instrumental/unsynced states, cancellation and cache limits. Use only original synthetic song/lyric fixtures.
- Native synthetic UI: quota-notice priority, hover hold, settings/menu priority, clipping, nonactivation, Quit and teardown. Repeat all retained quota/geometry/motion/packaging gates on the final source.
- Actual Music.app/TCC behavior, macOS-version streaming compatibility and physical-notch rendering require separately authorized integration evidence. Cloud synthetic tests cannot establish them.

## Bounded same-provider matching and retries

- Exact LRCLIB `/api/get` first when album metadata is available. Semantic no-match may proceed to structured `/api/search` for original title+artist, then a conservatively normalized title only when different. Never combine the broad `q` field with an assumed artist filter. An empty album may search directly.
- At most three distinct sequential requests per lookup, each with a ten-second deadline, separated by at least300ms: at most30.6seconds of request/gap budgets, plus scheduler overhead. No redirect, cookies, credentials or disk response cache. Cancellation retires the chain.
- Only allowlisted complete film/TV attribution suffixes and known album presentation labels are normalized. Live/remix/acoustic/cover/language/remaster and other recording markers remain identity-bearing; unknown parentheses are retained. Exact normalized artist, duration within two seconds and a unique best candidate are required. Album differences may affect rank but never override a recording mismatch. Arrays at the documented20-result cap are rejected because truncation cannot establish uniqueness.
- Embedded LRC tags are checked against the selected candidate. Plain text remains explicitly unsynced. No additional provider or metadata recipient is introduced.
- Genuine no-match, matching record without usable lyrics, version mismatch and temporary service/network failure retain distinct status across ordinary playback polls. At most two automatic retries follow a transient failure: local30/60second backoff, while a longer server Retry-After is never shortened. A metadata-free cooldown survives track/source/consent invalidation. Errors are never relabeled as a confirmed absence merely because another sample arrived.

## Primary references checked 2026-10-16

- Apple MusicKit Song / `hasLyrics`: https://developer.apple.com/documentation/musickit/song and https://developer.apple.com/documentation/musickit/song/haslyrics
- Apple Scripting Bridge: https://developer.apple.com/documentation/scriptingbridge
- Apple Events usage description: https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription
- Hardened-runtime Automation entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events
- Sandbox boundary: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
- Apple DTS discussion of Tahoe current-track/streaming failures: https://developer.apple.com/forums/thread/798267 . The thread acknowledges the issue and recommends catching errors; it does not establish universal resolution.
- LRCLIB API policy and request contract: https://lrclib.net/docs . Anonymous application access is supported; this does not establish copyright permission for all community lyrics.
- LRCLIB structured query and result limit: https://github.com/tranxuanthang/lrclib/blob/main/server/src/search_index/query.rs and https://github.com/tranxuanthang/lrclib/blob/main/server/src/search_index.rs . `q` overrides structured fields; search is capped at20 results.
- LRCLIB provider architecture: https://github.com/tranxuanthang/lrclib/blob/main/ARCHITECTURE.md . Metadata-based community matching is not authoritative Apple lyric identity.
- MusicLy (MIT) as a public implementation reference only: https://github.com/cbbtoagi/MusicLy . No source is copied into this project.

No private API backend or third-party source dependency is approved by this document. Any later provider/API policy change requires a fresh source and permission review.
