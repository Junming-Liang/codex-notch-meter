# Validation status

Observed results are pinned to the exact tested source below, not automatically to later documentation-only commits on `main`.

## v0.1.4 candidate — native results pending

The user reported slight horizontal offset in v0.1.3. Source audit identified a bounded rounding mechanism: independently rounding both auxiliary edges can move their midpoint by up to half a backing pixel. The supplied photograph and screenshot cannot establish an exact physical offset or prove this accounts for the whole observed difference.

The candidate preserves raw system-reported camera exclusion bounds. Only the transparent native window envelope is pixel-aligned; the visible rail, fill and clip use exact local rectangles. Optional per-built-in-display calibration starts at zero, uses 0.5pt steps up to ±8pt, respects screen bounds and can be reset. Public display UUIDs remain local; demo fixtures never persist them.

New synthetic geometry cases cover off-center, odd/even/fractional coordinates, positive/negative origins, raw midpoint preservation, signed/reset/invalid calibration and bounded expansion. A new native own-view gate measures full-mint vertical stroke axes from chroma-weighted pixel-center centroids against independently supplied raw edges plus known correction, checks mirrored lower corners, and rejects an actually rendered old-rounded-edge control. It logs actual native backing separately from calibrated 1x/2x offscreen contexts. Live synthetic preference tests cover two display identities, reorder, changed bounds, stored-value Reset and unchanged saved preferences.

All existing five-skin, quota-direction/black-tail, motion, Quit, desktop discovery, DMG and login-safety gates remain required. New native execution is pending; no physical alignment or screenshot inspection claim is made. This version does not change account reads or skin behavior apart from version metadata.

## v0.1.3 observed macOS results

