<div align="center">
  <img src="docs/assets/icon.svg" width="88" height="88" alt="Codex Notch Meter logo" />
  <h1>Codex Notch Meter</h1>
  <p><strong>Codex allowance and Apple Music lyrics, at the top of your Mac.</strong></p>
  <p>Native macOS · Read-only quotas · Optional lyrics</p>
  <p><a href="https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.0.1/CodexNotchMeter-1.0.1-universal.dmg">Download Universal DMG</a> · <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.0.1/CodexNotchMeter-1.0.1-universal.zip">Alternative ZIP</a> · <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v1.0.1">Release notes</a> · <a href="README.md">简体中文</a> · <a href="https://github.com/Junming-Liang/codex-notch-meter/issues">Report an issue</a></p>
</div>

## Overview

A small SwiftUI and AppKit menu-bar utility. A fine contour follows the MacBook notch; hover for remaining quota, the next reset date, and a countdown. Displays without a notch use the menu bar.

The meter reads the official Codex CLI's account interface. It sends no model prompts, starts no conversations, and does not collect chat history.

**v1.0.1 formal release.** Each app session starts closed; fresh playback can show tiny artwork. Move the pointer fully left-to-right across the top band without pressing a button to open lyrics; reverse to close. Pause hides lyrics, and quota notices take priority. Recovery and interaction-delayed quota notices are also repaired. [Beta 1](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v1.0.0-beta.1) and the quota-focused [v0.1.9](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.9) remain available.

Display handling uses runtime bounds and capabilities, with menu-bar fallback for non-notched, external-only, closed-lid and mirrored configurations. Hosted native gates passed; the [coverage matrix](docs/COMPATIBILITY.md) distinguishes synthetic evidence from physical-device validation. The automatic curve is a documented approximation, not a measured profile for every panel.

## Apple Music lyrics

- Each app session starts closed; fresh playback can show tiny artwork and a state indicator; missing artwork uses a neutral placeholder without a network fetch
- A complete no-button left-to-right crossing of the fixed top band opens matched lyrics; reverse to close. Ordinary hover still shows quotas
- Left-aligned current text, a subdued actual next cue and a small title; no usable current lyric means no empty expanded card
- Pause, stop, track changes and stale playback hide old lyrics. Resume restores the selected mode only after fresh usable lyrics return
- Quota notices take priority for the selected 2/4/6-second hold, then return to the selected eligible mode; hover can retain ordinary quota details
- Local LRC/text import and separately consented LRCLIB community matching; Music support and online matching both default off
- Exact lookup followed by bounded candidate search; known film/TV attribution suffixes may normalize, while live/remix/cover/language recording distinctions remain
- Temporary network failures and confirmed no-match results stay distinct; coverage and streaming compatibility remain limited

