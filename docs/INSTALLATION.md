# 安装、登录时启动与皮肤

## v0.1.5 开发预览

[下载 Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.5/CodexNotchMeter-0.1.5-universal.dmg) · [ZIP 备用下载](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.5/CodexNotchMeter-0.1.5-universal.zip) · [发布说明](https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.5)

原生编译、五款皮肤/动效检查、原始边界像素对齐与微调检查和 DMG 只读挂载验证已通过；登录项只进行了模拟状态转换与真实 API 只读检查。实际注册、用户批准及重新登录/重启后的启动尚未验证。完整证据见[验证说明](VALIDATION.md)。

## 安装

1. 下载发布页的 Universal DMG，并按需要核对同页的 SHA-256 文件。
2. 打开 DMG，把 **Codex Notch Meter.app** 拖到 **Applications** 链接。
3. 从“应用程序”启动已安装的副本，再推出 DMG。升级前先退出旧版本。
4. ZIP 仍可使用；解压后同样将完整 `.app` 放入“应用程序”。

DMG 是拖放安装映像，不是后台安装器。它不自动复制文件、不包含提权安装器、不注册登录项；复制到“应用程序”时的权限提示由 macOS 管理。应用从下载目录、只读映像或 App Translocation 运行时会给出安装提示，不会自行搬移或修改权限。

## 登录时启动

在应用“设置 → 启动”中打开“登录时启动”。这是 **登录当前 macOS 账户后** 启动菜单栏应用，不是登录前的系统服务。

