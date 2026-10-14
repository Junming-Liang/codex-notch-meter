# Validation status

This document distinguishes implemented checks from observed results. Update it only after running checks against the exact published source revision.

## Source-preparation checks

- Public-source safety preflight: passed in a Linux development environment
- Packaging script shell syntax: passed
- No third-party Swift package dependencies
- Test fixtures contain only synthetic data

## Awaiting macOS verification

- Swift compilation and the full XCTest suite
- Universal Apple Silicon + Intel `.app` packaging and ad-hoc signature verification
- Native UI behavior on a real notched MacBook
- Live quota reads against a signed-in official Codex CLI

No native build, UI run, screenshot, or live account check is implied by source-preparation checks. The manually dispatched macOS workflow can verify compilation, synthetic tests, universal packaging, and signatures without accessing a user's computer or account. A hosted runner cannot verify physical notch placement or real account behavior.

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
- No unexpected permissions, login prompts, model tasks, or unowned-process termination

## Automated test coverage

Quota parser: multi-bucket precedence, legacy fallback, missing values, invalid values, arbitrary durations, signed-out/unsupported account types, stale threshold, and reset-pending behavior.

Geometry: global coordinates, negative and vertical origins, invalid regions, missing notch, and pixel alignment.

Transport: request allowlist, fragmented/multiple lines, oversized lines, error redaction, server-request classification, executable validation, synthetic subprocess handshake, timeout, early exit, and cancellation.