[Diagnostic run #12](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38671460345) and [release run #13](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38672374256) passed on 2026-10-15 using standard hosted `macos-15` runners.

- Tested source and immutable release tag: [`b2f7d5e053f585db2cc9c22d6eee19d7c2d01c6b`](https://github.com/Junming-Liang/codex-notch-meter/commit/b2f7d5e053f585db2cc9c22d6eee19d7c2d01c6b)
- Source tree: `32ff9dd1b63e538e29c2da18084602aefc894cdd`
- XCTest: 83 discovered, 82 synthetic tests passed, one opt-in artifact test skipped in the synthetic job, zero failures
- Separate official signed-desktop artifact test: passed; diagnostic-run production discovery took 10.05 seconds within the unchanged 30-second budget, without executing Codex
- Apple Silicon and Intel builds, universal archive, Info.plist and ad-hoc signature verification: passed
- Four demo-only native window, geometry, motion, Quit and orderly-shutdown scenarios: passed
- 21 installer safety simulations: passed; native subprocesses mocked in these simulations

### Full-U skins and native motion evidence

The selected quota window, or shortest returned known duration by default, drives one continuous upper-left → bottom → upper-right path. Remaining is a left prefix; the consumed suffix is pure black. Zero/unknown render no colored marker or gray line. All quota rows remain available in the expanded card.

All five skins passed the calibrated 1x/2x own-view pixel suite. Each skin has 48 collapsed scene/scale checks covering 0/25/50/75/83/100, unknown, stale/reset-pending, live quota-window selection, live theme switching/restoration and color phases. Transparent interior/corners, the nominal 3pt / maximum 4pt envelope, true arc boundary and pure-black unused suffix are checked independently. Reversed fill, old opposed halves, a gray tail, center gap, missing progress and solid rectangle negative controls are rejected. Rainbow color changes while its quota boundary stays fixed; other skins remain static.

The production color scheduler passed actual native cadence, seven synthetic lifecycle pause reasons, resume, notification-burst and retired-timer checks in all four scenarios. In diagnostic run #12, all 28 resumed first publications arrived within 0.180 seconds, below the 1-second test bound. The initial run's harness checked at the first 0.2-second inspection callback; it was repaired to inspect the actual first publication timestamp and tick/count changes without altering production scheduling or loosening cadence/freeze requirements.

### Login and installer evidence

Native smoke compiled and read the real `SMAppService.mainApp.status` API (`notFound` in this runner). Synthetic state tests cover approval, cancellation, failures, external revocation and install-location guidance. Demo/CI mutation calls remained zero: no real registration, removal, System Settings launch, account login or reboot occurred.

The actual generated DMG passed read-only mounting, exact mounted app-byte comparison, version/Info.plist, arm64 + x86_64 and ad-hoc signature verification, literal `/Applications` link inspection, UDZO integrity and owned-device detach/temporary-directory cleanup. It never executed the mounted app. Both archive checksum gates passed before release.

### v0.1.3 release artifacts

- [Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.3/CodexNotchMeter-0.1.3-universal.dmg): 983,322 bytes; [checksum file](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.3/CodexNotchMeter-0.1.3-universal.dmg.sha256): 102 bytes
- GitHub-advertised DMG SHA-256: `d979859d2786f3f2c7a79e3ce2c930bd753221757bc21b19ffd32b8a85654f80`
- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.3/CodexNotchMeter-0.1.3-universal.zip): 972,989 bytes; [checksum file](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.3/CodexNotchMeter-0.1.3-universal.zip.sha256): 102 bytes
- GitHub-advertised ZIP SHA-256: `0c47c26ab82aa7d297a3c4d57ff68f6cbe12d344106a2f1be9ce0dca29c142a0`
- Release workflow checksums and public asset metadata were verified. Downloaded asset bytes were not independently rehashed here.

**Limits:** ad-hoc signing only, no Developer ID or notarization. macOS may block opening or login-item registration. Actual registration, system approval and login/reboot behavior remain unverified. Native pixel evidence is calibrated offscreen rendering, not physical Retina or human PNG review. Physical notch interaction remains unverified; the user reported successful v0.1.1 quota reads, while CI uses no live account.

## v0.1.2 observed macOS results

[Diagnostic run #9](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38567762579) and [release run #10](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38569117126) passed on 2026-10-14 using standard hosted `macos-15` runners.

- Tested source and immutable release tag: [`97a6eba71fd3fdad5a14d952cd2a68ccd3ad49aa`](https://github.com/Junming-Liang/codex-notch-meter/commit/97a6eba71fd3fdad5a14d952cd2a68ccd3ad49aa)
- Source tree: `de6877aeaf63ff468ea1227e67b2d2240cfd50d0`
- XCTest: 54 methods discovered, 53 synthetic tests passed, one opt-in artifact test skipped in the synthetic job, zero failures
- The real official signed-desktop artifact test passed separately; release-run helper discovery completed in 10.10 seconds within the unchanged 30-second production budget, without executing Codex
- Apple Silicon and Intel builds, universal archive, Info.plist, ad-hoc signature and release checksum checks: passed
- All three existing native geometry/motion/Reduce Motion/Quit/shutdown scenarios: passed

### Native contour evidence

The production root now matches its actual 226×35pt native host around a synthetic 220×32pt cutout, with a 3pt external envelope. The collapsed interior and lower corners are transparent; only the contour is drawn. A native diagnostic fixture of the old hidden-detail layout measured a 340×512pt silhouette inside a 232×39pt host, with no visible colored contour pixels. This reproduces the suspected layout mechanism; it is not an inspection of the user's running binary.

The new own-view harness updates the same live published model through full/83%/25%/0/unknown/stale/reset-pending/mixed values, expansion, and recollapse. Both calibrated 1x and 2x drawing contexts passed exterior arc samples, transparent corners/interior, colored/neutral tracks, exact repeat-update and recollapse comparisons. Per-rail fixed-area alpha-aware dimming passed; unchanged-data controls were rejected. Solid-black-rectangle and missing-progress negative controls were also rejected. Full-size 380×512pt expansion and usable Quit remain covered by native checks.

The first diagnostic run exposed a biased test metric that averaged only pixels above a chroma threshold. It was corrected to compare the identical exterior pixel population per rail, without changing production appearance or relaxing the dimming threshold.

Synthetic own-view PNGs and labeled light/dark cutout composites are retained for seven days in the workflow's `CodexNotchMeter-native-contour-evidence` artifact. They are not desktop captures or physical Retina evidence. Review here used source and native numeric results; **no human PNG inspection or physical MacBook visual approval is claimed**. Private user screenshots are never repository files or artifacts.

### v0.1.2 release artifact

- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.2/CodexNotchMeter-0.1.2-universal.zip): 816,024 bytes
- [SHA-256 file](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.2/CodexNotchMeter-0.1.2-universal.zip.sha256): 102 bytes
- GitHub-advertised ZIP SHA-256: `ccb42906772cf6d755df4c41242add6a3bd103bdf0fdedc16dab13559bfd09d4`
- The workflow verified the ZIP checksum before publication. The downloaded asset bytes were not independently rehashed in this workspace.
- Ad-hoc signed developer preview; no Developer ID or notarization. macOS may block it.

The user reported successful v0.1.1 quota reads on their Mac, alongside the collapsed appearance defect. Account discovery and reading behavior are unchanged in v0.1.2 apart from client version metadata. CI uses no live account; physical v0.1.2 appearance and interaction still need user verification.

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

- Actual login-item registration, system approval and launch after login/reboot

- Physical MacBook notch placement, Retina behavior, real hover/focus/click delivery, full-screen Spaces and multi-display interactions
- Independent live-account validation: the user reports successful v0.1.1 quota reads, but CI uses no account
- Actual native screenshots and visual acceptance

The 1x/2x unit geometry cases are mathematical checks, not physical Retina evidence. Official artifact discovery proves that the inspected helper can be found and verified, not that a real account provides quota data.

## Historical v0.1.0

[v0.1.0](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.0) and its immutable assets remain available for history. Its [run #4](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38536308482) passed 32 synthetic tests and a simpler native startup check, but did not inspect the actual notch panel or desktop-bundle discovery. Users subsequently reported desktop discovery, placement and hover/Quit-usability defects. Prefer v0.1.3.

The v0.1.1 diagnostic rounding failure was measured and repaired. It should not be described as a proven explanation of every original physical-device v0.1.0 symptom.

## Manual acceptance checklist

Use `--demo` first, then an account only with its owner's permission.

- Notched MacBook: the full-U contour tracks the actual notch, including scaled resolutions
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

Geometry and motion: global coordinates, negative and vertical origins, invalid regions, missing notch, 1x/2x frame alignment and odd/fractional collapsed envelopes, hover dwell/exit grace, interrupted spring motion and Reduce Motion.

Discovery: signed bundle identity and helper containment, renamed/registered applications, package metadata, CLI symlinks, unsigned rejection, bounded cancellation, and a separate read-only real official artifact test.

Transport: request allowlist, fragmented/multiple lines, oversized lines, error redaction, server-request classification, executable validation, synthetic subprocess handshake, timeout, early exit, cancellation, repeated/concurrent shutdown, and a SIGTERM-ignoring owned child.
