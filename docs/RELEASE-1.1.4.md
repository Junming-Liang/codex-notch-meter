## Codex Notch Meter v1.1.4

### 中文

v1.1.4/build 21 包含音乐详情展开宽度修正与默认关闭的本地调试记录。仅在最终版本提交的完整 macOS 自动检查通过后发布；保留已发布的 1.1.3，不覆盖旧包。

- 音乐详情从稳定收起态或歌词态展开时，宽度与轮廓两侧使用同一进度，避免共享紧凑宽度曲线中的平台段造成先变宽、缩回一点、再继续变宽；关闭使用同一路径。保留原动画时限、悬停阈值和中途反向处理。
- 调试记录默认关闭，用户主动开启后最多记录 5 分钟、2 MiB；可停止并导出到本地，不自动上传。记录几何、状态与耗时而非曲名、歌词或账户内容。导出文件仍应在分享前检查；自动测试没有验证真实保存对话框操作。
- 保留 LRCLIB 优先与独立同意、默认关闭的 AMLL 补充源；歌词覆盖仍取决于来源与匹配，不保证每首歌均可用。

### English

v1.1.4/build 21 adds a music-details width correction and opt-in local debug capture. Publication requires the complete automated macOS checks on the final version commit. The existing v1.1.3 release and its assets are preserved.

- Music details opening from a settled compact or lyrics state now uses the same progress for width and visible contour sides, avoiding the intermediate grow-shrink-grow segment in the shared compact-width map. Closing follows the same path. Existing animation deadlines, hover thresholds and interrupted reversals are retained.
- Debug capture is off by default. A user-started recording is bounded to 5 minutes and 2 MiB, can be stopped and exported locally, and is never uploaded automatically. It records geometry, state and timing rather than track titles, lyrics or account contents. Review exports before sharing; the real save-dialog interaction was not exercised by automated tests.
- LRCLIB remains primary; the separately consented AMLL fallback remains off by default. Coverage depends on source availability and matching, with no guarantee for every track.

### Validation and limits / 验证与边界

修正代码在 CI #84（提交 6db88235b18bc8a62d61a914bd8892781ae46236）通过完整自动检查：491 项测试、1 项跳过、0 项失败。宽度原生对照只向旧版移植测试夹具，旧版实际绘制回执出现两侧反向，新版在 220/330 宽度、有/无歌词、展开/收起共 8 段通过。版本更新后还须重新完整构建和验收，不能把 #84 的包改名当作 1.1.4。

这些是模拟播放数据、应用内事件与自身视图绘制回执，不是系统全局鼠标或显示扫描输出证明。真实系统 Music、TCC、流媒体和用户 Mac 仍未实测，截图尚未完成人工检查。动态附件正在变化时不在固定附件宽度单调证明范围内；此前轮询/定时器迟到的系统根因也未证明。通过不等于用户现场问题已全部解决。

The correction passed the complete automated checks in CI #84 at commit 6db88235b18bc8a62d61a914bd8892781ae46236: 491 tests, one skipped and zero failures. The native width comparison overlays only the test fixture onto old production code: old paint receipts demonstrate an actual side reversal, while the candidate passes eight segments across 220/330 widths, lyrics off/on and opening/closing. The version update must be rebuilt and fully checked; the #84 package cannot merely be renamed to 1.1.4.

These checks use synthetic playback, own-app events and own-view paint receipts, not physical system-wide mouse input or display scanout. Real system Music, TCC, streaming and the user's Mac remain untested; screenshots have not received manual visual review. Changing accessories are outside the fixed-accessory monotonic-width proof. The system-level cause of earlier polling/timer delays remains unproven. Passing checks do not establish that every field issue is resolved.

需要 macOS 13+；Universal DMG/ZIP 包含 Apple Silicon 与 Intel 二进制。仅 ad-hoc 签名，无 Developer ID 签名或 Apple 公证；macOS 可能阻止启动。请勿关闭系统安全保护。

Requires macOS 13+. Universal DMG/ZIP packages include Apple Silicon and Intel binaries. Ad-hoc signed only, without Developer ID signing or Apple notarization; macOS may block launch. Do not disable system security protections.
