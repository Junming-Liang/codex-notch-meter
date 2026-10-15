# 安装、登录时启动与皮肤

## v0.1.3 候选状态

DMG、登录项界面与五款皮肤正在原生 CI 验证。此文件描述候选行为，不代表已经发布或实际重启验证成功。

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

---

## English summary

Open the Universal DMG, drag the app to Applications, launch the installed copy, then eject the image. The image never installs files or enrolls a login item automatically. ZIP remains available.

Settings provides an opt-in Launch at Login switch using Apple's macOS 13+ `SMAppService.mainApp`. It reads actual system state, explains approval-required/error states, and allows pending enrollment to be canceled. System Settings opens only on a user click. Downloads/read-only/translocated copies receive install-first guidance. Login means signing into the current macOS account, not a pre-login system daemon.

The ad-hoc, unnotarized preview may be blocked or refused by macOS. CI does not mutate real login items or validate reboot/login behavior. No security bypass is provided.

Five skins are available. Mint is static by default; choosing Rainbow opts into a slow color loop with a separate motion switch and 8s/12s speed. A single full-U contour fills from the left; consumed quota leaves a pure-black right suffix. The selected/shortest-known window drives the contour, while the expanded card retains all windows. Color phase never changes quota length. One maximum-15fps clock pauses for Reduce Motion, low power, sleep, hidden/disabled surfaces or inactive sessions. Demo preferences do not persist.
