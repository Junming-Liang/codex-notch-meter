## Codex Notch Meter v1.0.2

### 中文

修复音乐状态下的外轮廓、无按键划过手势和展开抖动：

- 额度进度沿整个音乐黑色外壳绘制，紧凑封面、展开歌词和音乐详情共用同一轮廓。已用部分纯黑，保留五款皮肤；音乐详情不再重复显示内部横向进度条。
- 快速从左向右划过顶部可以打开匹配歌词，反向划过关闭。补充只读鼠标事件观察和跨采样边缘判断，避免漏掉快速轨迹；不新增辅助功能或屏幕录制权限。
- 手势完成后，指针继续移到邻近或下方不会被普通悬停抢走状态，避免突然放大成详情又缩回。离开整个外壳后重新悬停，仍可正常查看详情。
- 暂停、恢复及设置暂时隐藏时，配件宽度与外壳共用同一帧驱动，避免布尔尺寸跳变。保留默认小封面/播放指示、歌词 B 布局、额度提示优先及2/4/6秒停留。

- 修复额度通知设置 6 秒却一闪即逝的路径：普通鼠标移入移出不再抢占提示，慢绘制会重试而非在 250ms 后撤销；2/4/6 秒从稳定绘制确认后开始计算。保留未变化读取不撤销提示，新变化按自身已捕获时长重新显示。

### English

Fixes the music perimeter, button-free pointer gestures, and unstable expansion:

- One shared shell draws the body and quota perimeter around compact playback, expanded lyrics and music details. Used quota stays black; all five skins remain. Music details no longer duplicate progress as interior horizontal bars.
- Fast left-to-right pointer crossings open eligible lyrics, and reverse crossings close them. Read-only mouse observation and segment-based boundary handling avoid missed samples without new Accessibility or Screen Recording permission.
- Natural adjacent/downward movement after a gesture no longer promotes the same interaction into full hover details. Leaving the full shell and returning still supports ordinary hover.
- Playback accessory width and expansion share the frame driver through pause/resume and temporary suppression. Compact artwork, the B lyric layout, quota-notice priority and the 2/4/6-second holds remain.

- Prevents configured six-second quota notices from flashing away: passive pointer movement cannot interrupt the notice, and slow paint retries instead of dismissing after 250ms. The 2/4/6-second hold starts after settled paint acknowledgment; unchanged reads retain the notice, while a new change receives its own captured dwell.

### Validation and limits / 验证与边界

This release is intended to be published only after its exact source passes macOS CI and its synthetic native PNGs are reviewed. Build-source metadata binds the packaged app to the commit, tree and workflow run; archive checksums identify the reviewed ZIP/DMG bytes. See the source-linked workflow and `docs/VALIDATION.md` for observed results, rather than treating this note as an unverified test receipt.

Native tests use original synthetic lyrics/artwork, injected playback and the app's own view captures. They do not access a user's account, Music library or screen. Passing them does not establish physical-display smoothness, all Music/TCC/streaming combinations, macOS 13 runtime, or real login/reboot behavior.

需要 macOS 13+，Universal DMG/ZIP 包含 Apple Silicon 与 Intel 二进制。仅 ad-hoc 签名，没有 Developer ID 签名或公证；macOS 可能阻止启动。本项目不提供绕过安全检查的指令。可选歌词与在线匹配仍默认关闭，LRCLIB 需要单独同意发送当前歌曲信息，社区歌词不等于 Apple 官方歌词。

Requires macOS 13+. Universal DMG/ZIP contains Apple Silicon and Intel binaries. Ad-hoc signed only, without Developer ID signing or notarization; macOS may block launch. No security-bypass instructions are provided. Optional lyrics and online lookup remain off by default; LRCLIB metadata sharing requires separate consent, and community lyrics are not Apple official lyrics.
