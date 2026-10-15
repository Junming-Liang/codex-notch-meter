# 原生界面设计

## 目标

让额度信息保持可见，但不抢夺注意力。默认只露出贴合物理顶边的细进度线；悬停时由同一个黑色轮廓连续展开额度内容。菜单栏始终保留完整入口。

## 设计语言

- 低干扰的石墨色表面与系统 San Francisco 字体
- 2.5 pt 彩色进度线；名义外扩 3 pt，含抗锯齿不超过 4 pt，不扩大现有刘海交互区域
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

## v0.1.2 collapsed contour

The resting surface is transparent, including its interior. Only two 2.5pt quota arcs and their subtle 3.5pt dark keyline are drawn inside a four-point external envelope. Left/right healthy signals use mint/sky-blue; amber/coral thresholds remain semantic. A neutral track remains at zero, with a tiny endpoint marker rather than invented positive progress. Unknown is dashed; stale/reset-pending keeps truthful text and visible dimmed color.

The lower-corner curve is an approximation: NSScreen supplies safe exclusion bounds, not the hardware's exact radius. A fixed expanded detail view must never size the collapsed canvas. Its subtree is an overlay and exists only after expansion starts; the viewport and mask use actual hosting bounds. Black fill appears only during intentional expansion. Native pixel evidence must be distinguished from a physical display or human screenshot review.

## v0.1.3 single-contour skin system (supersedes the two-rail/gray-track treatment above)

The collapsed surface draws one uninterrupted U, starting upper-left and ending upper-right. A single selected quota fraction fills a left-anchored prefix; consumption retracts its right endpoint. The unfilled suffix is pure black, never gray. Zero and unknown draw no colored marker or fill; their meaning remains explicit in details/accessibility. The interior/corners stay transparent and the original nominal 3pt / maximum 4pt envelope is unchanged. The default window is the shortest returned known duration; an explicit selection changes only the contour, never removes other detail rows.

Five original palettes: mint (default static), flowing rainbow, aurora, sunset gold, ice blue. Only Rainbow animates in this version. An 8s/12s color phase changes paint inside the fixed trimmed path, never geometry or quota. One shared clock is throttled to 15fps and stopped when hidden, asleep, disabled, low-power, session-inactive or Reduce Motion. No glow, flashing, added network activity or per-row clocks.

## v0.1.6 automatic contour and wrapped refresh candidate

The idle contour, moving rail and black body now use one original circular path description, including shared inset corner centers. Runtime auxiliary edges remain the position/width authority. The automatic lower profile is informed by [Notchmeister's published 4 pt upper / 8 pt lower circular reference](https://github.com/chockenberry/Notchmeister/blob/1d5f664dd897cde412dd5d1ece47b241c05a992c/Notchmeister/Notchmeister/NotchExtensions.swift) (Craig Hockenberry, BSD-3-Clause, 2021). No source or Apple bezel asset is copied into the app. This reference is not a per-model measurement database. Normalizing the reference by reported depth / 32 is this project's approximation, not an Apple specification or a backing-pixel conversion.

The outer lower radius adds the existing 3 pt contour allowance; the stroke is inset from the same circular center. The extra upper flare is capped at 0.5 pt, keeping the geometric side extension at most 3.5 pt and the tested painted/antialiased envelope within 4 pt. Raw system exclusion bounds remain separate from optional corrections and from content placement. Native checks cover raw straight axes, circular lower turns, top endpoints, transparent interior, full keyline bounds and combined correction extremes. These cannot prove physical fit on every MacBook.

Default fitting is automatic. Optional Advanced controls adjust total width (±16 pt), bottom depth (±6 pt), corner curvature (±6 pt) and horizontal position (±8 pt), in 0.5 pt steps and subject to safe screen bounds. Per-display Reset clears all corrections. These controls are a fallback, not the normal installation flow.

A single top-edge-connected black body wraps the camera exclusion and content. A normal two-window detail body is about 340×220 pt at a 32 pt inset, rather than the old 512 pt height. Content height follows row/group/error needs with a bounded scroll area; Settings and Quit retain reserved space. An open interaction freezes its size endpoint until idle, preventing new data from causing an instantaneous resize.

Completed refreshes can target an intermediate body of about 340×110 pt. The same spring preserves position and velocity, holds it for two seconds after settling (0.8 seconds for unchanged data), then collapses. Pointer entry promotes it directly to full details; an obsolete expiry cannot close active hover. The moving quota line follows the same shape and fades continuously, with the black consumed suffix preserved. Reduce Motion uses immediate state changes. No additional quota polling or system notification is introduced.

Numerical changes use percentage points only when the existing response supplies comparable account/window/reset identity and fresh timestamps. Initial, unknown, reset, increased, failed and unchanged reads have truthful alternative wording. Account identity never enters presentation or artifacts. Fixed precision and a `<0.01` label avoid false zero-consumption text.
