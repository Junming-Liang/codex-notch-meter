# 参与贡献 / Contributing

欢迎提交可复现的问题和范围清晰的改进。

## 开发前

- 阅读 [README](README.md)、[隐私边界](PRIVACY.md)和[验证说明](docs/VALIDATION.md)
- 使用 macOS 13+、Swift 5.9+ 与 Xcode Command Line Tools
- 不引入第三方凭据读取、私有 HTTP 接口或模型调用来获取额度

## 提交前检查

```sh
python3 Scripts/check-source.py
swift test
bash Scripts/build-app.sh --universal
```

界面改动请说明明暗模式、提高对比度、降低透明度及读屏行为。几何改动请覆盖多屏全局坐标、缩放和无刘海情况。生命周期改动必须测试取消、重复关闭和只终止本应用拥有的子进程。

截图只能来自真实运行；合成额度必须保留“演示数据”标识。请删去私人信息，不能把示意图当作产品运行截图。

## Issue 与 Pull Request

- 说明 macOS、CPU 架构、Codex CLI 版本和复现步骤
- 只提交脱敏错误码，不提交原始账户响应、令牌、凭据或私有配置
- 一次解决一个问题，附上实际执行的测试与未验证项目
- 公开发布前保留 macOS 构建、测试、签名及架构检查的证据

Changes are welcome. Keep pull requests focused, preserve the read-only protocol boundary, and distinguish tests actually run from checks still pending. Never include account data or credentials. Contributions are made under the project's MIT License.
