# Codex Notch Meter

让 MacBook 刘海边缘，安静地显示你的 Codex 剩余额度。

使用 SwiftUI 与 AppKit 构建的原生 macOS 菜单栏应用。两条细进度线沿刘海两侧和底缘显示剩余额度；鼠标悬停可查看额度、重置时间和实时倒计时。没有刘海的显示器使用菜单栏入口。

[English](README.md) · [隐私说明](PRIVACY.md) · [验证状态](docs/VALIDATION.md)

## 功能

- 显示剩余额度：`100 − usedPercent`
- 按 Codex 实际返回的时长显示窗口名称；支持返回的 5 小时、7 天等窗口，不把固定位置当成固定周期
- 展示多个额度组，并可选择刘海上显示的额度组
- 根据系统提供的真实刘海区域定位，使用全局屏幕坐标，支持多屏布局和缩放
- 启动、唤醒、手动操作时刷新，平时每 60 秒刷新；悬停防抖，错误后逐步降低请求频率
- 缺失数据显示“未知”；失败或过期数据有明确提示；到达重置时间后等待真实更新，不自行补满额度
- 菜单栏入口、刘海显示开关、Codex 可执行文件选择，以及明确标记的离线演示模式

没有 Dock 图标，不自动添加开机启动，不需要辅助功能或屏幕录制权限，不监听全局键盘事件。

## 运行要求

- macOS 13 或更新版本
- 已安装的官方 Codex CLI，并已使用能提供额度窗口的 ChatGPT 账户登录
- 从源码构建需要 Xcode Command Line Tools，以及 Swift 5.9 或更新版本

API Key 计费和其他账户类型不会被误当成订阅额度。应用不假设 Codex 桌面版一定会提供可自动发现的 CLI；可单独安装官方 CLI，或在设置中选择已有的官方可执行文件。

## 构建运行

```sh
swift test
bash Scripts/build-app.sh
open "dist/Codex Notch Meter.app"
```

生成同时支持 Apple Silicon 和 Intel 的版本：

```sh
bash Scripts/build-app.sh --universal
```

产物位于 `dist/`，包括 `.app`、ZIP 和 SHA-256 校验文件。构建仅使用临时签名（ad-hoc），不需要付费 Apple 开发者账户；没有 Developer ID 签名或公证。下载的开发预览产物可能被 macOS 安全检查阻止，预览阶段建议自行从源码构建。本项目不提供绕过安全检查的命令。

离线查看界面，不启动 Codex：

```sh
swift run CodexNotchMeter --demo
```

演示模式会明确标注。是否完成 macOS 构建、测试和真实界面验证，以[验证状态](docs/VALIDATION.md)为准。

## 使用

1. 启动应用，菜单栏入口始终可用
2. 悬停刘海进度线，或点击菜单栏入口，查看剩余额度和重置详情
3. 右键菜单栏入口，可以刷新、打开设置或退出
4. 如果找不到 Codex，在设置中选择你安装并信任的官方 `codex` 可执行文件

自动查找会检查 `PATH` 和常用 Homebrew 目录。子进程继承当前运行环境，包括已有的 `CODEX_HOME`；应用不会修改 Codex 配置。若你的设置依赖仅在终端中生效的环境变量，请从该终端启动应用的可执行文件。

暗淡的进度线表示旧数据；虚线表示未知或不可用。显示的重置时间到了，进度线也不会自行回满，而是等待下一次成功读取。日期使用 Mac 的本地时区。

## 数据来源与隐私

应用仅启动自己拥有的短生命周期 `codex app-server` 子进程，通过标准输入输出调用：

- `initialize` 和 `initialized`
- `account/read`，其中 `refreshToken` 为 `false`
- `account/rateLimits/read`

优先读取 `rateLimitsByLimitId`，兼容旧的 `rateLimits`。不发送模型提示，不创建对话或模型任务，不执行登录或退出，不调用私有 HTTP 接口，不打开或解析凭据文件、聊天记录或会话文件。遇到意外的服务端请求时关闭连接。

Codex CLI 本身负责自己的认证流程，仍可能进行正常的凭据刷新、日志、缓存和网络操作。应用本身不保存原始账户响应、不上传额度、不收集遥测。详见[隐私说明](PRIVACY.md)。

## 开发与测试

没有第三方 Swift 包依赖。测试只使用合成数据和本地模拟子进程，不需要 Codex、账户、凭据或网络。

```sh
python3 Scripts/check-source.py
swift test
```

GitHub Actions 工作流只支持手动触发，使用标准 macOS runner。发布源码不会自动执行构建；运行前应确认该仓库适用的 Actions 计费规则。

## 许可

[MIT](LICENSE)。独立实现，不隶属于 OpenAI 或 Apple，也不代表其官方产品。
