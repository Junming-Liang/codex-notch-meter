# Privacy and security

## What the meter reads

The meter requests the account type and quota windows from the installed official Codex desktop helper or CLI using the documented app-server interface. The account-type parser discards account identity fields. When the existing quota response supplies its optional accountId, the meter keeps only a redacted, opaque continuity value in memory with the last snapshot. It is never displayed, logged, encoded, persisted, or included in rendering artifacts. Missing identity suppresses numerical consumption comparisons. Raw responses are never logged or persisted.

The meter does not open or parse credential files, access tokens, conversation history, session recordings, or private Codex databases. It does not use private HTTP endpoints or request any model generation, login, logout, token refresh, or configuration change.

## Installed-app discovery

Automatic desktop discovery reads LaunchServices application registration and bounded `Info.plist` / `codex-package.json` metadata inside installed application bundles. It checks the OpenAI bundle identifier and Apple-anchored signing team for both the application and executable. Known helper paths must remain inside the application after symlink resolution. It does not launch the desktop GUI, scan private Codex data, or modify any app bundle.

A single background resolver handles metadata/signature checks. Its caller has a 30-second timeout and cancellation-aware wait; an abandoned read-only check can never launch Codex or update quota state. Explicit CLI paths and PATH/Homebrew remain supported. User-selected executables run with the user's permissions and must be trusted.

## What the CLI may do

The installed `codex app-server` is a separate OpenAI program. It inherits the runtime environment and existing `CODEX_HOME`, and owns its normal authentication, credential refresh, logging, caching, configuration loading, and network behavior. The meter's read-only request policy is not a promise that Codex itself never accesses credentials or writes files. Review the official CLI's policies and configuration separately.

The app does not read Codex stdout except for its own protocol connection. Subprocess stderr is discarded. User-facing errors contain fixed explanations and numeric error codes, never raw account or provider messages.

## Local preferences

The app stores only overlay/skin/refresh-feedback preferences, selected quota-group/window identifiers, motion/speed preferences, optional per-display contour corrections, an optional Codex executable path, and the optional Music, LRCLIB and AMLL enable preferences in macOS UserDefaults. It does not persist quota values, account names, emails, tokens, or reset history.

## Permissions and network

No telemetry, analytics, remote reporting, embedded web login, automatic updates, Accessibility access, Screen Recording access, or global keyboard hooks are implemented. The quota reader has no HTTP client; its Codex subprocess may contact OpenAI to retrieve current quotas. The separately opted-in lyrics feature has the narrowly scoped network boundary described below.

The island reads only the current pointer position while its overlay is enabled, to apply hover delays and ignore mouse events outside the revealed content. It does not record pointer history, monitor keys, install an event tap, or request input-control permissions. Polling and animation timers stop on sleep, display removal, overlay disable, and Quit. Routing flags are tested on hosted macOS; real cross-application click-through still needs physical interaction validation.

## Subprocess boundary

The production code sends only `initialize`, `initialized`, `account/read` with `refreshToken: false`, and `account/rateLimits/read`. It cleans up its own child after completion, timeout, cancellation, and sleep. During orderly app shutdown, it waits for all outstanding reads, including canceled reads, to confirm their owned children have exited. Force quit, crashes and power loss are outside this guarantee. A bounded fallback force-terminates only that same owned Process if it ignores normal termination. It never enumerates or kills other Codex processes.

Responses are bounded to 1 MiB per line and 4 MiB per connection. Unexpected server requests close the read-only connection. A selected custom executable runs with your user permissions; choose only the official CLI you installed and trust.

## Reporting problems

Do not attach credentials, raw account responses, chat history, or private configuration to public issues. Report your macOS version, CPU architecture, Codex CLI version, sanitized error code, and steps to reproduce. Quota values and screenshots may reveal usage patterns; review them before sharing.

## Synthetic rendering evidence

The optional CI contour harness renders only this app's own demo views into 1x/2x offscreen bitmaps. Its workflow artifacts contain synthetic quota data and explicitly labeled synthetic cutout composites, never screenshots of the desktop, other applications, or the user's account. Normal app use does not export these images or request Screen Recording access.

## Optional login item and installer

The user may explicitly enable or disable the main app's login item through Apple's `SMAppService.mainApp` API. System status is read when Settings appears, the app activates, and after a request; it is not replaced by a stored Boolean. No login item is registered at startup, installation, build time, in demo mode, or in CI. System Settings opens only when the user clicks. No launch daemon, privileged helper, custom LaunchAgent plist, automatic app relocation or security-setting change is used.

The DMG contains the app, a link to Applications and installation instructions. It does not run an installer script. CI mounts its own image read-only for verification and detaches it; login-item mutations use injected synthetic services only. Skin and motion choices are local preferences. Rainbow uses one bounded color-animation clock only while a visible colored surface is eligible; it pauses for Reduce Motion, low power, sleep, session inactivity or disabled/hidden surfaces. It never adds network access or quota polling.

