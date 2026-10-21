# AMLL + LRCLIB fallback (unreleased candidate)

## Choice and privacy

Local LRC/text keeps precedence. LRCLIB remains primary with its existing opt-in and strict recording-duration checks. The new “使用 AMLL 作为备用歌词源” setting is independently default-off, including for existing LRCLIB users. Confirming it discloses title, artist and album transmission to api.amll.dev for current/future playback. Both network toggles must be enabled. No Apple account, credentials, Music persistent ID, public catalogue ID or imported file is transmitted to AMLL.

## Matching and limits

AMLL uses one documented compatible search at /v1/lrclib/search, pageSize=20, with title + artist + album. Its compatible fields contain only the first metadata value, so this conservative client can miss valid aliases. We require a nonempty album and exact title/artist/album after NFC, case and whitespace normalization. Punctuation, recording/version qualifiers and script differences remain identity-bearing. No title-only, artist-only, fuzzy-get, guessed catalogue ID or blanket punctuation substitution is used. Missing album skips AMLL rather than lowering confidence.

A full page is rejected because bare arrays cannot prove uniqueness; multiple matching records are rejected even when IDs duplicate. AMLL duration is its highest lyric timestamp, not recording duration: it is never compared for equality with the track duration. Timestamp/duration overflow, conflicting LRC metadata, malformed records and instrumental=true are rejected. Plain text is explicitly unsynchronized. A matching empty record is unavailable, not instrumental.

LRCLIB retains at most three requests per attempt; AMLL adds at most one. The existing controller allows at most three automatic attempts for transient errors and keeps cooldowns across track changes. Each request has a 10-second timeout and a 1 MiB streamed response limit; redirects, credentials, cookies and disk caches are disabled. AMLL 429/503 Retry-After is retained by its client. A fallback miss does not hide a primary outage. Primary identity/security failures are terminal, not a reason to broaden search. Successful fallback identifies its source as AMLL; existing failure UI distinguishes no-match, unavailable, service errors and mismatches.

Track identity, generation, playback revision, cancellation and local-import guards remain in the controller. Consent changes cancel pending work and clear retained online content. Imports win even if a network completion arrives later.

## Licenses and coverage

This app remains MIT. The AMLL API server offers MIT/Apache-2.0 software licensing (https://github.com/amll-dev/amll-ttml-api); this integration uses the public HTTP protocol, not copied server implementation. Neither that software license nor LRCLIB's software license grants blanket rights to community lyric text. No corpus is bundled, logged or persisted; tests use invented snippets only. Individual lyric rights and provider coverage remain uncertain.

Official contract: https://amll.dev/reference/http-api/overview and https://amll.dev/reference/http-api/lrclib (reviewed 2026-10-21). Mainland availability and coverage for any particular song are not established by implementing a second provider. Compatibility mode supplies line timing, not native TTML word rendering.

## Validation

AMLLLyricsLookupTests covers synthetic success, strict identity/edition matching, empty results, ambiguity/full-page rejection, timestamp bounds, malformed metadata, 503 vs no-match, consent/migration, primary/fallback success, error preservation, cancellation and cooldowns. The existing native Music harness now requires four controlled pending-AMLL boundaries: revoke AMLL, revoke all online lookup, replace the track, and complete a local import. It releases a noncooperative late fallback and verifies obsolete content cannot replace the current track/import; its receipt parser requires all four cases. Existing fixtures also cover paused/stale presentation. The legacy-consent unit test checks the preference-key default, not a real production defaults migration or visual confirmation dialog. Run swift test, source checks and universal macOS build before acceptance. This candidate was prepared in a Linux cloud shell without Swift or macOS SDK: static checks can run, XCTest/native build and visual settings checks are NOT yet verified. It has not been committed, pushed or released.

The candidate package defines AMLL_FALLBACK for its executable's new native fixtures. Historical red/green runs overlay only MusicRendering.swift onto a fixed old package without that define; conditional branches preserve the old controller initializer/API and keep unrelated historical red evidence valid. The normal candidate --music-test requires all four AMLL receipts; no workflow edit is part of this change.
