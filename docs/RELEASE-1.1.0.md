## Codex Notch Meter v1.1.0

### 中文

v1.1.0/build 17 针对歌词恢复与普通额度详情展开；正式交付以对应源码的原生验收和资产核验为准。变更与验收范围如下：

- 针对临时 Music 读取失败后的歌词恢复：仅在取得新鲜的播放快照、严格确认仍为同一首歌曲并满足歌词展示条件后恢复；不得用失败前的旧快照直接重新展示。
- 正常暂停、权限拒绝以及跨曲切换必须继续遵守隐藏与失效边界，不得把上一首歌的歌词带到下一首。此恢复范围不代表所有歌词缺失、Music 权限或流媒体问题都已解决。
- 仅普通无音乐悬停周期恢复 v1.0.0 的单段宽度节奏，保留现有展开尺寸、高度和已获认可的音乐手势路径；中途通知或播放接管使用同一帧时钟上的连续交接。本版仍需原生验收与用户实机反馈，不能把数值连续或高帧率当作体感已恢复。
- 保留默认关闭的可选音乐/在线匹配。LRCLIB 发送当前歌曲信息仍需单独同意，社区歌词不等于 Apple 官方歌词。

### English

v1.1.0/build 17 targets lyric recovery and ordinary quota-detail expansion. Delivery is conditional on native validation and asset verification for the exact source. Changes and verification scope:

- Recover lyrics after a transient Music read failure only after obtaining a fresh playback snapshot, strictly confirming the same track, and satisfying lyric-display eligibility. Do not redisplay directly from the pre-failure snapshot.
- Preserve hiding and invalidation boundaries for ordinary pause, denied permission, and track changes; previous-track lyrics must not carry into the next track. This recovery scope does not establish that all missing-lyrics, Music permission, or streaming issues are resolved.
- Restore the v1.0.0 single-stage width timing only for ordinary, non-music hover cycles, retaining the current expanded dimensions, height, and user-accepted Music gesture path. Mid-transition notice or playback takeovers use a continuous handoff on the same frame clock. Native validation and user-device feedback remain necessary; numerical continuity or frame rate does not establish perceptual smoothness.
- Optional Music and online matching remain off by default. Sending current-track metadata to LRCLIB still requires separate consent, and community lyrics are not Apple official lyrics.

### Validation and limits / 验证与边界

本版必须以最终对应源代码的完整 macOS 工作流、原生图片与回执审核，以及绑定源代码的 ZIP/DMG 字节核验作为后续发布依据。先前版本的验证仅为历史记录，不能替代 v1.1.0 的验证。静态检查、合成事件及控制器测试均不能证明用户实机已修复，也不覆盖全部 Music/TCC/流媒体组合、macOS 13 运行或真实登录/重启。实际结果应记录在对应源代码的工作流与 `docs/VALIDATION.md` 中。

Release readiness requires the complete macOS workflow for the exact final source, review of native images and receipts, and verification of the source-bound ZIP/DMG bytes. Earlier versions' validation is historical evidence only and does not validate v1.1.0. Static checks, synthetic events, and controller tests do not establish a user-device fix or cover every Music/TCC/streaming configuration, macOS 13 runtime, or real login/reboot behavior. Record observed results in the source-linked workflow and `docs/VALIDATION.md`.

需要 macOS 13+；计划的 Universal DMG/ZIP 包含 Apple Silicon 与 Intel 二进制。仅 ad-hoc 签名，没有 Developer ID 签名或公证；macOS 可能阻止启动。本项目不提供绕过安全检查的指令。

Requires macOS 13+. The planned Universal DMG/ZIP contains Apple Silicon and Intel binaries. Ad-hoc signed only, without Developer ID signing or notarization; macOS may block launch. No security-bypass instructions are provided.
