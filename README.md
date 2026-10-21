<div align="center">
  <img src="docs/assets/icon.svg" width="88" height="88" alt="Codex Notch Meter 标志" />
  <h1>Codex Notch Meter</h1>
  <p><strong>Codex 额度与 Apple Music 歌词，融入 Mac 顶边。</strong></p>
  <p>原生 macOS 菜单栏工具 · 只读额度 · 可选歌词</p>
  <p>
    <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.1.0/CodexNotchMeter-1.1.0-universal.dmg">下载 Universal DMG</a> ·
    <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.1.0/CodexNotchMeter-1.1.0-universal.zip">ZIP 备用下载</a> ·
    <a href="https://github.com/Junming-Liang/codex-notch-meter/releases/tag/v1.1.0">发布说明</a> ·
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

> **v1.1.0 已发布。** 临时 Music 读取失败后，取得新鲜且确认同曲的播放信息即可恢复已加载歌词；换到新曲时仍需等待匹配，无匹配时不会展示旧歌词。普通额度详情悬停展开恢复单段宽度节奏，保留现有尺寸与音乐手势路径。[Run 58](https://github.com/Junming-Liang/codex-notch-meter/actions/runs/39241505652) 的完整 macOS 检查已通过，30 张合成原生图片及同次源码绑定安装包已审核。见[中英发布说明](docs/RELEASE-1.1.0.md)。合成验证不等于用户实机手感、物理刘海或全部 Music 权限/流媒体组合已验证。

显示适配使用系统实时边界与显示能力；无刘海、外接、合盖及镜像模式保留菜单栏。云端原生检查已通过，[机型与覆盖矩阵](docs/COMPATIBILITY.md)明确区分合成验证和实机验证；自动曲线仍是公开资料支持的近似，不能保证每块实物面板完全贴合。

## Apple Music 歌词

- 每次启动默认收起，播放时可显示小封面与状态指示；缺少可用封面时使用中性占位，不联网补图
- 不按鼠标键，在固定顶部区域完整左→右划过打开匹配歌词，右→左关闭；普通悬停仍查看额度
- 左对齐当前句、较弱的真实下一句与小歌名；没有可用当前歌词就不展开空卡片
- 暂停、停止、切歌或播放信息过期时隐藏旧歌词；恢复后仅在已选择歌词模式且新歌词可用时重新显示
- 额度变化提示临时优先，按所选 2 / 4 / 6 秒停留后返回当前所选且可用的模式；悬停可保持普通额度详情
- 支持本地 LRC / 文本，以及单独授权的 LRCLIB 社区歌词匹配；歌词功能与在线匹配默认关闭
- 先精确匹配，再进行有界候选查询；规整已知影视出处等展示后缀，保留现场、混音、翻唱和语言版本区别
- 临时网络错误与真正无匹配分别显示；歌词覆盖率和不同系统的流媒体兼容性仍有限

使用步骤见下方[启用歌词](#4-启用歌词可选)，接口、安全边界与验证情况见[歌词说明](docs/MUSIC-LYRICS.md)。

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

1. 下载 [v1.1.0 Universal DMG](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.1.0/CodexNotchMeter-1.1.0-universal.dmg)，可同时获取 [SHA-256 校验文件](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.1.0/CodexNotchMeter-1.1.0-universal.dmg.sha256)
2. 打开 DMG，把 **Codex Notch Meter.app** 拖到 **Applications**
3. 从“应用程序”打开已安装的副本，再推出 DMG

也可选择 [Universal ZIP](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.1.0/CodexNotchMeter-1.1.0-universal.zip)及其 [SHA-256 文件](https://github.com/Junming-Liang/codex-notch-meter/releases/download/v1.1.0/CodexNotchMeter-1.1.0-universal.zip.sha256)，解压后将完整 `.app` 放入“应用程序”。

升级时请先退出旧版本，再替换 `.app`。

Universal 产物包含 Apple Silicon 与 Intel 版本。发布工作流要求合成测试、双架构打包、原有额度/像素/动效检查、歌词生命周期、官方 helper 只读发现和 DMG 验证全部通过。DMG 与 ZIP 各提供独立 SHA-256 文件；最终源码、实际结果与验证边界见[验证说明](docs/VALIDATION.md)。

**签名说明：**发布产物使用 ad-hoc 临时签名，没有 Apple Developer ID 签名或公证。macOS 可能阻止下载产物启动，因此不能保证下载后在所有 Mac 上直接打开。项目不提供关闭 Gatekeeper 或绕过安全检查的命令；遇到拦截时可选择[从源码构建](#从源码构建)。不需要付费 Apple 开发者账户。

## 功能

| 一眼可见 | 按需展开 | 安静运行 |
| --- | --- | --- |
| 3.5 pt 进度线沿刘海外侧细轮廓显示 | 剩余额度、重置日期与倒计时 | 不抢焦点，没有 Dock 图标 |
| 自动适配系统报告的刘海位置 | 支持 Codex 返回的多个额度组 | 启动、唤醒及每 60 秒刷新 |
| 无刘海时使用菜单栏 | 设置中选择额度组与 CLI 路径 | 错误退避、悬停防抖、手动刷新 |

- 额度以 **剩余百分比** 展示：`100 − usedPercent`；整条 U 从左填充，消耗后右端退回，已用段纯黑
- 刘海默认显示最短的已知额度周期，也可选择主额度；展开卡片保留全部额度窗口
- 经典薄荷、流光彩虹、极光、日落暖金、冰蓝五款皮肤；彩虹支持可关闭的 8 秒 / 12 秒颜色循环
- 周期名称来自接口实际返回的时长，不把“主窗口 / 次窗口”写死成 5 小时 / 7 天
- 详情与额度变化提示包裹刘海、连接屏幕顶边；仅实际数值变化触发，首读、未变化、失败及仅元数据更新保持安静，可在设置中关闭提示
- “提示停留时长”可选短 2 秒 / 标准 4 秒 / 长 6 秒，默认 4 秒；完全展开后计时，鼠标移入保留详情
- 只有同一账户、额度窗口与重置周期的连续新鲜读数才计算减少的百分点；重置导致的数值变化只说明重置，不虚构消耗
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

### 4. 启用歌词（可选）

1. 自行打开 Music 并播放歌曲，在“设置 → Apple Music 歌词”开启“Apple Music 歌词与播放指示”
2. 阅读说明后自行选择是否允许 Music 自动化访问；应用只读取当前歌曲、播放位置与可用封面，不控制播放
3. 为当前歌曲导入本地 UTF-8 LRC / 文本，或单独开启“使用 LRCLIB 在线匹配歌词”
4. 有可用歌词后，不按鼠标键从顶部左侧完整划到右侧；反向划过关闭。每次启动默认收起，暂停或换歌保留选择，但不会保留旧句

在线匹配会向 `lrclib.net` 发送歌名、歌手、专辑和时长，不发送 Apple 账户、令牌或额度。本地导入不上传；社区歌词不是 Apple 官方歌词，没有时间戳的文本会标为未同步。若服务暂不可用，应用遵守退避并显示对应状态，不能保证每首歌都有匹配结果。

### 5. 保持轻量

展开岛和菜单栏详情底部均有明确的“退出”；右键菜单栏也可退出。设置获得焦点时支持 ⌘Q，不会截获其他应用的快捷键。设置中可以隐藏刘海进度线，保留菜单栏。正常退出会等待本应用启动的账户读取子进程完成清理。

## 手动抖动诊断

在设置中开始录制，然后关闭设置和菜单再复现。菜单栏 `●REC` 会保持提示；复现后右键图标“停止并导出…”。默认关闭，最多 5 分钟、2 MiB，有界内存记录，不自动上传，不记录账户、歌曲/歌词正文或完整鼠标轨迹。[步骤、隐私和验证边界](docs/DEBUG-CAPTURE.md)。

## 读懂额度状态

| 状态 | 含义 |
| --- | --- |
| 薄荷色 / 琥珀色 / 珊瑚色进度 | 当前读取的剩余额度；颜色只是辅助，卡片始终显示数字 |
| 轮廓纯黑 / 详情“—” | 未知或不可用；0% 也不虚构彩色进度，详情区分状态 |
| “上次读取” / “数据已过期” | 保留的历史读取，不能当作实时额度 |
| “等待确认” | 重置时间已到，等待接口返回新数据；不会自动补满进度 |
| “演示数据” | 离线合成数据，没有启动 Codex 进程 |

重置日期使用 Mac 的本地时区。超时或断线后按 15 / 30 / 60 / 120 / 300 秒退避重试，其他错误仍使用保守退避；手动刷新和唤醒可主动重试。暂存读数标明上次成功读取的年龄。恢复后若满足账户与窗口连续性条件的新鲜读数确实变化，会显示当前值更新，不把跨失败间隔当作已验证的消耗量。

普通未变化刷新不会撤销或重启已有提醒。交互期间只保留最新的一条变化，在原始读数与接收时间均未超过 180 秒、重置未到期时交付；首读和失败本身保持安静。

## 隐私与连接方式

额度读取仅使用以下账户接口，通过自身 `codex app-server` 子进程的标准输入输出通信：

```text
initialize → initialized
account/read { refreshToken: false }
account/rateLimits/read
关闭并等待本应用拥有的子进程退出
```

- 不发送模型任务，不启动对话，不执行登录或退出
- 不打开或解析凭据文件、访问令牌、聊天历史、会话记录或私有数据库
- 不直接调用私有 HTTP API，不上传额度，不收集遥测
- 不保存原始账户响应或额度历史；本地保留显示/皮肤、歌词开关、额度组及可选 CLI 路径等设置
- 可选歌词通过公开 Apple Events 读取已运行的 Music；只有单独同意在线匹配后，才向 LRCLIB 发送上述歌曲字段。歌词与播放状态保存在内存，关闭功能或退出会清理

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
- 缺少 Apple Developer ID 签名与公证，发布产物不能承诺在所有 Mac 上无提示启动
- 托管 macOS CI 可以验证构建与模拟测试，不能代替真实刘海、悬停、全屏、外接显示器和真实账户验证
- 歌词来自本地文件或 LRCLIB 社区；不是 Apple 官方歌词，无法保证全部歌曲、Music 授权或流媒体组合。已有用户报告 Beta 歌词可用，不能替代跨设备验证
- 当前界面以简体中文为主；英文说明见 [README.en.md](README.en.md)
- 强制退出、进程崩溃或系统断电不属于正常退出清理保证

## 设计与许可

原生设计参考 [VoltAgent / awesome-design-md](https://github.com/VoltAgent/awesome-design-md) 中 Linear、Raycast 与 Apple 的视觉原则，采用独立实现的界面与图标，不复用其品牌资产或代码。详见[设计说明](docs/DESIGN.md)。

[MIT License](LICENSE) · 独立开源项目，不隶属于 OpenAI 或 Apple，也不代表其官方产品。Codex 等名称归各自权利人所有。

## Unreleased: optional AMLL fallback

A separately confirmed, default-off AMLL fallback is available in the candidate source. Existing LRCLIB consent does not enable it. It sends title, artist and album to api.amll.dev only after LRCLIB lacks usable lyrics or temporarily fails; local imports retain precedence. Exact identity/ambiguity checks deliberately prefer missing lyrics over wrong lyrics. See [matching, privacy and validation limits](docs/AMLL-LYRICS.md). This is not a release or a guarantee of song coverage.