使用 macOS 13+ 的 [`SMAppService.mainApp`](https://developer.apple.com/documentation/servicemanagement/smappservice)；仅在用户明确点击时请求注册或取消。系统状态会在操作之后、设置出现及应用重新激活时读取，不以本地布尔偏好代替真实状态。

- **未启用**：没有自动注册或反复重试。
- **已启用**：系统报告 eligible；实际登录启动仍由 macOS 决定。
- **等待批准**：点击“在系统设置中批准…”自行处理，或“取消待批准请求”。应用不会代替用户批准。
- **失败 / 未找到**：显示实际状态和安装建议；可以由用户点击“打开系统登录项…”。

预览版只有 ad-hoc 临时签名，没有 Apple Developer ID 签名或公证。macOS 可能阻止打开应用或拒绝登录项注册。DMG 不能消除签名限制；项目不提供关闭 Gatekeeper、删除隔离属性或其他安全绕过命令。

CI 仅模拟注册/取消状态转换，并在原生进程中只读观察系统 API；不会实际注册、取消或更改 runner 的登录项。真实用户批准和注销/重启后启动尚未验证。Apple 的[注册说明](https://developer.apple.com/documentation/servicemanagement/smappservice/register())明确要求尊重用户批准；[开发者技术支持](https://developer.apple.com/forums/thread/799910)也提醒 ad-hoc 签名在 Service Management 集成中可能存在问题。

## 外观皮肤

“设置 → 显示 → 外观皮肤”提供 **经典薄荷、流光彩虹、极光、日落暖金、冰蓝**。默认薄荷静态；选择流光彩虹会启用其颜色流动，可另关“皮肤动效”，或选 8 秒 / 12 秒周期。偏好保存在本机；演示测试不写入皮肤偏好。

折叠态只有一条完整 U 形主额度：左上沿左侧向下，经底边向右，再沿右侧向上。剩余额度从左端填充，用掉后从右端缩回；已用段纯黑，没有灰轨。0% 和未知不绘制彩色填充，详情与辅助功能文字区分状态。默认显示返回数据中最短的已知额度周期，“刘海主额度”可切换；展开卡片始终保留全部额度。

彩虹仅在固定额度弧内改变颜色，不移动进度端点、不添加光晕、不扩大约 3pt 轮廓。共享时钟最高 15fps；减少动态效果、低电量模式、屏幕休眠、会话不活跃、覆盖层关闭或没有可见彩色内容时暂停。不增加额度轮询。低额度仍有琥珀/珊瑚提示，过期/待重置状态保留准确文字并降低亮度。

## 悬停展开与收起

v0.1.5 在 macOS 14+ 使用随显示器刷新的几何更新，macOS 13 使用仅在过渡期间运行的主队列定时回退。首次悬停有短暂停留判定；离开有缓冲，收起过程中移回会保留当前位置和速度继续展开。详情提前在不影响收起尺寸的容器中布局；开启系统“减少动态效果”时直接切换状态。

几何动效与彩虹颜色时钟分开，后者仍最高 15 fps，不增加额度读取。云端原生时序与实际窗口/呈现层边界检查已通过；这不代表已在每种 Mac 或实际 macOS 13 上验证手感。

## 水平微调

默认按系统报告的刘海安全区域对齐，不自动左移。若实物仍有轻微偏差，可在“设置 → 显示 → 水平微调”使用减号向左、加号向右；单位是 macOS 逻辑点，每次 0.5 pt，最多 ±8 pt，靠近屏幕边界时进一步限制。可随时“重置”回到 0。

此设置只在本机按内建显示器的公开 UUID 分别保存，不读取硬件序列号、不上传标识。更改会关闭旧轮廓窗口并重建对应的绘制与鼠标区域，避免残留点击区。没有带刘海的内建屏幕或无法取得稳定标识时不开放校准。

Apple 的辅助安全区是系统报告的相机遮挡范围，并非实物轮廓的精密测量。照片有透视，屏幕截图又不显示硬件遮挡，不能据此承诺一个适用于所有机器的固定左移量。

---

## English summary

Open the Universal DMG, drag the app to Applications, launch the installed copy, then eject the image. The image never installs files or enrolls a login item automatically. ZIP remains available.

Settings provides an opt-in Launch at Login switch using Apple's macOS 13+ `SMAppService.mainApp`. It reads actual system state, explains approval-required/error states, and allows pending enrollment to be canceled. System Settings opens only on a user click. Downloads/read-only/translocated copies receive install-first guidance. Login means signing into the current macOS account, not a pre-login system daemon.

The ad-hoc, unnotarized preview may be blocked or refused by macOS. CI does not mutate real login items or validate reboot/login behavior. No security bypass is provided.

Five skins are available. Mint is static by default; choosing Rainbow opts into a slow color loop with a separate motion switch and 8s/12s speed. A single full-U contour fills from the left; consumed quota leaves a pure-black right suffix. The selected/shortest-known window drives the contour, while the expanded card retains all windows. Color phase never changes quota length. One maximum-15fps clock pauses for Reduce Motion, low power, sleep, hidden/disabled surfaces or inactive sessions. Demo preferences do not persist.

Version 0.1.5 provides default-zero per-built-in-display horizontal calibration in logical points, with 0.5pt steps, bounds and Reset. Public display UUIDs are local preference keys only; no serial-number lookup or identifier upload occurs. Actual physical alignment still needs observation.

Version 0.1.5 adds display-linked hover geometry on macOS 14+ and a transition-only main-queue fallback for macOS 13. Mid-collapse reentry preserves position and velocity; prewarmed details remain non-sizing. Reduce Motion snaps to the target. Native timing checks passed on the hosted newer OS; physical smoothness and actual macOS 13 runtime remain unverified. The separate rainbow clock stays capped at 15 fps.

## 显示兼容性候选 / Display compatibility candidate

v0.1.6 正在验证按显示能力适配的改进；当前上方下载链接仍指向已发布的 v0.1.5。不同屏幕尺寸、缩放或主屏排列不会被转换成固定的机型坐标。有效的内建刘海屏幕使用系统报告的边界；无刘海、外接屏、合盖、镜像及无效数据使用菜单栏。请参阅[覆盖矩阵与系统边界](COMPATIBILITY.md)，其中明确区分合成验证与真机验证。

The v0.1.6 candidate uses runtime display capabilities rather than model-specific notch coordinates. Non-notched, external-only, mirrored and invalid-geometry configurations retain the menu bar. The current verified download above remains v0.1.5; physical model-by-model validation is not claimed.
