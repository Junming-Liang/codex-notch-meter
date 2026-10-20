## Codex Notch Meter v1.1.2

### 中文

v1.1.2/build 19 是音乐交互与播放读取修复的候选版本，尚未完成原生 macOS CI 和用户实机验收，不能据此认定问题已解决。

- 原生鼠标事件与定时轮询共用有界的音乐手势悬停占用，避免两条输入路径交替重置识别器时，无限续期占用额度悬停。
- 普通悬停允许累计不超过 3 点的微小移动，避免轻微抖动持续重置悬停计时；超过阈值后仍按移动重新计时。
- 将可选封面读取与必需的播放快照读取隔离，并使用独立、有界的封面缓存。保留封面展示、必需读取的 2 秒预算与原有 5 秒播放新鲜度边界，不延长有效期，也不新增 Music 权限。
- 保留暂停、快照过期、权限拒绝及跨曲切换的隐藏与失效边界。可选音乐与在线歌词匹配仍默认关闭；向 LRCLIB 发送歌曲信息仍需单独同意。

### English

v1.1.2/build 19 is a candidate for music-interaction and playback-reading fixes. Native macOS CI and acceptance on the user's Mac are pending; this candidate does not establish that the reported problems are resolved.

- Native pointer events and polling share one bounded music-gesture hover reservation, preventing source changes from indefinitely renewing a reservation that blocks quota hover.
- Ordinary hover tolerates up to 3 points of cumulative micro-movement so small jitter does not continually restart its timer. Movement beyond the threshold still restarts the timer.
- Isolate optional artwork reads from required playback-snapshot reads, with an independent, bounded artwork cache. Retain artwork, the 2-second required-read budget and the existing 5-second playback-freshness boundary; do not extend freshness or request new Music permissions.
- Preserve hiding and invalidation boundaries for pause, stale snapshots, denied permissions and track changes. Optional Music and online lyric matching remain off by default; sending track metadata to LRCLIB still requires separate consent.

### Validation and limits / 验证与边界

原生 CI、对应最终源代码的构建与测试、合成图片人工审核，以及绑定 build 19 和源代码的 ZIP/DMG 核验均须完成后才能发版。Linux 上的脚本或核心测试不能替代 macOS 验证。实际 Music/TCC、流媒体及用户实机行为尚未验证；模拟读取与合成手势不能证明这些场景已修复。不得沿用旧版本的验收结果作为本版证据。

Release requires native CI, build and tests for the final source, human review of synthetic images, and source-bound ZIP/DMG verification for build 19. Script or core tests on Linux do not replace macOS validation. Real Music/TCC, streaming and user-device behavior remain unvalidated; mocked reads and synthetic gestures do not prove those scenarios are fixed. Prior-version acceptance is not evidence for this candidate.

需要 macOS 13+；计划的 Universal DMG/ZIP 包含 Apple Silicon 与 Intel 二进制。仅 ad-hoc 签名，无 Developer ID 签名或 Apple 公证；macOS 可能阻止启动。请勿关闭系统安全保护。

Requires macOS 13+. Planned Universal DMG/ZIP packages contain Apple Silicon and Intel binaries. Ad-hoc signed only, without Developer ID signing or Apple notarization; macOS may block launch. Do not disable system security protections.
