# Privacy and security

## What the meter reads

The meter requests the account type and quota windows from the installed official Codex desktop helper or CLI using the documented app-server interface. An account response may contain identity fields; the meter's parser discards those fields and never logs or persists the raw response. Quota snapshots are held in memory only.

The meter does not open or parse credential files, access tokens, conversation history, session recordings, or private Codex databases. It does not use private HTTP endpoints or request any model generation, login, logout, token refresh, or configuration change.

## Installed-app discovery

Automatic desktop discovery reads LaunchServices application registration and bounded `Info.plist` / `codex-package.json` metadata inside installed application bundles. It checks the OpenAI bundle identifier and Apple-anchored signing team for both the application and executable. Known helper paths must remain inside the application after symlink resolution. It does not launch the desktop GUI, scan private Codex data, or modify any app bundle.

A single background resolver handles metadata/signature checks. Its caller has a six-second timeout and cancellation-aware wait; an abandoned read-only check can never launch Codex or update quota state. Explicit CLI paths and PATH/Homebrew remain supported. User-selected executables run with the user's permissions and must be trusted.

## What the CLI may do

The installed `codex app-server` is a separate OpenAI program. It inherits the runtime environment and existing `CODEX_HOME`, and owns its normal authentication, credential refresh, logging, caching, configuration loading, and network behavior. The meter's read-only request policy is not a promise that Codex itself never accesses credentials or writes files. Review the official CLI's policies and configuration separately.

The app does not read Codex stdout except for its own protocol connection. Subprocess stderr is discarded. User-facing errors contain fixed explanations and numeric error codes, never raw account or provider messages.

## Local preferences

The app stores only the overlay preference, selected quota-group identifier, and optional Codex executable path in macOS UserDefaults. It does not persist quota values, account names, emails, tokens, or reset history.

## Permissions and network

No telemetry, analytics, remote reporting, embedded web login, automatic updates, launch-at-login registration, Accessibility access, Screen Recording access, or global keyboard hooks are implemented. The meter has no HTTP client. Its Codex subprocess may contact OpenAI to retrieve current quotas.

The island reads only the current pointer position while its overlay is enabled, to apply hover delays and ignore mouse events outside the revealed content. It does not record pointer history, monitor keys, install an event tap, or request input-control permissions. Polling and animation timers stop on sleep, display removal, overlay disable, and Quit. Routing flags are tested on hosted macOS; real cross-application click-through still needs physical interaction validation.

## Subprocess boundary

The production code sends only `initialize`, `initialized`, `account/read` with `refreshToken: false`, and `account/rateLimits/read`. It cleans up its own child after completion, timeout, cancellation, and sleep. During orderly app shutdown, it waits for all outstanding reads, including canceled reads, to confirm their owned children have exited. Force quit, crashes and power loss are outside this guarantee. A bounded fallback force-terminates only that same owned Process if it ignores normal termination. It never enumerates or kills other Codex processes.

Responses are bounded to 1 MiB per line and 4 MiB per connection. Unexpected server requests close the read-only connection. A selected custom executable runs with your user permissions; choose only the official CLI you installed and trust.

## Reporting problems

Do not attach credentials, raw account responses, chat history, or private configuration to public issues. Report your macOS version, CPU architecture, Codex CLI version, sanitized error code, and steps to reproduce. Quota values and screenshots may reveal usage patterns; review them before sharing.