### Local contour calibration

Optional alignment values are stored only in local preferences, keyed by the public display UUID for each built-in notched screen. The app does not query hardware serial numbers or transmit/log these identifiers. Horizontal, total-width, bottom-depth and corner corrections default to zero; Reset removes both correction stores for the selected display. Automatic fitting uses the current public exclusion rectangles and a documented circular approximation, so calibration is an optional fallback. Demo/native test fixtures use synthetic identities and never save calibration preferences.

## Refresh feedback

A transient update notice uses the same completed quota read; it adds no request, polling, notification permission or focus activation. A numerical decrease is shown only for fresh, monotonically ordered snapshots with the same supplied account continuity value, bucket/window identity, duration and future reset epoch. It means percentage points between those two reads, not tokens or a relative percentage. Initial reads, source/account changes, missing identity, errors, stale gaps, resets and increases use non-comparative wording. Only the newest pending notice is retained briefly behind active interaction.

Refresh feedback is enabled by default for the requested update experience and can be disabled in Settings. Disabling it discards pending feedback and dismisses a passive notice without closing active hover details. This preference does not affect reads or login-item enrollment.

## Optional Music lyrics (v1.0.0 candidate)

Music support and online lyrics lookup are both off by default. Only an explicit enable or authorization action may request Music Automation consent. Ordinary polling and restored preferences do not prompt. The reader addresses an already-running system Music process by PID, validates its process instance, and sends only public read-property Apple Events. It does not launch or activate Music, control playback, scan the library, or use private MediaRemote/cache/token access. Current title, artist, album, duration, playback state, position and an optional Music persistent ID remain transient in memory and are never logged or included in diagnostics.

A separate online-lookup confirmation explains that title, artist, album and duration will be sent to `https://lrclib.net/api/get` and bounded title/artist searches at `https://lrclib.net/api/search` for community-lyrics matching. No request occurs before that opt-in. The client uses an ephemeral session, no cookie/credential/persistent cache stores, rejects all redirects, and bounds payloads, time and concurrency. Provider results must match the requested metadata; they are not Apple official lyrics and may be absent or wrong. The provider's software license does not establish a blanket license to lyric text; the public API permits anonymous application lookup, but rights to individual community submissions remain uncertain. No lyric database is bundled or persisted.

A user-selected local UTF-8 LRC/text file is read with a byte limit and one actual worker slot. Its selection is bound to the current track revision, so a song change while the picker is open cannot attach the file to another song. File paths, bookmarks and lyric text are not persisted or uploaded. Plain text has no invented synchronization. Local I/O on provider-backed storage can stall; disabling/Quit retires its result without waiting for that I/O.

Track/source changes, disabled settings, sleep, inactive session and Quit cancel pending work and prevent late results from replacing current content. Missing or stale Music data clears displayed lyrics. Music's public scripting API has reported streaming-track limitations, so reliable metadata for every stream is not promised. Native fixtures use injected readers/providers and original synthetic lyrics; they never request real Automation permission, launch Music, access an account or perform online lyric requests. Actual TCC, streamed playback and physical presentation require separate validation.

### Optional AMLL fallback (unreleased candidate)

AMLL is separately off by default, including upgrades from existing LRCLIB opt-in. Its confirmation names `api.amll.dev` and discloses title, artist and album transmission for current and future played tracks. No duration, Music persistent ID, Apple catalogue ID, Apple account data or local lyric file is sent to AMLL. Both LRCLIB and AMLL toggles must be enabled for fallback requests. Turning either off cancels affected work; local imports take precedence.

The only added destination is `https://api.amll.dev/v1/lrclib/search`. At most one AMLL request follows an unsuccessful LRCLIB attempt. All existing transport restrictions apply: HTTPS allowlist, no redirects/auth/cookies/cache, 10-second request deadline and 1 MiB streaming byte ceiling. No server is deployed, API key obtained or lyric corpus embedded. See [provider contract](docs/AMLL-LYRICS.md) for matching, licensing and verification limits.

## 手动诊断日志 / Manual diagnostic capture

抖动诊断默认关闭，不持久化录制开关。用户开始后，最多录制 5 分钟、保留不超过 2 MiB 的结构化日志（内存结构有少量额外开销）。仅收集有限几何/状态/时序和刘海附近相对坐标，不记录完整桌面轨迹、歌曲/歌词正文、账户数据、凭据、文件路径或窗口标题。没有新增网络传输、截图、音频或权限请求。用户停止后通过原生保存面板选择位置，再自行检查和分享；取消或失败保留内存记录，退出清除。详见 [诊断说明](docs/DEBUG-CAPTURE.md)。

Manual diagnostics are off by default and never restored on launch. Capture is bounded, memory-only until you explicitly save, and never auto-uploaded. Finite geometry/state/timing fields exclude credentials, account content, music/lyric text, paths, window titles and a full cursor trajectory. An exported file remains wherever you chose to save it.
