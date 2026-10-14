# 原生界面设计

## 目标

让额度信息保持可见，但不抢夺注意力。默认只露出细进度线；需要细节时再展开原生卡片。菜单栏始终保留完整入口。

## 设计语言

- 低干扰的石墨色表面与系统 San Francisco 字体
- 3 pt 进度线、6 pt 黑色底边，不扩大现有刘海交互区域
- 薄荷色 `#70D7B0` 表示正常信号，琥珀色 `#F1BF69` 和珊瑚色 `#F08086` 辅助表示较低余额
- 未知、旧数据和重置待确认均有文字说明，不仅依赖颜色
- 悬浮卡片宽 340 pt，设置窗口宽 480 pt；使用清晰的小字号层级和单一主数字
- 悬浮层固定深色，设置跟随系统；尊重降低透明度与提高对比度设置
- 不使用发光、装饰动画、网页侧边栏或额外品牌字体

## 参考与归属

本项目根据用户指定的 [VoltAgent / awesome-design-md](https://github.com/VoltAgent/awesome-design-md) 研究以下参考：

- [Linear](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/linear.app/DESIGN.md)：克制的层级、精确的间距、低饱和信号
- [Raycast](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/raycast/DESIGN.md)：紧凑、快速、工具型信息呈现
- [Apple](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/apple/DESIGN.md)：系统字体与原生材质、明确的操作层级

这些文档作为视觉原则参考，源仓库采用 MIT License，版权归 VoltAgent 2026。项目没有复制其代码、字体、品牌资产或设计原文。SwiftUI / AppKit 界面与图标均为独立实现。

设计规范不能代替真实界面验证。屏幕截图只能来自实际原生运行；演示模式必须保留明确标记。
