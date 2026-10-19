## Codex Notch Meter v1.0.3

### 中文

此候选版本针对 v1.0.2 安装后仍然抖动、无按键划过未触发，以及闭合音乐外壳过高的反馈。先前的合成验证没有证明这些实机问题已经解决；以下是本次修订范围，验证状态另列于后。

- 鼠标观察保留收到的 `NSEvent` 坐标和时间戳，避免用回调执行时的全局鼠标位置替换原始轨迹。轮询后备与事件样本分开处理，减少重复或过时采样干扰。
- 无按键划过覆盖完整的闭合高度；左向右选择可用歌词，反向关闭。普通悬停以累计位移和停留判断，移动中的指针及手势后的邻近移动不应立即抢占为详情。
- 闭合音乐状态与普通闭合状态保持相同高度，只横向加宽以容纳封面与播放指示；展开歌词和详情仍有各自高度。相机避让区域与可见外壳分别处理。
- 外壳、配件和额度轮廓使用同一几何/进度修订；保留 v1.0.0 的显示时钟、弹簧和先发布后调整窗口的顺序，不额外改变已知基线调度。
- 保留歌词 B 布局、五款皮肤、默认关闭的可选音乐/在线匹配，以及额度提示优先与已选 2/4/6 秒可读停留。

### English

This candidate addresses reports that v1.0.2 still jitters, misses button-free crossings, and makes the closed music shell too tall. Earlier synthetic validation did not establish that those physical-device issues were resolved. The changes under validation are:

- Preserve each observed `NSEvent` coordinate and timestamp instead of replacing its path with the global pointer position when the callback runs. Keep polling fallback separate from event samples to limit duplicate or stale input interference.
- Recognize button-free crossings throughout the closed shell's height: left-to-right selects eligible lyrics and the reverse closes them. Ordinary hover uses cumulative displacement and dwell, so a moving pointer or adjacent post-gesture movement should not immediately take over as details.
- Give closed music the same height as ordinary closed mode, with width added for artwork and the playback indicator. Expanded lyrics and details retain their own heights. Handle camera exclusion separately from the visible shell.
- Use one geometry/progress revision for the shell, accessories and quota perimeter while preserving v1.0.0's display clock, spring and publish-before-resize order, without adding a scheduler change to the established baseline.
- Retain the B lyric layout, all five skins, default-off optional Music/online matching, quota-notice priority and the selected 2/4/6-second readable holds.

### Validation and limits / 验证与边界

v1.0.3/build 16 is a candidate until the exact source passes the complete macOS workflow, the native images and receipts are reviewed, and the source-bound ZIP/DMG bytes are verified. At preparation time, native validation and publication are pending. The previous v1.0.2 run is historical evidence only; it is not a pass for v1.0.3 or proof of a user-device fix. Observed results belong in the source-linked workflow and `docs/VALIDATION.md`.

A separate native comparison runs the same synthetic controller-level input plan against the fixed v1.0.0 source and candidate for ordinary hover, steady music and playback changes. It preserves each version's own production geometry and behavior; v1.0.0 has no compact artwork wings or directional lyric mode. This comparison does not replace event-ingress verification or establish a perceptual jitter fix.

The added verification is intended to exercise the app's real local event-monitor entry through its own `NSApp.postEvent` queue, record motion-frame history, and compare ordinary/music closed-shell pixels at the active native backing scale with simulated camera masks, alongside 1x/2x geometry tests. These are synthetic own-app events, geometry and captures, not real user-pointer input, physical-notch measurements or GPU scanout. They do not establish every Music/TCC/streaming configuration, macOS 13 runtime, or login/reboot behavior. No user's Mac, account, Music library or screen is used by these fixtures.

v1.0.3/build 16 在对应源代码通过完整 macOS 工作流、原生图片和回执审核，以及绑定源代码的 ZIP/DMG 字节验证之前，均为候选版本。本文准备时，原生验证和发布尚未完成；v1.0.2 的历史验证不能视作本版通过，也不能证明用户实机问题已修复。新增验证计划从应用自身事件队列经过真实本地鼠标观察入口，并记录运动帧历史、比较当前原生显示比例下普通与音乐闭合像素及模拟相机遮挡，另以几何测试覆盖 1x/2x。它仍不等于真实鼠标输入、实物刘海测量或 GPU 扫描输出，也不覆盖全部 Music 权限/流媒体组合、macOS 13 运行及真实登录/重启。

另设同输入原生 A/B：固定 v1.0.0 源码与候选分别执行普通悬停、稳定音乐、播放变化三组控制器级合成计划。保留各版自己的生产几何和行为，不能给 v1.0.0 虚构封面侧翼或手势模式，也不能将这项比较当作真实事件入口或主观流畅度已经通过。

需要 macOS 13+，Universal DMG/ZIP 包含 Apple Silicon 与 Intel 二进制。仅 ad-hoc 签名，没有 Developer ID 签名或公证；macOS 可能阻止启动。本项目不提供绕过安全检查的指令。可选歌词与在线匹配仍默认关闭，LRCLIB 需要单独同意发送当前歌曲信息，社区歌词不等于 Apple 官方歌词。

Requires macOS 13+. Universal DMG/ZIP contains Apple Silicon and Intel binaries. Ad-hoc signed only, without Developer ID signing or notarization; macOS may block launch. No security-bypass instructions are provided. Optional lyrics and online lookup remain off by default; LRCLIB metadata sharing requires separate consent, and community lyrics are not Apple official lyrics.
