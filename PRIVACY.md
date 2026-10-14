# Privacy and security

## What the meter reads

The meter requests the account type and quota windows from an installed official Codex CLI using the documented app-server interface. An account response may contain identity fields; the meter's parser discards those fields and never logs or persists the raw response. Quota snapshots are held in memory only.

The meter does not open or parse credential files, access tokens, conversation history, session recordings, or private Codex databases. It does not use private HTTP endpoints or request any model generation, login, logout, token refresh, or configuration change.

## What the CLI may do

The installed `codex app-server` is a separate OpenAI program. It inherits the runtime environment and existing `CODEX_HOME`, and owns its normal authentication, credential refresh, logging, caching, configuration loading, and network behavior. The meter's read-only request policy is not a promise that Codex itself never accesses credentials or writes files. Review the official CLI's policies and configuration separately.

The app does not read Codex stdout except for its own protocol connection. Subprocess stderr is discarded. User-facing errors contain fixed explanations and numeric error codes, never raw account or provider messages.

## Local preferences

The app stores only the overlay preference, selected quota-group identifier, and optional Codex executable path in macOS UserDefaults. It does not persist quota values, account names, emails, tokens, or reset history.

## Permissions and network

No telemetry, analytics, remote reporting, embedded web login, automatic updates, launch-at-login registration, Accessibility access, Screen Recording access, or global keyboard hooks are implemented. The meter has no HTTP client. Its Codex subprocess may contact OpenAI to retrieve current quotas.

## Subprocess boundary

The production code sends only `initialize`, `initialized`, `account/read` with `refreshToken: false`, and `account/rateLimits/read`. It terminates its own child on completion, timeout, cancellation, sleep, and app shutdown. A bounded fallback force-terminates only that same owned Process if it ignores normal termination. It never enumerates or kills other Codex processes.

Responses are bounded to 1 MiB per line and 4 MiB per connection. Unexpected server requests close the read-only connection. A selected custom executable runs with your user permissions; choose only the official CLI you installed and trust.

## Reporting problems

Do not attach credentials, raw account responses, chat history, or private configuration to public issues. Report your macOS version, CPU architecture, Codex CLI version, sanitized error code, and steps to reproduce. Quota values and screenshots may reveal usage patterns; review them before sharing.
