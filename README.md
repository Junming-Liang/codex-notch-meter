<div align="center">
  <img src="docs/assets/icon.svg" width="88" height="88" alt="Codex Notch Meter 标志" />
  <h1>Codex Notch Meter</h1>
  <p><strong>让 Codex 剩余额度，安静地待在 Mac 刘海边。</strong></p>
  <p>原生 macOS 菜单栏工具 · 只读额度 · 不打断工作</p>
  <p>
    <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.dmg">下载 macOS Universal DMG</a> ·
    <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.zip">ZIP 备用下载</a> ·
    <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v0.1.4">发布说明</a> ·
    <a href="#快速开始">快速开始</a> ·
    <a href="README.en.md">English</a> ·
    <a href="https://github.com/Junming-Liang/codex-notch-meter/issues">反馈问题</a>
  </p>
  <p>
    <img alt="macOS 13 or later" src="https://img.shields.io/badge/macOS-13%2B-111318?logo=apple&amp;logoColor=white" />
    <img alt="Swift 5.9 or later" src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&amp;logoColor=white" />
    <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-70D7B0" /></a>
  </p>
</div>

## 概览

Codex Notch Meter 把 Codex 订阅的剩余额度显示在 MacBook 刘海两侧与底缘。需要细节时，悬停即可查看每个额度周期、重置时间和倒计时；没有刘海的显示器也能通过菜单栏使用。

应用使用 SwiftUI 与 AppKit 构建，通过官方 Codex CLI 的账户接口读取数据。不发送模型提示，不创建对话，不收集聊天记录。

> **v0.1.4 对齐修复预览已发布。** 保留系统报告的原始边界中心，提供默认 0 的逐屏水平微调（0.5 pt 一步，最多 ±8 pt，可重置）。五款皮肤、流光彩虹、DMG 和可选登录时启动继续保留；收起是约 3 pt 细轮廓，悬停展开完整详情。[安装与设置说明](docs/INSTALLATION.md)介绍使用方式与验证边界。

## 目录

