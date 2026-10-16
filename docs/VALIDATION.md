# Validation status

Observed results are pinned to the exact tested source below, not automatically to later documentation-only commits on `main`.

## v1.0.0 optional lyrics candidate: native validation pending

The current source adds default-off, read-only Music.app sampling, a separately consented LRCLIB lookup, bounded local LRC/text import and a lyric row inside the existing scrollable detail content. The quota protocol, refresh frequency, contour geometry/stroke and motion remain unchanged.

Local source/syntax checks and installer safety simulations can be run without macOS. New pure fixtures cover original LRC text/timeline, metadata validation, bounded read/cancellation and provider policy. The new native fixture injects every IPC/network/file boundary, checks actual own-view lyric pixels, track/permission/stale lifecycle, picker revision, quota-notice priority and Quit layout. All retained native and package gates still apply. These Swift/native tests have not yet executed for this candidate; no pass is claimed here.

[Diagnostic run #32](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38870524289) did not reach native validation: the build job rejected an assumed `Music.sdef` resource path, and the separate official job found a throwing cancellation assertion inside a nonthrowing synthetic transport. The repair reads the declared `OSAScriptingDefinition` filename or extensionless basename, falling back only to one bounded direct `.sdef` resource when the key is absent. Missing, dynamic, ambiguous, linked, oversized or invalid dictionaries still fail; no OSA extraction or app launch is used. The declaration handling follows [Apple’s property-list key](https://developer.apple.com/documentation/bundleresources/information-property-list/osascriptingdefinition) and [extensionless-name documentation](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/conceptual/ASLR_script_objects.html), checked 2026-10-16. Twenty synthetic discovery/safety fixtures pass locally. The cancellation fixture now catches and checks the exact cancellation error without changing the production transport. Native compile and runtime results remain pending.

A separate read-only CI step inspects Music's installed public scripting dictionary and property codes. It does not launch Music, request Automation, read a music library or contact a lyrics provider. Actual Music/TCC behavior, provider availability/content correctness, macOS-version streaming compatibility and physical appearance remain unverified. See [the integration and safety contract](MUSIC-LYRICS.md).

## v0.1.9 observed notification compatibility results

[Diagnostic run #30](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38864370658) and [release run #31](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38865243130) passed on 2026-10-16. The immutable release tag points to [`4dbfe2e9faa8dfa5283869603326176f7e20cc77`](https://github.com/Junming-Liang/codex-notch-meter/commit/4dbfe2e9faa8dfa5283869603326176f7e20cc77), tree `8fe431a77cdaf3a43060a86513f75fccb8902ef5`.

The prior notice tracker suppressed every change when the optional rate-limits account identity was unavailable. Schema-compatible synthetic responses reproduced quota values updating without a notice. The user's raw account response was not inspected, so this is a verified failure path rather than a proven diagnosis of their exact response.

Fresh, ordered, preexisting matching windows can now produce a generic current-value notice when identity or optional duration/reset metadata is unavailable on both readings. It never claims consumption or a comparison interval. Known identity switches, one-sided optional-field changes, initial/recovery reads, failures, stale/replayed/future data and unchanged values still break or suppress comparison. Fully verified same-account/window/reset continuity retains percentage-point deltas. No discovery, quota request, polling, geometry, stroke or motion change was made.

The parser-to-tracker tests cover absent/null/malformed identity, optional window fields, fractional changes, reset/increase cases, secondary-only changes, mixed-window presentation and source/error boundaries. A synthetic owned-process pipe test also parses an identity/metadata-free response. Native parser-to-notice-to-paint cases passed for both unavailable identity and unavailable window metadata, displaying current remaining `79.875` with `consumptionClaim=false`.

Run #30 detailed evidence passed 213 synthetic tests plus one opt-in skip, a separate official helper test, universal builds/plist/ad-hoc signature, all native smoke/skin/stroke/alignment/motion/close/update/display gates, 21 installer safety simulations and actual read-only DMG inspection. Run #31 repeated the unchanged-source workflow successfully; its update, DMG and release checksum receipts were read directly. Release-run painted 2/4/6-second holds measured 2.252/4.069/6.085 seconds. These are hosted synthetic results, not live-account or physical-device confirmation.

The earlier Run #29 passed the notice and other native gates but correctly rejected an outdated `0.1.8` installer version pin. The strict package check was retained, the active version metadata was synchronized to `0.1.9` / build `10`, and source preflight now rejects missing, duplicate or conflicting active version pins. Both final runs passed the real installer gate.

### Download identity

- [Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.9/CodexNotchMeter-0.1.9-universal.dmg): 1,778,145 bytes; advertised SHA-256 `eabaccc488f8c075d84a11a4eb12f0a9399df47c4a2946637bc69ebd662c8581`
- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.9/CodexNotchMeter-0.1.9-universal.zip): 1,753,337 bytes; advertised SHA-256 `a7ead27a1fea321f185318be7c386c5fcc10172541d5a394b660ea334d74725c`
- Both separate checksum files are 102 bytes. Public asset identity and gated release checks agree; no independent downloaded-byte rehash is claimed.

The preview remains ad-hoc signed and unnotarized. Actual login/reboot, macOS 13 runtime, physical notch behavior and the user's notification outcome remain unverified here. Historical results below apply only to their named versions.

## v0.1.8 observed notice and shared-paint results

[Release run #28](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38845967956) passed on 2026-10-16. The immutable release tag points to [`2ef62ff647a02683f27f797fd4c421ffcb828e54`](https://github.com/Junming-Liang/codex-notch-meter/commit/2ef62ff647a02683f27f797fd4c421ffcb828e54), tree `c76260321435176ee186514ce904dde55b97f78c`.

Only fresh, comparable numeric changes create a notice. Initial, unchanged, failed and metadata-only reads are silent; a changed secondary window is selected instead of showing an unchanged primary. A changed reset-cycle value uses reset wording rather than a consumption claim. Settings persist Short 2s / Standard 4s / Long 6s, default 4s, separately from motion duration. Native tests passed all three real holds from fresh full-size paint, replacement and duplicate-ID behavior, hover priority, Reduce Motion, retired callbacks and preference isolation.

The unchanged v0.1.7 body and full-U rail now draw in one synchronous Canvas from the same immutable geometry/progress frame. Gradient coordinates, grouped opacity, accessibility, calibration, shape and 3.5pt color / 4pt black widths are preserved. Actual paint-callback checks and separate native 1x/2x paired-side pixels passed, including a displaced-rail negative control and comparison with the prior composition.

The reference-informed critically damped motion reached 99% of open/close travel in 0.3986–0.4177s on the hosted runner. Callback p95 was 25.59ms for the view display link and 27.72ms for the dispatch fallback; sampled view-update lag was zero in both. Reversal preserved position/velocity. These are callback/view observations, not display FPS, compositor scanout, an exact DynamicNotchKit spring or a physical smoothness guarantee.

Run #27 failed two native test oracles: Reduce Motion had already painted idle before a later inspection demanded another paint, and view-update age could include a settled frame's idle time. The two-file harness repair uses the scheduled expiry boundary and the first request replacing the acknowledged frame, with fail-closed history controls and the unchanged 120ms lag limit. Run #28 passed; its raw and corrected lag were both zero, so it does not retrospectively establish the cause of the specific Run #27 fallback sample.

All required workflow gates passed: 202 synthetic tests plus one opt-in official-artifact skip in that job, a separate successful official test, universal builds/plist/ad-hoc signature, native smoke/skins/stroke/alignment/motion/close/update/display, 21 installer safety simulations, read-only DMG inspection and archive checksums. CI uses synthetic quota data, never enrolls login items and never executes the downloaded official helper.

### Download identity

- [Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.8/CodexNotchMeter-0.1.8-universal.dmg): 1,769,352 bytes; advertised SHA-256 `741a95380a8219681dd1ad78a6050515041d36ae05db6f887289fd6806b20385`
- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.8/CodexNotchMeter-0.1.8-universal.zip): 1,744,836 bytes; advertised SHA-256 `dea5bf4fae63219c200ed5d467569f672a0f9b2a9009023946c539d22c957b71`
- Both separate checksum files are 102 bytes. Public asset identity and gated release checks agree; no independent downloaded-byte rehash is claimed.

Physical fit/feel, human PNG review, actual macOS 13 runtime and real login/reboot remain unverified. Forced 2x captures are offscreen scale evidence. The preview remains ad-hoc signed and unnotarized; macOS may block it. Historical results below apply only to their named versions.

## v0.1.7 observed thicker-contour results

[Release run #26](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38753274566) passed on 2026-10-15. The immutable release tag points to [`13d54b278a18173dec57c2a9d44f5a2bfb43f128`](https://github.com/Junming-Liang/codex-notch-meter/commit/13d54b278a18173dec57c2a9d44f5a2bfb43f128), tree `40b7b202b42595e26b2c6784b3d8837b91a573cd`.

Only contour paint width changed: color 2.5→3.5 pt and black backing 3.5→4 pt. The shared circular centerline, clipping silhouette, frame, calibration and quota trim are unchanged. There is no white stroke in the production rail; this improves coverage without claiming that the user's physical white-fringe cause was reproduced.

The native gate passed all 100 distinct paired records: five skins × full/half/quarter/zero/unknown × 1x/2x × two lower corners. Fixed raw-input normal bands measure alpha/background contribution separately from chromatic coverage. The old-width control is rejected by the same acceptance predicate, and both references and current views must have the expected opaque colored/black core. Existing transparency, four-point paint envelope and full-U fraction checks remain unchanged.

For the standard full-quota left corner at 1x, mean inner-band alpha increased from 0.5296 to 0.7482 and background contribution fell from 0.4704 to 0.2518; chromatic coverage increased from 0.2164 to 0.3363. These are native own-view offscreen measurements, including light/dark composites, not a physical-notch screenshot or a model-specific fit guarantee.

All retained required workflow gates passed, including unit/process tests, universal packaging, signature, native smoke/pixels/alignment/motion/close/update/display, official helper inspection and mounted DMG verification. No login item was registered and no account was used in CI.

- [Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.7/CodexNotchMeter-0.1.7-universal.dmg): 1,652,431 bytes; advertised SHA-256 `e4ebf4d56846b85ec37a21794d5f70abcb757cec8c41ba0bf519677c0324f099`
- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.7/CodexNotchMeter-0.1.7-universal.zip): 1,627,303 bytes; advertised SHA-256 `2c2b8692b1a0db269e7ce1355c23070070b3767515b23184e05452eb8c5de3e0`
- Both separate checksum files are 102 bytes. Public asset identity and gated release checks agree; no independent downloaded-byte rehash is claimed.

Ad-hoc/unnotarized signing and the physical fit, human PNG inspection, actual macOS 13 and login/reboot limits below remain applicable.

## v0.1.6 observed macOS results

[Diagnostic run #24](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38728721178) and [release run #25](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38730063651) passed on 2026-10-15 using standard hosted `macos-15` runners.

- Tested source and immutable release tag: [`629caa3c73c0a2284cc1fc3ce724dec90fc5cd97`](https://github.com/Junming-Liang/codex-notch-meter/commit/629caa3c73c0a2284cc1fc3ce724dec90fc5cd97)
- Source tree: `fd418a890755687b68bf1e1f6b303acac3f4f080`
- XCTest: 187 discovered, 186 synthetic tests passed, one opt-in official-artifact test skipped in that job, zero failures; the separate official test passed without executing its helper
- Universal arm64/x86_64 builds, Info.plist, ad-hoc signature, four native smoke/color-clock/Quit scenarios, five skins' 240 scene/scale pixel checks and 21 installer safety simulations: passed
- Actual read-only mounted DMG app-byte/architecture/signature/Applications-link/cleanup checks and both release checksum gates: passed

Detailed scene counts and timings below come from the fully reviewed Run24 receipts. Run25 repeated the same gated workflow successfully on the identical source, with release/tag/asset checks verified; an independently read complete Run25 pixel transcript is not claimed.

### Automatic contour, compact feedback and display handling

The rail and connected black body now share a circular contour, using runtime exclusion bounds and a documented open-source reference. This is an automatic approximation, not a manufacturer radius table. The [Apple-sourced coverage matrix](COMPATIBILITY.md) records the macOS 13+ boundary and 216 synthetic layouts; model names do not select runtime coordinates.

The production capability planner/reconciler passed synthetic native lifecycle injection: valid built-in displays only, unchanged-controller reuse, selective retirement, fresh bounded topology retries, identity/calibration isolation and suspension/teardown. Actual physical clamshell, mirroring, Spaces and scaled-mode transitions are not established by injected snapshots.

Native alignment passed 102 scale captures and 21 expanded Quit/routing checks, including width/depth/corner corrections, fractional origins, reset and rejected old-rounding controls. The corrected footer remains inside its strict 304pt viewport. All five skins retain the full-U left remaining prefix, pure-black consumed suffix and calibrated 1x/2x transparency/arc/phase gates.

Compact wrapped details and passive refresh feedback passed intermediate-target, 2s/0.8s hold, immediate hover promotion, coalescing, stale-expiry rejection, Reduce Motion, deferred content fit and measured Quit checks. Numeric decreases require fresh matching transient account identity, window/duration and reset cycle; only the existing rate-limits response supplies that identity, which is never persisted or displayed. Other states do not invent consumption, and refresh frequency is unchanged.

### Closing and motion evidence

Run20 exposed competing progress/viewport callbacks that left a stale nonzero view observation after the native frame reached idle. One coherent observation repaired that hosted failure. Run24's five skin paths plus dispatch fallback acknowledged fresh zero in approximately 14.5–16.8ms, within the unchanged 120ms readiness deadline. Actual retirement and final display cost are separately recorded; a blocked main loop can service a timeout later.

Separate own-view replay passed 138 captures, ten moving-rail/late-tail gates and 20 side-axis checks. The same tight positional predicate constrains actual terminal frames and rejects a 1pt translated viewport; missing rail, opaque rectangle and abrupt replacement controls are also rejected. These captures are not display scanout or proof of physical perceived smoothness.

Run24 measured callback p95 of 18.52ms for the view display link and 19.72ms for the dispatch fallback under synthetic UI load. Actual frame/presentation, continuous reversal and retired-source checks passed. These are callback measurements, not claimed display FPS. The fallback ran on the hosted newer OS, not actual macOS 13.

The unsuccessful intermediate runs were retained as evidence: Run21 exposed a test-only scalar overload; Run22 exposed fractional footer overflow and obsolete rectangle/whole-image test assumptions; Run23 exposed a synthetic pointer below the negatively corrected contour. Each was repaired without loosening the actual timing, terminal-paint or containment limits.

### Download identity

- [Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.6/CodexNotchMeter-0.1.6-universal.dmg), advertised SHA-256 `f57bc52eab135c619f5b45eb6aa5e511e3ba841a480a74da491918e9871b08d0`
- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.6/CodexNotchMeter-0.1.6-universal.zip), advertised SHA-256 `3563d27bb8ef60a6f8ffd6e968508e843404bb97960d120e3c227c1f18efff67`
- Both separate checksum files are 102 bytes. Release checksum checks and public metadata agree; no independent downloaded-byte rehash is claimed.

**Limits:** ad-hoc signed and unnotarized; actual login registration/reboot, macOS 13 hardware, physical model-by-model fit/smoothness, cross-application click delivery and human PNG inspection remain unverified. Forced 2x rendering is offscreen evidence, not a physical Retina test. The user previously reported successful live quota reads; CI uses no account. See [design attribution and approximation](DESIGN.md).

## v0.1.5 observed macOS results

[Diagnostic run #17](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38692547654) and [release run #18](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38693787318) passed on 2026-10-15 using standard hosted `macos-15` runners.

- Tested source and immutable release tag: [`be65833128d7ccd7e512857e3e4df3e54f4f0e9a`](https://github.com/Junming-Liang/codex-notch-meter/commit/be65833128d7ccd7e512857e3e4df3e54f4f0e9a)
- Source tree: `d3e2dd200076d1f19357d0ec53fa9efc8da290a0`
- XCTest: 103 discovered, 102 synthetic tests passed, one opt-in artifact test skipped in the synthetic job, zero failures
- Separate official signed-desktop helper discovery: passed without executing Codex; diagnostic resolution took 11.158 seconds within the unchanged 30-second budget, with clean detach
- Universal arm64/x86_64 build, Info.plist and ad-hoc signature checks: passed
- Four native smoke/color-scheduler/Quit scenarios with 28 resumed publications, all five skins' 240 scene/scale checks, 70 alignment captures and 13 expanded calibration checks: passed
- New three-profile native motion, presentation, reversal and cleanup gate: passed
- 21 installer safety simulations, read-only mounted DMG inspection/cleanup and release ZIP/DMG checksum gates: passed

### Hover-motion evidence

The user reported insufficiently smooth hover motion. Source review identified forced synchronous display/layout and first-expansion detail construction as costs to measure; it did not prove the cause of that user's experience. The previous spring already retained velocity. The new exact critically damped solver removes cadence-dependent integration and discarded elapsed time, while immediate mid-collapse reentry preserves current position and velocity.

The native harness compares the previous synchronous drawing/layout strategy, the new display-linked path and the macOS 13 dispatch fallback under the same four-bucket/eight-window UI load and new spring. Diagnostic run #17 measured:

| Strategy | Callback p95 | Maximum callback gap | Apply p95 |
| --- | ---: | ---: | ---: |
| Previous run-loop Timer drawing strategy | 64.754 ms | 80.216 ms | 5.037 ms |
| View-bound display link | 19.231 ms | 20.508 ms | 3.633 ms |
| Coalescing dispatch fallback | 21.894 ms | 42.664 ms | 5.257 ms |

The two new paths passed unchanged timing bounds, actual native-frame checks, and 67/72 active layer-presentation samples respectively. Sampled SwiftUI view-update lag was zero; this is a view-update observation, not a display scanout measurement. Near-boundary chatter, post-grace reentry, fresh event-time integration/velocity continuity, repeated expansion, measured Quit routing, duplicate/backward timestamps, and retired-source cleanup passed. A held presentation expires at most 100 ms after its replacement, with controls rejecting expired or impossible sizes. Bitmap checks run separately from timing.

Full details stay mounted in a non-sizing clipped overlay, and all collapsed transparency/footprint gates remain required. One progress drives surface, rail and detail reveal. Geometry sources stop at settlement/teardown; the macOS 13 fallback uses a main-queue strict dispatch source with 1 ms leeway and no process power assertion. The independent rainbow clock remains capped at 15 fps.

[Initial run #16](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38691184031) exposed approximately 83 ms p95 gaps in both ordinary Timer profiles despite low apply cost. The successful replacement supports the scheduler change without proving App Nap was responsible. Its presentation-history oracle was also corrected to age a predecessor from replacement, rather than from when a long-held settled frame was created. No cadence limit was loosened.

This is an old-drawing-strategy comparison using the same new spring, not a full old-binary benchmark. The runner's actual backing was 1x; forced 2x captures are offscreen scale checks. Actual macOS 13 runtime, physical-display smoothness/alignment, human PNG inspection and real login/reboot remain unverified. The user previously reported successful live quota reads in v0.1.1; CI uses synthetic accounts and does not inspect that account. The preview remains ad-hoc signed and unnotarized.

### Download identity

- [Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.5/CodexNotchMeter-0.1.5-universal.dmg): 1,132,527 bytes; advertised SHA-256 `c242a30b1438fe40bdf8e835418702e77ccd877218e3cdb212e6965294450c02`
- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.5/CodexNotchMeter-0.1.5-universal.zip): 1,126,048 bytes; advertised SHA-256 `aea51f4a1acbad8dd197baa6f1e8521afbadd53202c896d27974627435bcee2c`
- Both separate checksum files are 102 bytes. Workflow checksum verification and public asset metadata agree; no independent downloaded-byte rehash is claimed.

API references: Apple's [view-bound display link](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)), [macOS 14 AppKit release notes](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14), [frame display behavior](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:)), [deferred window display](https://developer.apple.com/documentation/appkit/nswindow/display()), [strict timer leeway](https://developer.apple.com/documentation/dispatch/dispatchsource/timerflags) and [dispatch-source event coalescing](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html).

## v0.1.4 observed macOS results

[Diagnostic run #14](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38682562047) and [release run #15](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38683231675) passed on 2026-10-15 using standard hosted `macos-15` runners.

- Tested source and immutable release tag: [`0306d0e163603f5333e0cd790b19655486b47b27`](https://github.com/Junming-Liang/codex-notch-meter/commit/0306d0e163603f5333e0cd790b19655486b47b27)
- Source tree: `fa76cb3050b6ba998b766a07991359fcd5435a2e`
- XCTest: 92 discovered, 91 synthetic tests passed, one opt-in artifact test skipped in the synthetic job, zero failures
- Separate official signed-desktop discovery: passed without executing Codex; diagnostic-run resolution took 10.519 seconds within the unchanged 30-second budget
- Apple Silicon and Intel builds, universal packaging, Info.plist and ad-hoc signature verification: passed
- All four native motion/Quit/scheduler scenarios, all five skins' 240 collapsed scene/scale checks, 21 installer safety simulations and actual read-only DMG inspection/cleanup: passed
- Both release checksum gates: passed

### Raw-edge alignment and calibration evidence

The user reported slight horizontal offset in v0.1.3. Source audit identified a bounded rounding mechanism: independently rounding both auxiliary edges can move their midpoint by up to half a backing pixel. The supplied photograph and screenshot cannot establish an exact physical offset or prove this accounts for the whole observed difference.

Version 0.1.4 preserves raw system-reported camera exclusion bounds. Only the transparent native window envelope is pixel-aligned; the visible rail, fill and clip use exact local rectangles. Optional per-built-in-display calibration starts at zero, uses 0.5pt steps up to ±8pt, respects screen bounds and can be reset. Public display UUIDs remain local; demo fixtures never persist them.

The new native own-view gate passed 70 scale captures: 68 normal alignment/recollapse records and two rejected, actually rendered old-rounding controls. Independently supplied raw edges plus known correction are the oracle for chroma-weighted pixel-center stroke axes and mirrored lower corners. Inputs include off-center, odd/even/fractional edges and 0/±0.5/±8pt corrections. All 13 expanded detail/Quit/routing checks passed, including final reset to zero. Synthetic preference checks passed for two display identities, reorder, changed bounds, stored-value Reset and unchanged saved preferences.

In diagnostic run #14, maximum measured midpoint error was 0.0500pt at calibrated offscreen 1x and 0.00658pt at 2x. The recreated old edge-rounded contour was displaced by −0.25pt in the targeted synthetic fixture and correctly rejected. The actual hosted window reported **1x backing**; the 2x bitmap is explicit offscreen-scale evidence, not a physical Retina test. Fractional-size capture calibration preserved the view's bounds, rounded only the bitmap canvas upward, and verified its drawing transform.

Synthetic geometry tests additionally cover positive/negative global origins, raw midpoint preservation, invalid calibration and bounded expansion. Existing quota direction, pure-black consumed suffix, five skins, motion, discovery, DMG and login-safety behavior remains covered. Account requests and skin behavior are unchanged apart from version metadata.

### v0.1.4 release artifacts

- [Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.dmg): 1,060,193 bytes; [checksum file](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.dmg.sha256): 102 bytes
- GitHub-advertised DMG SHA-256: `fc11d924a0e8bc397c1ea191e2c7cf940eb7ee7b06062a0e83fc5e3a037ba34a`
- [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.zip): 1,051,659 bytes; [checksum file](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.zip.sha256): 102 bytes
- GitHub-advertised ZIP SHA-256: `a29c28a4b8299ea27e222fd685bfdc44dfb342d1e8bb28715534c79ed9c87c38`
- Release checksum gates and public asset metadata were verified. Downloaded asset bytes were not independently rehashed here.

**Limits:** no precise cause or universal correction is inferred from the physical photo. Physical MacBook alignment, actual Retina behavior and human PNG review remain unverified. The user previously reported successful quota reads; CI uses no live account. Ad-hoc signing only, without Developer ID or notarization; macOS may block opening or login-item registration. Actual registration, system approval and login/reboot behavior remain unverified.

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

[v0.1.0](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.0) and its immutable assets remain available for history. Its [run #4](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/38536308482) passed 32 synthetic tests and a simpler native startup check, but did not inspect the actual notch panel or desktop-bundle discovery. Users subsequently reported desktop discovery, placement and hover/Quit-usability defects. Prefer the current v0.1.9 preview.

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
