# Validation status

Observed results are pinned to the exact tested source below, not automatically to later documentation-only commits on `main`.

## v0.1.1 observed macOS results

[Workflow run #7](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38552814815) passed on 2026-10-14 using standard hosted `macos-15` runners.

- Tested source: [`ac6d6cbf771fb82c6e1d918ccaa00be0d895b505`](https://github.com/Junming-Liang/codex-notch-meter/commit/ac6d6cbf771fb82c6e1d918ccaa00be0d895b505)
- Source tree: `b38eda11e56c9c84c9cda530df17780b0b33b80e`
- Swift XCTest: 53 methods discovered, 52 synthetic tests passed, one opt-in official-artifact test skipped in the synthetic job, zero failures
- The official-artifact test passed separately in its dedicated job
- Apple Silicon (`arm64`) and Intel (`x86_64`) native builds, universal architecture check, Info.plist validation and ad-hoc signature verification: passed
- Universal ZIP packaging and the release checksum gate: passed

### Actual native island checks

All three demo-only scenarios passed: normal quota data, missing-helper/error state, and multiple quota groups. Each starts the real AppKit/SwiftUI application and requires its readiness marker plus orderly process exit within 25 seconds.

The checks observe the ordered panel's actual frame, content origin/bounds and hosting safe area at multiple animation sizes. They also verify native bitmap coverage in memory, non-key behavior, hover-state collapse/reentry, motion settling, controller teardown, Reduce Motion, measured visible/interactable Quit bounds, mouse-routing flags, and dispatch/menu/local-command Quit routes. No Codex process or account session is started.

The hosted display reported matching normalized requested/actual frames and the correct top edge. This establishes the tested hosted-window behavior; it does not establish a physical MacBook notch, actual cross-application mouse delivery, or a native screenshot.

### Real official desktop artifact

The dedicated job downloaded the official desktop DMG with a 1 GiB / 120-second cap, mounted it read-only, called the production resolver, and detached the volume cleanly.

- Official desktop version: `26.1007.71326`, bundle `com.openai.codex`
- Application deep/strict signature and native-helper signature: passed
- Resolved helper: `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`
- Complete production resolution: approximately 10.01 seconds, inside the 30-second production deadline
- The test allows only 0.5 seconds of scheduling tolerance beyond that same production deadline
- No downloaded executable, desktop GUI, app-server or account session was launched

The earlier [diagnostic run #6](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38550905744) measured 13.03 seconds for cold application verification and 0.58 seconds for the native helper. That evidence motivated the bounded 30-second budget. Caller cancellation remains immediate; signature and containment checks were not relaxed. See [desktop discovery](DISCOVERY.md).

## Published developer preview

[`v0.1.1`](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.1) is a prerelease bound to the tested source above.

- Archive: `CodexNotchMeter-0.1.1-universal.zip`
- Archive size: 701,775 bytes
- GitHub-advertised SHA-256: `fbe18bacb000f9377920740436079a6a6590242d90f641fdd5c407c73d19c4f8`
- A matching `.zip.sha256` file accompanies the archive; the release workflow verified the archive against it
- The published download was not independently downloaded and rehashed during this audit
- Signing: ad-hoc only; no Apple Developer ID or notarization

macOS may block downloaded builds. Hosted execution does not guarantee that an unnotarized download opens on every Mac. The project provides no security-bypass commands.

## Still awaiting separate verification

- Physical MacBook notch placement, Retina behavior, real hover/focus/click delivery, full-screen Spaces and multi-display interactions
- Live quota reads against the user's signed-in official Codex installation
- Actual native screenshots and visual acceptance

The 1x/2x unit geometry cases are mathematical checks, not physical Retina evidence. Official artifact discovery proves that the inspected helper can be found and verified, not that a real account provides quota data.

## Historical v0.1.0

[v0.1.0](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.0) and its immutable assets remain available for history. Its [run #4](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38536308482) passed 32 synthetic tests and a simpler native startup check, but did not inspect the actual notch panel or desktop-bundle discovery. Users subsequently reported desktop discovery, placement and hover/Quit-usability defects. Prefer v0.1.1.

The v0.1.1 diagnostic rounding failure was measured and repaired. It should not be described as a proven explanation of every original physical-device v0.1.0 symptom.

## Manual acceptance checklist

Use `--demo` first, then an account only with its owner's permission.

- Notched MacBook: left/right rails track the actual notch, including scaled resolutions
- Hover the collapsed rails, follow the continuous expansion, leave/reenter during collapse, and repeat quickly
- Hover does not activate the app or steal keyboard focus
- Rails occupy narrow side/bottom regions and do not interfere with ordinary menu-bar clicks
- Details show remaining percentages, returned window durations, local reset date, and countdown
- Expired reset times show pending fresh data; they do not refill quota
- Menu-bar details, right-click menu, Settings, overlay toggle, and Quit work
- External display, mirrored display, changed primary display, negative/vertical display origins
- Spaces, fullscreen apps, sleep/wake, screen disconnect/reconnect
- Missing CLI, signed-out account, API-key account, missing quota, unsupported method
- Offline timeout, stale values, recovery, rapid refresh clicks, executable changes
- Quit during startup/read, after sleep/path changes, and repeated Quit; all outstanding owned reads must drain
- Reduce Transparency, Increase Contrast, VoiceOver labels, and dark hover surface on light wallpaper
- No unexpected permissions, login prompts, model tasks, or unowned-process termination

## Automated test coverage

Quota parser: multi-bucket precedence, legacy fallback, missing values, invalid values, arbitrary durations, signed-out/unsupported account types, stale threshold, and reset-pending behavior.

Geometry and motion: global coordinates, negative and vertical origins, invalid regions, missing notch, 1x/2x frame alignment, hover dwell/exit grace, interrupted spring motion and Reduce Motion.

Discovery: signed bundle identity and helper containment, renamed/registered applications, package metadata, CLI symlinks, unsigned rejection, bounded cancellation, and a separate read-only real official artifact test.

Transport: request allowlist, fragmented/multiple lines, oversized lines, error redaction, server-request classification, executable validation, synthetic subprocess handshake, timeout, early exit, cancellation, repeated/concurrent shutdown, and a SIGTERM-ignoring owned child.