- [下载与安装](#下载与安装)
- [功能](#功能)
- [快速开始](#快速开始)
- [读懂额度状态](#读懂额度状态)
- [隐私与连接方式](#隐私与连接方式)
- [从源码构建](#从源码构建)
- [开发与贡献](#开发与贡献)
- [已知限制](#已知限制)
- [设计与许可](#设计与许可)

## 下载与安装

1. 下载 [v0.1.4 Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.dmg)（1,060,193 字节），可同时获取 [SHA-256 校验文件](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.dmg.sha256)
2. 打开 DMG，把 **Codex Notch Meter.app** 拖到 **Applications**
3. 从“应用程序”打开已安装的副本，再推出 DMG

也可选择 [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.zip)（1,051,659 字节）及其 [SHA-256 文件](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v0.1.4/CodexNotchMeter-0.1.4-universal.zip.sha256)，解压后将完整 `.app` 放入“应用程序”。

升级时请先退出旧版本，再替换 `.app`。

Universal 产物包含 Apple Silicon 与 Intel 版本。本版已通过 91 项合成测试、双架构打包与签名校验、四种原生窗口/动画场景、五款皮肤的 1× / 2× 像素与实时切换检查、70 次原生对齐捕获及 13 次校准后展开操作检查、官方桌面 helper 只读发现，以及 DMG 只读挂载和清理检查。DMG 与 ZIP 分别提供独立 SHA-256 校验文件；源码版本与验证边界见[验证说明](docs/VALIDATION.md)。

**签名说明：**预览版使用 ad-hoc 临时签名，没有 Apple Developer ID 签名或公证。macOS 可能阻止下载产物启动，因此不能保证下载后在所有 Mac 上直接打开。项目不提供关闭 Gatekeeper 或绕过安全检查的命令；遇到拦截时可选择[从源码构建](#从源码构建)。不需要付费 Apple 开发者账户。

## 功能

| 一眼可见 | 按需展开 | 安静运行 |
| --- | --- | --- |
| 2.5 pt 进度线沿刘海外侧细轮廓显示 | 剩余额度、重置日期与倒计时 | 不抢焦点，没有 Dock 图标 |
| 自动适配系统报告的刘海位置 | 支持 Codex 返回的多个额度组 | 启动、唤醒及每 60 秒刷新 |
| 无刘海时使用菜单栏 | 设置中选择额度组与 CLI 路径 | 错误退避、悬停防抖、手动刷新 |

- 额度以 **剩余百分比** 展示：`100 − usedPercent`；整条 U 从左填充，消耗后右端退回，已用段纯黑
- 刘海默认显示最短的已知额度周期，也可选择主额度；展开卡片保留全部额度窗口
- 经典薄荷、流光彩虹、极光、日落暖金、冰蓝五款皮肤；彩虹支持可关闭的 8 秒 / 12 秒颜色循环
- 周期名称来自接口实际返回的时长，不把“主窗口 / 次窗口”写死成 5 小时 / 7 天
- 从刘海顶边连续展开与收起；悬停停留判定、离开缓冲和可中断的弹簧动效，支持“减少动态效果”
- 展开面板、菜单栏菜单与设置中均有明确的“退出”；应用激活时可用 `⌘Q`
- 石墨色面板、系统字体与可选皮肤；兼顾降低透明度、提高对比度和读屏文字
- “登录时启动”由用户自选，显示 macOS 实际状态和待批准提示
- 不默认添加开机启动，不监听全局键盘，不请求辅助功能或屏幕录制权限

## 快速开始

### 1. 准备官方 Codex

需要 macOS 13 或更新版本，以及已安装并使用 ChatGPT 账户登录的官方 Codex 桌面应用，或[官方 Codex CLI](https://learn.chatgpt.com/docs/cli)。账户必须能提供订阅额度窗口；API Key 计费不属于此类额度。

应用优先通过 LaunchServices 和标准应用目录寻找官方桌面应用，不依赖应用文件名。发现过程校验应用标识、OpenAI 签名、包版本元数据和内置 helper；随后才检查 `PATH` 与 Homebrew。未知布局或无效签名会明确失败，不会猜测任意可执行文件。首次完整签名校验可能需要一些时间，最多等待 30 秒；界面与退出操作不会因此阻塞。已检查的官方桌面版本和路径见[桌面应用发现](docs/DISCOVERY.md)。

### 2. 连接并查看额度

- 启动后，点击菜单栏图标或悬停刘海进度线
- 找不到 Codex 时，进入“设置 → Codex 连接 → 选择 Codex…”
- 可直接选择已安装的官方 `.app`，也可选择信任的 `codex` CLI；应用包必须通过签名与已知布局校验
- 请在 Codex 自己的界面或 CLI 中完成登录，然后回到本应用刷新

子进程继承原有运行环境，包括 `CODEX_HOME`；本应用不会修改 Codex 配置。若你的环境变量只在终端中生效，请从相同终端启动应用的可执行文件。

### 3. 自选启动与外观

安装到“应用程序”后，可在“设置 → 启动”打开“登录时启动”；如需系统批准，按界面提示处理。此选项默认不启用，临时签名可能导致 macOS 拒绝注册，真实重启后的自动启动尚未验证。

在“设置 → 显示”选择皮肤、皮肤动效和刘海主额度。默认薄荷静态；彩虹颜色只在剩余额度范围内流动，减少动态效果或无可见内容时暂停。

如实物仍有轻微偏差，可使用同页的“水平微调”：减号向左、加号向右，每次 0.5 pt，默认 0，支持重置。设置仅在本机按内建屏幕保存；系统安全区并非实物边缘的精密测量。

### 4. 保持轻量

展开岛和菜单栏详情底部均有明确的“退出”；右键菜单栏也可退出。设置获得焦点时支持 ⌘Q，不会截获其他应用的快捷键。设置中可以隐藏刘海进度线，保留菜单栏。正常退出会等待本应用启动的账户读取子进程完成清理。

## 读懂额度状态

| 状态 | 含义 |
| --- | --- |
| 薄荷色 / 琥珀色 / 珊瑚色进度 | 当前读取的剩余额度；颜色只是辅助，卡片始终显示数字 |
| 轮廓纯黑 / 详情“—” | 未知或不可用；0% 也不虚构彩色进度，详情区分状态 |
| “上次读取” / “数据已过期” | 保留的历史读取，不能当作实时额度 |
| “等待确认” | 重置时间已到，等待接口返回新数据；不会自动补满进度 |
| “演示数据” | 离线合成数据，没有启动 Codex 进程 |

重置日期使用 Mac 的本地时区。网络失败后，自动读取间隔逐步增加，最长 15 分钟；手动刷新和唤醒可主动重试。

## 隐私与连接方式

生产代码仅使用以下账户接口，通过自身 `codex app-server` 子进程的标准输入输出通信：

```text
initialize → initialized
account/read { refreshToken: false }
account/rateLimits/read
关闭并等待本应用拥有的子进程退出
```

- 不发送模型任务，不启动对话，不执行登录或退出
- 不打开或解析凭据文件、访问令牌、聊天历史、会话记录或私有数据库
- 不直接调用私有 HTTP API，不上传额度，不收集遥测
- 不保存原始账户响应或额度历史；本地只保留显示/皮肤偏好、额度组及可选 CLI 路径

Codex CLI 本身仍负责自己的认证、凭据刷新、日志、缓存及网络行为。“只读”描述的是本应用发出的请求，并不保证 Codex 子进程不会读写其自身文件。完整边界见[隐私说明](PRIVACY.md)。

## 从源码构建

需要 Xcode Command Line Tools 与 Swift 5.9 或更新版本。项目没有第三方 Swift 包依赖。

```sh
git clone https://github.com/Junming-Liang/codex-notch-meter.git
cd codex-notch-meter
swift test
bash Scripts/build-app.sh
open "dist/Codex Notch Meter.app"
```

生成双架构应用与校验文件：

```sh
bash Scripts/build-app.sh --universal
```

输出位于 `dist/`：`.app`、ZIP 和 SHA-256 校验文件。离线查看界面，无需 Codex 或账户：

```sh
swift run CodexNotchMeter --demo
```

## 开发与贡献

```text
Sources/NotchCore/          额度解析、状态、几何和只读传输
Sources/CodexNotchMeter/    原生界面、菜单栏和生命周期
Tests/NotchCoreTests/      合成数据与本地模拟子进程测试
Scripts/                   打包、图标和发布前检查
```

```sh
python3 Scripts/check-source.py
swift test
```

测试不依赖真实账户、凭据、Codex 安装或网络。工作流仅手动触发；构建与公开发布使用标准 GitHub 托管 runner。运行前确认仓库适用的 Actions 费用与存储条件。

提交问题前，请附上 macOS 版本、CPU 架构、Codex CLI 版本及复现步骤。不要上传原始账户响应、私有配置或凭据。贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 已知限制

- Codex 账户接口会演进；旧版本、未登录或不返回额度的账户会明确报错
- 缺少 Apple Developer ID 签名与公证，预览产物不能承诺在所有 Mac 上无提示启动
- 托管 macOS CI 可以验证构建与模拟测试，不能代替真实刘海、悬停、全屏、外接显示器和真实账户验证
- 当前界面以简体中文为主；英文说明见 [README.en.md](README.en.md)
- 强制退出、进程崩溃或系统断电不属于正常退出清理保证

## 设计与许可

原生设计参考 [VoltAgent / awesome-design-md](https://github.com/VoltAgent/awesome-design-md) 中 Linear、Raycast 与 Apple 的视觉原则，采用独立实现的界面与图标，不复用其品牌资产或代码。详见[设计说明](docs/DESIGN.md)。

[MIT License](LICENSE) · 独立开源项目，不隶属于 OpenAI 或 Apple，也不代表其官方产品。Codex 等名称归各自权利人所有。