See [Enable lyrics](#enable-lyrics-optional) below and the [lyrics integration contract](docs/MUSIC-LYRICS.md).

## Download

1. Download the [v1.0.1 Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.0.1/CodexNotchMeter-1.0.1-universal.dmg) and optional [SHA-256 checksum](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.0.1/CodexNotchMeter-1.0.1-universal.dmg.sha256)
2. Open the DMG and drag **Codex Notch Meter.app** to **Applications**
3. Launch the installed copy from Applications, then eject the DMG

An alternative [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.0.1/CodexNotchMeter-1.0.1-universal.zip) and [checksum](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.0.1/CodexNotchMeter-1.0.1-universal.zip.sha256) are available. Extract the complete `.app` into Applications.

For an upgrade, quit the previous version before replacing the `.app`.

Universal packages contain Apple Silicon and Intel binaries. The release workflow requires synthetic tests, universal packaging, retained quota/pixel/motion checks, lyrics lifecycle checks, official-helper discovery and DMG inspection. Each archive has a separate SHA-256 checksum. Exact final source, observed results and evidence limits are recorded in [validation status](docs/VALIDATION.md).

**Signing:** published builds are ad-hoc signed, without an Apple Developer ID or notarization. macOS may block downloaded builds, so launch on every Mac cannot be guaranteed. The project provides no Gatekeeper-disable or security-bypass commands. Building from source is an alternative. No paid Apple developer account is required.

## Features

- Remaining quota shown as `100 − usedPercent`: one left-anchored full-U prefix, with a pure-black consumed right suffix
- Select the notch quota window, defaulting to the shortest known duration; all windows remain in the expanded card
- Mint, Rainbow, Aurora, Sunset and Ice skins; Rainbow has optional 8s/12s color motion and a shared maximum-15fps clock
- Window labels derived from actual returned duration, with multiple quota groups
- Real `NSScreen` notch geometry, global coordinates, display changes and a menu-bar fallback
- Content-fit wrapped details and numeric-change-only feedback; initial, unchanged, failed and metadata-only reads stay silent, with a setting to disable notices
- Notice Hold settings: Short 2s / Standard 4s / Long 6s, default 4s from the fully expanded painted state; hovering holds details open
- Percentage-point decreases require fresh comparable account/window/reset context; numeric changes across a reset use reset wording without claiming consumption
- Continuous top-attached expansion with hover dwell, exit grace, reversible motion and Reduce Motion support
- Visible Quit in the expanded island, menu bar and Settings; local `⌘Q` when the app is active
- Restrained graphite cards, system typography, selectable skins, accessible state text and reduced-transparency support
- Opt-in Launch at Login with actual macOS status and approval-required guidance
- Launch/wake/manual refresh, 60-second polling, hover debounce and error backoff
- Explicit unknown, last-known, stale and reset-pending states; reset time alone never refills the bar
- No Dock icon, automatic login item, global key hooks, Accessibility or Screen Recording permissions

## Connect Codex

Requires macOS 13+ and the official Codex desktop application or [official CLI](https://learn.chatgpt.com/docs/cli), already signed in with a ChatGPT account that provides subscription quota windows. API-key billing is not represented as subscription allowance.

Discovery first checks LaunchServices and standard application directories for the official desktop bundle, independent of its filename. It validates the bundle identifier, OpenAI signature, version metadata and known helper layout, then falls back to PATH/Homebrew. Settings can select the official `.app` directly or a trusted CLI. Unknown layouts and invalid signatures fail closed. Cold full-signature verification can take time and has a 30-second overall limit; UI and Quit remain responsive. See [desktop discovery](docs/DISCOVERY.md) for the inspected official version and helper path.

The child inherits the runtime environment, including existing `CODEX_HOME`. The meter does not mutate Codex configuration. For terminal-only environment variables, launch the app executable from that terminal. Sign in through Codex itself, then refresh.

The current native interface is primarily Simplified Chinese. Right-click the menu-bar item for Refresh, Settings and Quit. Ordinary Quit waits for owned account-reading subprocesses to be cleaned up.

## Enable lyrics (optional)

1. Open Music yourself and play a track. Enable “Apple Music 歌词与播放指示” (lyrics and playback indicator) in Settings.
2. Read the explanation and choose whether to grant Music Automation access. The app reads the current song, position and available artwork; it does not control playback.
3. Import a local UTF-8 LRC/text file for the current track, or separately enable LRCLIB online matching.
4. Once a usable lyric is available, cross the top band fully left-to-right without a mouse button; reverse to close. Each app session starts closed. Pause and track changes retain the choice, while old text clears immediately.

Online matching sends title, artist, album and duration to `lrclib.net`, without Apple account data, tokens or quota values. Local imports are not uploaded. Community lyrics are not Apple's official lyrics; text without timestamps is labeled unsynced. Temporary failures follow backoff and retain their status. Not every song has a reliable match.

## Startup and appearance

After copying the app into Applications, open Settings to request Launch at Login. macOS may require approval or reject the ad-hoc signature; actual login/reboot behavior remains unverified. No enrollment happens automatically.

Display settings select the skin, motion, speed and primary quota. Mint is static by default. Rainbow changes color inside the true remaining arc and pauses for Reduce Motion, sleep, low power or hidden/disabled surfaces.

For a remaining physical offset, use Horizontal Adjustment in the same section: minus moves left, plus moves right, in 0.5pt steps. It starts at zero and includes Reset. Corrections stay local to each built-in display; system safe areas are not precise measurements of the physical edge.

## Quota states

| State | Meaning |
| --- | --- |
| Solid rail | Remaining quota; numbers are always available in the card |
| Black contour / em dash | Unknown or unavailable; zero has no colored fill, details distinguish the state |
| Last reading / stale | Retained historical data, not a live allowance |
| Reset pending | Reset time passed; awaiting a successful fresh response |
| Demo badge | Synthetic data; no Codex process is running |

Dates use the Mac's local time zone. Timeouts and disconnections retry after 15/30/60/120/300 seconds; other errors retain conservative backoff. Manual refresh and wake can retry sooner. Retained values show their last-success age. A fresh recovery change in an eligible matching quota window may show a current-value update without claiming verified consumption across the failed interval.

An unchanged refresh does not dismiss or restart an existing notice. While interaction blocks delivery, only the latest change waits, bounded by the original 180-second receipt/read freshness and a reset-not-due check. Initial reads and failures themselves stay quiet.

## Privacy

The quota protocol operations are `initialize`, `initialized`, `account/read` with `refreshToken: false`, and `account/rateLimits/read`. The app starts its own short-lived `codex app-server` subprocess, then closes and awaits it.

No model work, login/logout, credential-file parsing, conversation/session reads, private HTTP endpoints, telemetry, raw account logs, or persistent quota history. UI/skin preferences, lyrics toggles, quota-group selection and an optional executable path are stored locally. Optional lyrics use public Apple Events to read the already-running Music app. Only separate online consent permits the listed song fields to reach LRCLIB. Lyrics and playback state stay in memory and are cleared when disabled or stopped.

Codex itself owns its normal authentication, refresh, logging, caching and network behavior. The meter's read-only request policy is not a promise that the CLI never reads or writes its own files. Read [PRIVACY.md](PRIVACY.md).

## Build

Xcode Command Line Tools and Swift 5.9+ are required. No third-party Swift package dependencies.

```sh
git clone https://github.com/Junming-Liang/codex-notch-meter.git
cd codex-notch-meter
swift test
bash Scripts/build-app.sh
open "dist/Codex Notch Meter.app"
```

Universal app, archive and checksum:

```sh
bash Scripts/build-app.sh --universal
```

Offline interface demo:

```sh
swift run CodexNotchMeter --demo
```

## Development

`NotchCore` contains parsing, state, geometry and read-only transport. `CodexNotchMeter` contains native UI and lifecycle code.

```sh
python3 Scripts/check-source.py
swift test
```

Tests use synthetic data and local fake subprocesses; no account, credentials, Codex installation or network is required. The manually dispatched workflow uses standard GitHub-hosted runners. Verify the applicable Actions cost/storage conditions before running it.

See [CONTRIBUTING.md](CONTRIBUTING.md). Never post credentials, raw account responses or private configuration in issues.

## Limitations

Lyrics come from local files or the LRCLIB community, not Apple’s official lyrics. Coverage, Music Automation and streaming combinations cannot be guaranteed; a user’s successful beta report does not establish cross-device compatibility.

The Codex account interface evolves. Native CI cannot validate a physical notch, real hover/focus behavior, external displays or a live account. Ad-hoc builds are not notarized. Force quit, crashes and power loss are outside orderly-shutdown cleanup guarantees. See the [acceptance checklist](docs/VALIDATION.md).

## Design and license

Visual principles are inspired by the Linear, Raycast and Apple entries in [VoltAgent / awesome-design-md](https://github.com/VoltAgent/awesome-design-md). UI, icon and implementation are original; no brand assets or code were copied. [Design notes](docs/DESIGN.md).

[MIT](LICENSE). Independent project, not affiliated with or endorsed by OpenAI or Apple. Product names belong to their respective owners.
