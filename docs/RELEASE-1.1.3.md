## Codex Notch Meter v1.1.3

### 中文

v1.1.3/build 20 包含音乐悬停稳定性修正和可选歌词补充源。仅在最终提交的完整 macOS 自动检查通过后发布，不覆盖旧版 1.1.2。

- 修正宽音乐翼缘进入额度展开轮廓时，静止指针可能因轮廓变化反复开合的问题；保留真实移出、暂停和播放新鲜度失效边界。
- 在线歌词继续优先使用 LRCLIB；AMLL 是独立开关、默认关闭的可选补充源，需要单独同意。覆盖范围取决于来源收录与匹配结果，不保证每首歌都有歌词。
- 明确设置窗口打开时的歌词交互提示，并补充跨曲、撤销同意、本地导入与迟到结果隔离检查。
- 保留额度提示原时长。暂停验收等待界面处理完暂停后，检查原提示计时器身份和到期时间不变，而不是误把音乐附件动画重定向当作提示重启。

### English

v1.1.3/build 20 includes music-hover stability changes and an optional lyrics fallback. Publication requires the complete automated macOS checks on the final commit; v1.1.2 is preserved.

- Retain eligible music-origin hover geometry while quota details expand, preventing a stationary pointer on wide music wings from being dropped by the changing contour. Real exits, pause and playback-freshness boundaries remain enforced.
- LRCLIB remains the primary online lyrics source. AMLL is a separately consented, independently controlled fallback that is off by default. Coverage depends on source availability and matching; lyrics are not guaranteed for every track.
- Clarify lyrics interaction while Settings is open, with additional cross-track, consent-revocation, local-import and late-result isolation checks.
- Preserve quota-notice duration. Pause verification now waits for the panel to consume pause and checks the original notice timer identity and expiry, instead of confusing accessory-animation retargeting with a restarted notice.

### Validation and limits / 验证与边界

完整自动验收包括 Swift 测试、原生应用内回归、旧版失败/新版通过检查、Universal 构建及源代码绑定的 ZIP/DMG 核验。自动检查仍使用模拟播放数据、应用内事件和自身视图捕获，不能等同系统全局手势或用户现场验收。

真实系统 Music、TCC 权限、流媒体和用户 Mac 尚未实测；自动生成截图尚未完成人工检查。先前 #77 的轮询迟到根因仍未证明，后续通过只代表对应运行未复现。用户已知这些缺口并允许自动检查全部通过后发布；本版不宣称用户现场问题已全部解决，也不宣称全部验证边界已满足。

Automated acceptance covers Swift tests, native in-app regressions, old-red/new-green checks, universal builds and source-bound ZIP/DMG verification. Synthetic playback, own-app events and own-view captures are not proof of system-wide physical gestures or field behavior.

Real system Music, TCC, streaming and the user's Mac remain untested. Generated screenshots have not received manual visual review. The root cause of the earlier run #77 polling delay remains unproven; later passing runs establish non-reproduction only. The user authorized publication after all automated checks pass with these gaps disclosed. This release does not claim every reported field issue is resolved or every validation boundary has been satisfied.

需要 macOS 13+；Universal DMG/ZIP 包含 Apple Silicon 与 Intel 二进制。仅 ad-hoc 签名，无 Developer ID 签名或 Apple 公证；macOS 可能阻止启动。请勿关闭系统安全保护。

Requires macOS 13+. Universal DMG/ZIP packages include Apple Silicon and Intel binaries. Ad-hoc signed only, without Developer ID signing or Apple notarization; macOS may block launch. Do not disable system security protections.
