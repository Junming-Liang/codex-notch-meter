## Codex Notch Meter v1.1.1

### 中文

v1.1.1/build 18 是针对音乐手势回退和重复渲染工作的候选版本。macOS 原生验证和人工图片审核尚未完成，不能据此认定用户实机问题已修复。变更与验收范围如下：

- 向右划过尝试打开歌词时，若当前歌词不可用，释放本次失败打开对悬停的占用，让停留不动的鼠标重新进入普通额度悬停流程；已经打开的歌词失去展示资格时，也只释放这类失效的歌词打开占用。保留成功反向手势的语义和额度通知优先级。
- 封面未变化时复用一份已生成的 CGImage，歌词高度测量最多缓存两项，并按歌曲、文字布局条件、宽度和字体样式区分；避免每个动画帧重复生成相同资源，不保留无界历史。
- 相同的已发布展示字段不再重复发布，同时仍处理新播放快照、更新新鲜度与计时器，并保留暂停、失效、权限拒绝及跨曲切换的隐藏边界。
- 保留现有音乐动画轨迹、时序和尺寸；本版不声称动画体感已经更流畅，也不声称全部歌词缺失、Music 权限或流媒体问题已解决。
- 右侧播放指示改为轻微跳动的三条音频柱，仅表示播放状态，不分析音频或显示真实频谱。只在新鲜播放且图标可见时运行；暂停、过期、隐藏时停止，并尊重减少动态效果设置。动效局限于图标图层，不驱动整个窗口布局。
- 可选音乐与在线匹配仍默认关闭。向 LRCLIB 发送当前歌曲信息仍需单独同意，社区歌词不等于 Apple 官方歌词。

### English

v1.1.1/build 18 is a candidate targeting music gesture fallback and repeated rendering work. Native macOS validation and human image review are pending; these changes do not establish that the user's Mac is fixed. Changes and verification scope:

- When a rightward lyric-open gesture is rejected because lyrics are unavailable, release that failed open's hover ownership so a stationary pointer can resume ordinary quota hover. If an opened lyric presentation later loses eligibility, release only that lost lyric-open ownership. Preserve successful reverse-gesture behavior and quota-notice priority.
- Reuse one prepared CGImage while artwork is unchanged and cache at most two lyric-height measurements, distinguished by track, text-layout conditions, width and font style. Avoid recreating identical resources on each animation frame without retaining unbounded history.
- Deduplicate identical published presentation fields while continuing to process fresh playback snapshots, update freshness and timers, and preserve hiding boundaries for pause, invalidation, denied permission and track changes.
- Retain the existing music animation trajectory, timing and dimensions. This version does not claim improved perceptual smoothness or that all missing-lyrics, Music permission or streaming issues are resolved.
- The right-side playing indicator uses three gently moving bars to represent playback state, without audio analysis or a real spectrum. It runs only during fresh playback while visible, stops when paused, stale or hidden, and respects Reduce Motion. Animation stays within the icon layers rather than driving window layout.
- Optional Music and online matching remain off by default. Sending current-track metadata to LRCLIB still requires separate consent, and community lyrics are not Apple official lyrics.

### Validation and limits / 验证与边界

本候选版本仍须完成最终对应源代码的完整 macOS 工作流，包括新增手势红绿回归与缓存检查、全部既有门禁、34 张原生合成图片及回执的人工审核，以及绑定源代码和 build 18 的 ZIP/DMG 字节核验。先前版本的验证仅为历史记录，不能替代 v1.1.1 的验证。静态检查、合成事件及控制器测试均不能证明用户实机已修复，也不覆盖全部 Music/TCC/流媒体组合、macOS 13 运行或真实登录/重启。实际结果应记录在对应源代码的工作流与 `docs/VALIDATION.md` 中。

This candidate still requires the complete macOS workflow for the exact final source, including new gesture red-green regression and cache checks, every retained gate, human review of the 34 native synthetic images and receipts, and verification of the ZIP/DMG bytes bound to that source and build 18. Earlier versions' validation is historical evidence only and does not validate v1.1.1. Static checks, synthetic events and controller tests do not establish a user-device fix or cover every Music/TCC/streaming configuration, macOS 13 runtime or real login/reboot behavior. Record observed results in the source-linked workflow and `docs/VALIDATION.md`.

需要 macOS 13+；计划的 Universal DMG/ZIP 包含 Apple Silicon 与 Intel 二进制。仅 ad-hoc 签名，没有 Developer ID 签名或公证；macOS 可能阻止启动。本项目不提供绕过安全检查的指令。

Requires macOS 13+. The planned Universal DMG/ZIP contains Apple Silicon and Intel binaries. Ad-hoc signed only, without Developer ID signing or notarization; macOS may block launch. No security-bypass instructions are provided.
