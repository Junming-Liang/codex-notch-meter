# 手动抖动诊断 / Manual jitter capture

This candidate adds observation, not another guessed jitter fix. Lyrics lookup,
AMLL/LRCLIB consent and quota behavior remain unchanged. It is not a claim that
physical jitter, native UI behavior or capture overhead has been validated.

## 在实机复现

1. 打开“设置 → 抖动诊断（默认关闭）”，点击“开始录制”。重新开始会替换内存里的上一份记录；先导出需要保留的记录。
2. **关闭设置窗口及菜单/弹出卡片再复现。** 设置可见时本来就会抑制音乐展示，不能保持此页打开来测音乐抖动。菜单栏的 `●REC` 表示录制仍在进行，不需要设置窗口保持打开。
3. 按正常操作播放 Music、划过或悬停刘海，尽量在 30–60 秒内复现一次。记下你看到抖动的大致顺序即可，不需要截图或录音。
4. 复现后，右键菜单栏图标，点击“诊断录制中 · 停止并导出…”。这会先停止，再打开 macOS 保存对话框。也可回设置点击“停止录制”，稍后“导出日志…”。
5. 检查保存的 `CodexNotchMeter-debug.jsonl` 后手动发送。应用不会自动上传，也不会替你提交 Issue。取消保存不会丢失内存中的日志；写入失败会显示明确提示，保留记录供重试。

录制最多 5 分钟，自动停止后右键仍可导出。活动记录仅在内存；退出应用会清除，已由你导出的文件不会被应用删除。启动不会恢复上次录制。保存操作在停止采集后执行，不承诺异步或零阻塞 I/O。

## Reproduce on the Mac

Start capture in Settings → jitter diagnostics, then **close Settings and all
menus/popovers**. A visible Settings window suppresses passive music presentation.
The menu-bar `●REC` remains visible outside Settings. Reproduce normally, then
right-click the menu-bar icon and choose Stop and export. Capture stops before
the native Save dialog. Cancel or a failed write retains the session for retry.
After the five-minute deadline, export remains available. Nothing uploads
without you manually sharing the exported file.

## Recorded and deliberately excluded

- Structured JSONL: schema/version/build, safe screen/notch dimensions and scale,
  calibration, chronological bounded state events, and counters/stop summary.
- Real production pointer ingress, hover decisions and fixed-anchor resets,
  owner/target transitions, music freshness and bounded failure categories,
  frame publication/apply durations, accessory/width-bridge changes, and
  settings/menu/popover gates. Source timestamps and actual observation times
  are separate. This does not add a new pointer poller or frame driver.
- Pointer/anchor positions only near the app's own expanded interaction area,
  relative to the notch, capped to ±1024 pt. Outside events have classifications
  and counts but no cursor coordinates. No complete desktop trajectory is stored.
- Random playback/notice/island identities become bounded session-local numbers;
  revision counters are relative to capture start. No stable display identifier
  or global screen origin is included.
- **Never recorded:** token, credentials, account responses, quota body/history,
  raw title/artist/album, lyrics, paths, window titles, other apps' windows,
  screenshots, audio, or browser content. Field keys and textual values are
  finite allowlists, not arbitrary model descriptions or error strings.

## Limits and timing interpretation

The serialized event ring is capped below 2 MiB and 4096 rows, with room reserved
for the schema, up to eight last-known safe geometry contexts, and summary. Old
rows are evicted; the summary counts evictions, sampling, rate limiting and invalid
fields. A five-minute file is **not** a complete five-minute trace. The latest
geometry context survives timeline eviction, but is context, not an ordered event.

High-frequency lanes are sampled at most 10 Hz per event type/island, with a hard
120 emitted rows/second cap across the session. `pollTick`, `pollIngress` and
`inputIngress` have separate lanes so event traffic cannot sample away all timer
observations. Local/global event counts remain separate, although their ingress
samples share a lane. State transitions are not intentionally sampled, but the
hard rate cap still applies. Always check drop counters before inferring absence.

- Row `elapsedMs`: actual monotonic recorder observation, not event enqueue time.
- `deliveredOffsetMs`: the clock read at the actual pointer callback/ingress.
- `sourceOffsetMs`: original mouse event timestamp (or admitted poll sample),
  relative to capture start. It can precede the capture; it is not delivery time.
- `decisionOffsetMs`: the exact clock passed to the actual `hover.update` call.
- `scheduledOffsetMs`: frame scheduler timestamp, not proof of display/scanout.
- `sourceAgeMs`: observer minus source timestamp; scheduled frames can be ahead.
- `rawPollGapMs`: consecutive timer-to-observer deliveries after the original
  stopped/placement/fixture guards, before the event-quiet guard. It does not
  observe callbacks rejected by those original guards. `eventGapMs` and
  `pollGapMs` at ingress instead refer to the previous **accepted** input.
- `pollCallbacks` counts those eligible timer-to-observer deliveries; `polls`
  counts pointer observer entry;
  `acceptedPolls` and `quietPolls` distinguish admitted samples and quiet guards.
- `recordWorkMs`, `maximumRecordWorkMs`, `measuredRecords`: measured accepted-row
  payload/encoding/ring cost. These exclude the caller, rejected-sample checks,
  Save I/O and display work. They are **not** an end-to-end overhead benchmark.

Encoding is synchronous on the main actor. Sampling and bounds limit work but
cannot prove that logging does not affect timing. Compare captures cautiously;
a gap alone does not distinguish main-thread stalls, timer delivery, event queues,
or compositor issues. No physical root cause is asserted by the synthetic fixture.

## Verification

Run existing checks unchanged, plus:

```sh
swift test --filter DebugCaptureTests
python3 Scripts/check-debug-capture.py --self-test
python3 Scripts/check-debug-capture.py --app "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter"
```

The native fixture uses injected Music data and synthetic pointer samples through
the real IslandPanelController, checks repeated music → details → music ownership,
production trace/privacy, no-Music capture/export, restart clearing, stop retention,
idle deadline and expiry/UI synchronization. It does
not use a real Music library, physical cursor/global delivery or scanout. The
separate existing native gates must still pass. Manual acceptance still needs
start/stop/restart, Save cancel/retry/error, five-minute expiry, menu state, and
capture with Settings closed, including accessibility appearance settings.

No native test/build result is claimed merely because a parser or static check
passes on Linux. Do not publish an installer before native validation and review.
