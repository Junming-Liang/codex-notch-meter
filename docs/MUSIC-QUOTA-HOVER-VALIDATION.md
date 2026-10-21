# Music-shell quota hover regression

The closed music shell can be wider than the compact transition or the expanded quota contour's inset shoulders. For a 330-point notch, a stationary pointer at center +194 points and 16 points below the screen top is inside the closed shell but outside the expanded contour. Dynamic-only hit testing therefore alternates the existing 120ms entry and 220ms exit hysteresis without any pointer movement or Music failure.

The correction retains the closed music shell together with the current contour only while fresh music is playing and manual hover owns details. It does not enlarge click targets or the gesture corridor. A retained lyric-mode preference does not change this rule: expanded hover owns quota details, not the passive lyric presentation. Passive lyrics alone never enable the retained region. Leaving both regions closes normally; stopping playback removes the retained region.

## Checks

- `swift test --filter MusicQuotaHoverStabilityTests` exercises the real geometry, hover state and spring. It asserts repeated openings with the old hit-testing rule versus one stable opening with the new rule, on both sides and negative-origin displays. Calibration and narrow-notch controls, real exit and ordinary hover are covered.
- `python3 Scripts/check-native-music-quota-hover.py --red-green` archives exact baseline `17e3fef35ac89dda5588620009564558136270b6` and overlays only `MusicStationaryHoverChecks.swift`. The original executable must fail specifically at `wide-music-quota-settled`; unrelated errors do not count as red. It then runs the candidate app and validates the native success/cleanup receipts.
- The native case uses actual own-window event dispatch, the production timer, controller, owner, spring and paint. It requires a 2.4-second stable details hold with at least 30 polls and three playback reads, followed by real exit and pause-release checks. Playback and pointer location are synthetic. This is not physical mouse/global event delivery or real Music compatibility proof.
- The new parser and red-green command are connected to the main macOS workflow after packaging. Any build, intended-red, candidate, receipt or shutdown failure exits nonzero; no `continue-on-error` is used.

## Local preparation status

Source checks, diff whitespace checks, the new parser's ten self-test cases, Python syntax compilation and the existing stationary parser's 23 self-tests passed. Swift is not installed in the preparation environment. Swift unit tests, native red/green, universal build and user-Mac validation have not run. No remote push, CI dispatch or release was performed. This geometric counterexample matches the reported interaction but does not establish the user's exact notch dimensions or prove that every visible jitter has the same cause.
