# Codex 桌面应用发现

v0.1.1 不再要求桌面用户另外安装 CLI。应用先查询 LaunchServices 的 `com.openai.codex` 注册记录，再检查 `/Applications` 和当前用户的 `Applications` 顶层应用包；文件名可以是 Codex、ChatGPT 或用户重命名后的名称。不会递归搜索用户文件或 Codex 私有数据目录。

## 身份与路径校验

- 应用 `CFBundleIdentifier` 必须为 `com.openai.codex`，版本元数据必须存在
- 应用与 helper 都必须通过 Apple 信任锚和 OpenAI Team ID `2DC432GLL2` 的代码签名校验；应用同时校验嵌套签名
- helper 必须为可执行普通文件，解析符号链接后仍在该应用包内
- 支持官方文档中的旧版 `Contents/Resources/codex`
- 对新版 `Contents/Resources/codex-cli`，先验证有界 `codex-package.json`：布局版本 1、Codex 类型、Darwin 目标和已知入口/资源字段，再尝试包入口及签名的原生 helper
- 不执行桌面 GUI，不安装或修改任何文件，不启动对话；发现后仍只使用既有只读 app-server 账户握手

包内布局是兼容性探测，不是永久 API。未知格式、缺失文件、无效签名或逃逸链接会安全失败。设置中也可直接选择官方 `.app` 或可信 CLI；PATH/Homebrew 仍为后备选项。桌面应用被发现并不证明当前账户一定有可读取额度。

## 证据来源

- [OpenAI 官方桌面安装器源码](https://github.com/openai/codex/blob/main/codex-rs/cli/src/desktop_app/mac.rs)：应用标识、OpenAI 签名团队、标准安装目录和验证要求；经典 `com.openai.chat` 不属于此身份
- [OpenAI 官方排错文档](https://learn.chatgpt.com/docs/reference/troubleshooting)：旧版内置 Codex 入口
- [OpenAI 官方包布局实现](https://github.com/openai/codex/blob/main/scripts/codex_package/layout.py)与[说明](https://github.com/openai/codex/blob/main/scripts/codex_package/README.md)：布局版本、包入口和资源元数据
- [OpenAI 仓库中的新桌面打包报告](https://github.com/openai/codex/issues/48219)：`bin/codex` 包装入口和嵌套 `CodexCLI.app` 原生可执行文件。此项是第一手兼容性报告，并非供应商的稳定路径承诺；运行时仍必须通过上述签名和结构校验

测试使用合成应用目录、注入的签名判定和原生无签名拒绝检查。它们没有冒充 OpenAI 签名产物，也没有访问真实用户账户。真实已安装桌面版本及账户额度仍需单独确认。

## 原生分发包检查

CI 另有独立的发布门槛：从官方安装器定义的 HTTPS 地址下载当前 DMG（最多 1 GiB，120 秒），只读挂载，在不执行任何下载程序的情况下调用生产环境的有界 resolver，验证真实应用与 helper 签名、包含关系和30 秒发现时限，然后卸载卷。下载产物不会成为项目附件或安装到 runner。该检查与合成测试分开记录，候选版本通过前不得标记为已验证；它仍不能证明真实账户额度可读。
