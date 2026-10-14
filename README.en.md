<div align="center">
  <img src="docs/assets/icon.svg" width="88" height="88" alt="Codex Notch Meter logo" />
  <h1>Codex Notch Meter</h1>
  <p><strong>Your remaining Codex allowance, quietly beside the MacBook notch.</strong></p>
  <p>Native macOS · Read-only quotas · No interruption</p>
  <p><a href="https://github.com/Junming-Liang/codex-notch-meter/releases">Download previews</a> · <a href="README.md">简体中文</a> · <a href="https://github.com/Junming-Liang/codex-notch-meter/issues">Report an issue</a></p>
</div>

## Overview

A small SwiftUI and AppKit menu-bar utility. Two fine rails follow the MacBook notch; hover for remaining quota, the next reset date, and a countdown. Displays without a notch use the menu bar.

The meter reads the official Codex CLI's account interface. It sends no model prompts, starts no conversations, and does not collect chat history.

This is a developer preview. Download only artifacts actually listed under [Releases](https://github.com/Junming-Liang/codex-notch-meter/releases). [Validation status](docs/VALIDATION.md) separately records native builds, synthetic tests, and physical-device checks.

## Download

1. Open [GitHub Releases](https://github.com/Junming-Liang/codex-notch-meter/releases) and choose the Universal ZIP
2. Extract **Codex Notch Meter.app** and move it to Applications
3. Launch it and open the menu-bar item

Universal packages contain Apple Silicon and Intel binaries. Publication is gated on macOS compilation, synthetic tests, universal packaging, and ad-hoc signature verification.

**Signing:** previews are ad-hoc signed, without an Apple Developer ID or notarization. macOS may block downloaded builds, so launch on every Mac cannot be guaranteed. The project provides no Gatekeeper-disable or security-bypass commands. Building from source is an alternative. No paid Apple developer account is required.

## Features

- Remaining quota shown as `100 − usedPercent`
- Window labels derived from actual returned duration, with multiple quota groups
- Real `NSScreen` notch geometry, global coordinates, display changes and a menu-bar fallback
- Restrained graphite cards, system typography, mint signals, accessible state text and reduced-transparency support
- Launch/wake/manual refresh, 60-second polling, hover debounce and error backoff
- Explicit unknown, last-known, stale and reset-pending states; reset time alone never refills the bar
- No Dock icon, automatic login item, global key hooks, Accessibility or Screen Recording permissions

## Connect Codex

Requires macOS 13+ and the [official Codex CLI](https://learn.chatgpt.com/docs/cli), already signed in with a ChatGPT account that provides subscription quota windows. API-key billing is not represented as subscription allowance.

Discovery checks `PATH` and common Homebrew locations. If needed, open Settings and choose the installed official `codex` executable you trust. The chooser can browse application packages, but the meter does not guess bundled paths. A Codex desktop installation alone does not guarantee a discoverable CLI.

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
