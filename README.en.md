<div align="center">
  <img src="docs/assets/icon.svg" width="88" height="88" alt="Codex Notch Meter logo" />
  <h1>Codex Notch Meter</h1>
  <p><strong>Your remaining Codex allowance, quietly beside the MacBook notch.</strong></p>
  <p>Native macOS · Read-only quotas · No interruption</p>
  <p><a href="https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.1/CodexNotchMeter-0.1.1-universal.zip">Download macOS Universal ZIP</a> · <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.1">Release notes</a> · <a href="README.md">简体中文</a> · <a href="https://github.com/Junming-Liang/codex-notch-meter/issues">Report an issue</a></p>
</div>

## Overview

A small SwiftUI and AppKit menu-bar utility. Two fine rails follow the MacBook notch; hover for remaining quota, the next reset date, and a countdown. Displays without a notch use the menu bar.

The meter reads the official Codex CLI's account interface. It sends no model prompts, starts no conversations, and does not collect chat history.

**v0.1.2 visual repair is under validation.** The user confirmed quota reads work in v0.1.1, but reported a black collapsed rectangle with invisible progress. The new candidate uses transparent backing and a thin rounded contour outside the notch; it will not release before the new native pixel gates pass.

## Download

1. Download the [v0.1.1 Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.1/CodexNotchMeter-0.1.1-universal.zip) (701,775 bytes) and optional [SHA-256 checksum](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.1/CodexNotchMeter-0.1.1-universal.zip.sha256)
2. Extract **Codex Notch Meter.app** and move it to Applications
3. Launch it and open the menu-bar item

For an upgrade, quit the previous version before replacing the `.app`.

Universal packages contain Apple Silicon and Intel binaries. This release passed synthetic tests, both architecture builds, packaging, Info.plist and ad-hoc signature verification, three native island regression scenarios, and read-only discovery against the official signed desktop distribution. Each archive includes a SHA-256 checksum file. Exact tested revisions and verification limits are recorded in [validation status](docs/VALIDATION.md).

**Signing:** previews are ad-hoc signed, without an Apple Developer ID or notarization. macOS may block downloaded builds, so launch on every Mac cannot be guaranteed. The project provides no Gatekeeper-disable or security-bypass commands. Building from source is an alternative. No paid Apple developer account is required.

## Features

- Remaining quota shown as `100 − usedPercent`
- Window labels derived from actual returned duration, with multiple quota groups
- Real `NSScreen` notch geometry, global coordinates, display changes and a menu-bar fallback
- Continuous top-attached expansion with hover dwell, exit grace, reversible motion and Reduce Motion support
- Visible Quit in the expanded island, menu bar and Settings; local `⌘Q` when the app is active
- Restrained graphite cards, system typography, mint signals, accessible state text and reduced-transparency support
- Launch/wake/manual refresh, 60-second polling, hover debounce and error backoff
- Explicit unknown, last-known, stale and reset-pending states; reset time alone never refills the bar
- No Dock icon, automatic login item, global key hooks, Accessibility or Screen Recording permissions

## Connect Codex

Requires macOS 13+ and the official Codex desktop application or [official CLI](https://learn.chatgpt.com/docs/cli), already signed in with a ChatGPT account that provides subscription quota windows. API-key billing is not represented as subscription allowance.

Discovery first checks LaunchServices and standard application directories for the official desktop bundle, independent of its filename. It validates the bundle identifier, OpenAI signature, version metadata and known helper layout, then falls back to PATH/Homebrew. Settings can select the official `.app` directly or a trusted CLI. Unknown layouts and invalid signatures fail closed. Cold full-signature verification can take time and has a 30-second overall limit; UI and Quit remain responsive. See [desktop discovery](docs/DISCOVERY.md) for the inspected official version and helper path.

The child inherits the runtime environment, including existing `CODEX_HOME`. The meter does not mutate Codex configuration. For terminal-only environment variables, launch the app executable from that terminal. Sign in through Codex itself, then refresh.

The current native interface is primarily Simplified Chinese. Right-click the menu-bar item for Refresh, Settings and Quit. Ordinary Quit waits for owned account-reading subprocesses to be cleaned up.

## Quota states

| State | Meaning |
| --- | --- |
| Solid rail | Remaining quota; numbers are always available in the card |
| Dashed rail / em dash | Unknown or unavailable, never assumed full |
| Last reading / stale | Retained historical data, not a live allowance |
| Reset pending | Reset time passed; awaiting a successful fresh response |
| Demo badge | Synthetic data; no Codex process is running |

Dates use the Mac's local time zone. Failed automatic checks back off to at most 15 minutes; manual refresh and wake can retry sooner.

## Privacy

The only production protocol operations are `initialize`, `initialized`, `account/read` with `refreshToken: false`, and `account/rateLimits/read`. The app starts its own short-lived `codex app-server` subprocess, then closes and awaits it.

No model work, login/logout, credential-file parsing, conversation/session reads, private HTTP endpoints, telemetry, raw account logs, or persistent quota history. Only UI preferences, quota-group selection and an optional executable path are stored locally.

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

The Codex account interface evolves. Native CI cannot validate a physical notch, real hover/focus behavior, external displays or a live account. Ad-hoc builds are not notarized. Force quit, crashes and power loss are outside orderly-shutdown cleanup guarantees. See the [acceptance checklist](docs/VALIDATION.md).

## Design and license

Visual principles are inspired by the Linear, Raycast and Apple entries in [VoltAgent / awesome-design-md](https://github.com/VoltAgent/awesome-design-md). UI, icon and implementation are original; no brand assets or code were copied. [Design notes](docs/DESIGN.md).

[MIT](LICENSE). Independent project, not affiliated with or endorsed by OpenAI or Apple. Product names belong to their respective owners.
