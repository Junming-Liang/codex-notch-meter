# Validation status

This document distinguishes implemented checks from observed results. Update it only after running checks against the exact published source revision.

## v0.1.1 repair candidate

Native results for this candidate are pending. It adds desktop-helper discovery, a continuous top-attached island, prominent Quit actions, and a stronger regression gate. The source contains 51 synthetic XCTest methods, one separately opt-in official-artifact test, and three native smoke scenarios (normal, missing-helper/error, multiple quota groups). The smoke targets the actual island controller, checks ordered panel/content bounds and in-memory native drawing, exercises collapse/reentry and Reduced Motion, verifies Quit's measured bounds and mouse-routing flags, and checks dispatch/menu/local-command Quit paths. These checks do not establish cross-application mouse delivery or physical-notch correctness.

A separate, release-blocking macOS job downloads the official DMG with a 1 GiB / 120-second limit, mounts it read-only, and tests the production signature/helper resolver with its normal six-second deadline (the elapsed-time assertion allows 0.5 seconds of CI scheduling tolerance). It requires both a successful test exit and its discovery marker, never opens Codex or executes its helper, and detaches the volume afterward. The native build and geometry job runs independently, so download problems do not hide UI regression results. This positive artifact check is still pending for this candidate.

The v0.1.0 observations below are historical and do not validate this new candidate. v0.1.0 has reported desktop-discovery, placement and hover/quit-usability defects.

## Source-preparation checks

- Public-source safety preflight: passed in a Linux development environment
- Packaging script shell syntax: passed
- No third-party Swift package dependencies
- Test fixtures contain only synthetic data

## Observed macOS CI results

[Workflow run #4](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38536308482) passed on 2026-10-14 using the standard hosted `macos-15` runner. These observations apply to the tested source below, not automatically to later changes on `main`.

- Source: [`4d251aa8828b4f1ade876281acb5e21af98cdcdf`](https://github.com/Junming-Liang/codex-notch-meter/commit/4d251aa8828b4f1ade876281acb5e21af98cdcdf)
- Source tree: `501481cd1e5145c3931dd45192c27a56d04cb678`
- Swift compilation and 32 synthetic XCTest tests: passed, zero failures (Geometry: 5, Quota: 11, RPC: 16)
- Universal Apple Silicon (`arm64`) + Intel (`x86_64`) build and architecture check: passed
- `.app` Info.plist validation and ad-hoc signature verification: passed
- Universal ZIP packaging and release checksum gate: passed
- Real native demo Settings and quota-card startup/readiness plus orderly exit: passed in 3 seconds, within the 25-second watchdog

The smoke test uses only synthetic quota data and starts no Codex process. It exercises the actual native windows, not an HTML mockup, but does not capture screenshots or verify physical interactions.

## Published developer preview

[`v0.1.0`](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.0) is a prerelease bound to the tested source commit above.

- Archive: `CodexNotchMeter-0.1.0-universal.zip`
- Archive size: 576,520 bytes
- GitHub-advertised archive SHA-256: `a0dd27ea32f2b82cf615eb1c29a1451348b64554c96af758ce3af2c2bb785d4a`
- A matching `.zip.sha256` file accompanies the archive
- Signing: ad-hoc only; no Apple Developer ID signature or notarization

macOS may block downloaded builds. Successful hosted smoke execution does not guarantee that an unnotarized download opens on every Mac. The project provides no security-bypass commands.

## Still awaiting separate verification

- Actual notch placement, hover/focus behavior, full-screen Spaces and multi-display interactions on a real MacBook
- Live quota reads against a signed-in official Codex CLI
- Actual native UI screenshots and visual acceptance

A hosted runner cannot establish these results. Source review and synthetic tests are not substitutes for physical-device or live-account verification.

## Manual acceptance checklist

Use `--demo` first, then an account only with its owner's permission.

- Notched MacBook: left/right rails track the actual notch, including scaled resolutions
- Hover each rail, move into the detail panel, move away, repeat quickly
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

Geometry: global coordinates, negative and vertical origins, invalid regions, missing notch, and pixel alignment.

Transport: request allowlist, fragmented/multiple lines, oversized lines, error redaction, server-request classification, executable validation, synthetic subprocess handshake, timeout, early exit, cancellation, repeated/concurrent shutdown, and a SIGTERM-ignoring owned child.
