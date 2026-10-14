# 原生界面设计

## 目标

让额度信息保持可见，但不抢夺注意力。默认只露出贴合物理顶边的细进度线；悬停时由同一个黑色轮廓连续展开额度内容。菜单栏始终保留完整入口。

## 设计语言

- 低干扰的石墨色表面与系统 San Francisco 字体
- 3 pt 进度线、6 pt 黑色底边，不扩大现有刘海交互区域
- 薄荷色 `#70D7B0` 表示正常信号，琥珀色 `#F1BF69` 和珊瑚色 `#F08086` 辅助表示较低余额
- 未知、旧数据和重置待确认均有文字说明，不仅依赖颜色
- 悬浮卡片宽 340 pt，设置窗口宽 480 pt；使用清晰的小字号层级和单一主数字
- 悬浮层固定深色，设置跟随系统；尊重降低透明度与提高对比度设置
- 一个弹簧进度同时驱动真实 NSPanel 尺寸、顶边位置、轮廓和内容显隐，不使用分离弹窗跳切
- 悬停进入等待 120 ms，离开保留 220 ms 宽限；中途回到岛内可平滑反转
- 降低动态效果时直接切换尺寸，不播放弹簧；折叠或运动期间不截获鼠标点击
- 展开内容为滚动区，底部始终预留设置和显式“退出”；菜单栏和设置也提供退出，⌘Q 只在应用获得键盘焦点时生效
- 不使用发光、网页侧边栏或额外品牌字体

## 参考与归属

本项目根据用户指定的 [VoltAgent / awesome-design-md](https://github.com/VoltAgent/awesome-design-md) 研究以下参考：

- [Linear](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/linear.app/DESIGN.md)：克制的层级、精确的间距、低饱和信号
- [Raycast](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/raycast/DESIGN.md)：紧凑、快速、工具型信息呈现
- [Apple](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/apple/DESIGN.md)：系统字体与原生材质、明确的操作层级

这些文档作为视觉原则参考，源仓库采用 MIT License，版权归 VoltAgent 2026。项目没有复制其代码、字体、品牌资产或设计原文。SwiftUI / AppKit 界面与图标均为独立实现。

设计规范不能代替真实界面验证。屏幕截图只能来自实际原生运行；演示模式必须保留明确标记。

## v0.1.1 动效研究

参考 [NotchKit](https://github.com/duongductrong/NotchKit)（MIT）的顶边连续轮廓、进入/离开宽限和降低动态效果原则，以及 [dynamic-landing](https://github.com/bring-shrubbery/dynamic-landing)（MIT）的顶边锚定验证思路。没有引入依赖或复制实现。本项目采用真实窗口尺寸跟随单一弹簧的独立实现，避免固定大透明窗口留下不可见点击区域。

原生测试使用托管 Mac 的真实 AppKit 窗口和明确标识的合成刘海/额度数据；检查实际窗口与内容边界、绘制边缘、退出按钮范围、反向动画和计时器清理。不把这些结果称为真实 MacBook 刘海测试或用户账户验证。
