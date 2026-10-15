# 兼容性 / Compatibility

适用于 v0.1.6；Apple 机型资料核对日期：2026-10-15。

**兼容性以运行时能力为准。** 下表说明支持范围与预期行为，不是逐机型实测认证。应用最低要求 macOS 13，Universal 构建包含 `arm64` 与 `x86_64`；还需使用该 Mac 官方支持的系统及可用的官方 Codex 桌面应用或 CLI。新机型须运行其兼容的较新 macOS，最低部署版本不表示可以给新机安装 Ventura。

## 机型与显示方式

### 有刘海的内建屏幕

满足下文的运行时检查后，显示刘海轮廓与展开详情；菜单栏入口始终保留。

| 机型系列 | 芯片范围 | 屏幕对角线 / 原生像素 | 官方依据 |
| --- | --- | --- | --- |
| MacBook Air 13 英寸 | M2、M3、M4、M5 | 13.6 英寸 / 2560 × 1664 | [Air 技术规格](https://www.apple.com/macbook-air/specs/)、[历代机型与规格入口](https://support.apple.com/en-us/102869) |
| MacBook Air 15 英寸 | M2、M3、M4、M5 | 15.3 英寸 / 2880 × 1864 | [Air 技术规格](https://www.apple.com/macbook-air/specs/)、[历代机型与规格入口](https://support.apple.com/en-us/102869) |
| MacBook Pro 14 英寸 | M1 Pro/Max、M2 Pro/Max；M3、M4、M5 各系列 | 14.2 英寸 / 3024 × 1964 | [Pro 技术规格](https://www.apple.com/macbook-pro/specs/)、[历代机型与规格入口](https://support.apple.com/en-us/108052) |
| MacBook Pro 16 英寸 | M1 至 M5 的 Pro/Max | 16.2 英寸 / 3456 × 2234 | [Pro 技术规格](https://www.apple.com/macbook-pro/specs/)、[历代机型与规格入口](https://support.apple.com/en-us/108052) |

像素规格用于辨识屏幕系列，**不用于推算刘海宽度、高度或位置**，也不代表 macOS 的默认逻辑分辨率。14 英寸的 M3/M4/M5 系列包含实际发布的基础、Pro 与 Max 配置；16 英寸不包含基础芯片配置。

### 无刘海的内建屏幕

以下为满足系统要求的代表性机型，使用菜单栏查看额度，不绘制虚拟刘海。

| 机型示例 | 配置 / 年份 | 预期方式与官方依据 |
| --- | --- | --- |
| MacBook Air 13.3 英寸 | Intel Retina（2018–2020）、M1（2020） | 菜单栏；[Air 机型资料](https://support.apple.com/en-us/102869) |
| MacBook Pro 13.3 英寸 | Intel（2017–2020）、M1（2020）、M2（2022） | 菜单栏；[Pro 机型资料](https://support.apple.com/en-us/108052) |
| MacBook Pro 15.4 英寸 | Intel（2017–2019） | 菜单栏；[Pro 机型资料](https://support.apple.com/en-us/108052) |
| MacBook Pro 16 英寸 | Intel（2019） | 菜单栏；[Pro 机型资料](https://support.apple.com/en-us/108052) |
| MacBook 12 英寸 | Intel（2017） | 菜单栏；[MacBook 机型资料](https://support.apple.com/en-us/103257) |
| MacBook Neo 13 英寸 | A18 Pro（2026），2408 × 1506 | 菜单栏；[Neo 官方规格与外观](https://support.apple.com/en-us/126322) |

[Apple 的 Ventura 兼容列表](https://support.apple.com/en-us/102861)可核对上述旧机型的 macOS 13 支持；该列表已归档，不是新机型的系统安装指南。不能据此承诺所有历史 MacBook 都能运行本应用，也不能用 Apple Silicon 或 M 系列芯片名称判断是否有刘海。

## 运行时判定与安全回退

- 仅在屏幕为**内建、在线、活动、唤醒且不参与镜像**时考虑刘海显示。外接屏不创建刘海窗口；合盖后内建屏不可用、镜像任一角色、无刘海或几何不可靠时，保留菜单栏功能。
- 以 `NSScreen.frame`、`safeAreaInsets.top`、`auxiliaryTopLeftArea` 与 `auxiliaryTopRightArea` 的全局逻辑点坐标定位。检查有限值、正尺寸、左右顺序、顶部位置和容纳详情的空间；不会用菜单栏自动隐藏或全屏时变化的 `visibleFrame` 重新定位刘海。
- 保留系统提供的原始边缘，仅对原生窗口外框做像素对齐。没有机型查表、硬编码的机型刘海尺寸或设备遥测；官方资料不是程序中的硬件白名单。
- 分辨率、缩放、主屏、屏幕排列、Spaces、连接或唤醒发生变化时重新读取能力。几何与原生窗口位置未变则保留现有窗口；需要改变或撤下时先清理旧窗口。立即处理后，按需在约 150 ms、600 ms 再读取新快照，不持续轮询或复用过期布局。
- 系统或显示器睡眠、会话不活跃、应用隐藏、关闭刘海显示及退出时，撤下刘海窗口并停止刘海相关的悬停、动画和布局重检计时源；恢复后重新读取布局。

实现入口：[能力判定](../Sources/NotchCore/Display.swift)、[原生快照与窗口协调](../Sources/CodexNotchMeter/DisplayCoordinator.swift)。全屏行为受 macOS 与前台应用影响；不承诺在所有全屏应用、锁屏或系统界面之上显示或交互。

## 自动轮廓与可选微调

默认根据系统避让区域与公开圆弧参考自动匹配轮廓。系统没有公开精确的物理圆角数据；自动曲线是有依据的近似，不是逐型号实测表。宽度、底部位置和圆角使用同一轮廓定义，进度线与展开主体不再使用不同的转角。

高级选项中的水平微调默认 **0 pt**，每次 0.5 pt，最多 ±8 pt，并受屏幕边界限制；总宽度、底部位置和圆角另有默认 0 的小范围修正，可一次重置全部。偏好按公开显示 UUID 仅保存在本机，不上传、不记录为遥测。UUID 缺失或重复时使用零偏移，不借用同名屏幕、主屏或其他屏幕的校准。安全区描述系统保留区域，不是实物边缘的精密测量，无法保证所有面板完全贴边。

## 验证范围

- [纯逻辑测试](../Tests/NotchCoreTests/DisplayTests.swift)包含 **216 组任意逻辑点布局**：四组官方原生像素比例 × 三种人为尺寸变换 × 三种全局原点 × 1×/2× backing scale × 三种水平偏移。刘海尺寸、安全区和尺寸变换均为合成输入，不是实测刘海或 Apple 默认缩放档位。
- 另有无刘海、外接、镜像、睡眠、无效几何、空间不足、屏幕重排、校准身份与恢复等合成案例。用例覆盖不等于已在对应设备运行。
- **v0.1.6 新增原生验证待完成；没有逐机型实机通过结论。** 既有托管 macOS 窗口、像素和动效结果只适用于[验证说明](VALIDATION.md)列出的精确提交，不能自动沿用到本版。实际 macOS 13、物理 Retina 面板、真实刘海对齐、缩放切换、合盖、镜像、睡眠唤醒及全屏交互仍需分别验收。
- 预览产物使用 ad-hoc 签名，没有 Apple Developer ID 签名或公证；双架构兼容不保证 Gatekeeper 放行或每台 Mac 可直接启动。项目不提供绕过系统安全检查的指引。

English summary: macOS 13+ universal architecture support and capability-based display handling are separate from physical-device validation. Model specifications inform documentation and synthetic fixtures only. Non-notched, external, mirrored or unavailable displays use the menu bar; new native validation and physical acceptance remain pending.
