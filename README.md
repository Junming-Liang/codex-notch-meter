# Codex Notch Meter

Your remaining Codex allowance, quietly wrapped around the MacBook notch.

A small, native macOS menu-bar app built with SwiftUI and AppKit. Two thin progress rails follow the notch edges; hover to see remaining quota, the next reset date, and a live countdown. Displays without a notch use the menu bar.

[简体中文](README.zh-CN.md) · [Privacy](PRIVACY.md) · [Validation](docs/VALIDATION.md)

## What it does

- Shows **remaining** allowance: `100 − usedPercent`
- Labels each quota window using the duration returned by Codex, including 5-hour and 7-day windows when available
- Displays multiple quota groups and lets you choose which group appears around the notch
- Uses actual `NSScreen` safe-area and auxiliary-region geometry, in global screen coordinates
- Refreshes on launch, wake, manual request, and every 60 seconds; debounces hover checks and backs off after errors
- Keeps missing data unknown, marks failed/stale readings, and waits for real data after a reset time passes
- Offers a menu-bar fallback, an overlay toggle, executable selection, and a clearly labelled offline demo

No Dock icon, launch-at-login registration, global keyboard hooks, Accessibility access, or Screen Recording access.

## Requirements

- macOS 13 or later
- The **official Codex CLI**, already installed and signed in with a ChatGPT account that provides quota windows
- Xcode Command Line Tools / Swift 5.9 or later to build from source

API-key billing and other account types are not represented as subscription allowance. Codex desktop installation alone is not assumed to expose a discoverable CLI; install the official CLI separately or choose an existing official executable in Settings.

## Build and run

```sh
swift test
bash Scripts/build-app.sh
open "dist/Codex Notch Meter.app"
```

For an Apple Silicon + Intel app:

```sh
bash Scripts/build-app.sh --universal
```

The script creates an `.app`, a ZIP, and a SHA-256 checksum in `dist/`. It uses **ad-hoc signing**, without a paid Apple developer account. It does not Developer ID-sign or notarize the app. Downloaded developer-preview builds may be blocked by macOS security checks; building locally is the recommended preview route. This project does not provide security-bypass commands.

To inspect the interface with synthetic data, without starting Codex:

```sh
swift run CodexNotchMeter --demo
```

Demo mode is visibly labelled. No product screenshots or native-runtime success are claimed merely from a source build; see [validation status](docs/VALIDATION.md).

## Use

1. Launch the app. The menu-bar item always remains available.
2. Hover either notch rail, or click the menu-bar item, to view details.
3. Right-click the menu-bar item for Refresh, Settings, and Quit.
4. If Codex is not found, open Settings and choose the official `codex` executable you installed.

Executable discovery uses `PATH` and common Homebrew locations. The child process inherits the existing runtime environment, including `CODEX_HOME`; the meter never changes Codex configuration. If a terminal-only environment is important to your setup, start the app executable from that terminal.

A dimmed reading is last-known information. A dashed rail means unknown or unavailable. Reaching the displayed reset time does **not** refill the bar: the app waits for another successful account read. Reset dates use your Mac's local time zone.

## How quota access works

The app starts its own short-lived `codex app-server` subprocess and uses newline-delimited JSON over standard input/output:

1. `initialize`, then `initialized`
2. `account/read` with `refreshToken: false`
3. `account/rateLimits/read`
4. Close the owned subprocess

It prefers `rateLimitsByLimitId`, with a backward-compatible `rateLimits` fallback. It sends no prompts, starts no conversation threads or turns, performs no login/logout, and uses no private HTTP endpoint. Unexpected server requests are declined by closing the connection.

This is an evolving Codex protocol. Unsupported versions, unavailable quotas, signed-out accounts, timeouts, and offline errors are reported explicitly. Codex itself owns its authentication and may perform its normal credential refresh, logging, caching, or network activity. See [privacy details](PRIVACY.md).

## Development

No third-party package dependencies. `NotchCore` contains quota parsing, reset/staleness state, geometry, and a bounded read-only transport. The app target contains the macOS UI.

```sh
python3 Scripts/check-source.py  # static publication checks
swift test                       # synthetic data and local fake subprocesses
```

Tests do not require a Codex installation, credentials, network access, or an account. The GitHub Actions workflow is manually dispatched, uses a standard macOS runner, and uploads only build artifacts. Publishing source alone does not trigger a build. Verify your repository's applicable Actions billing before running it.

## Sources and scope

- [OpenAI Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Apple NSScreen safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)
- [Apple NSScreen auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc)
- [Apple NSPanel](https://developer.apple.com/documentation/appkit/nspanel)

Original implementation. Not affiliated with, endorsed by, or an official product of OpenAI or Apple. “Codex” and other product names belong to their respective owners.

## License

[MIT](LICENSE)
