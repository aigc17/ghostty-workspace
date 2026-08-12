# Folder: macos/Sources/Features/Terminal
> L2 | 父级: ../../../../CLAUDE.md

> macOS 终端窗口层:窗口控制器 + 工作区侧边栏(本 fork 核心改动区)。

## 成员清单
- `BaseTerminalController.swift`: 终端窗口控制器基类,surface 树管理、关闭确认、全屏等通用逻辑。
- `TerminalController.swift`: 主终端窗口控制器,工作区接入点(搜 "Workspace"),窗口生命周期与恢复。
- `TerminalRestorable.swift`: 窗口状态持久化/恢复(NSWindowRestoration)。
- `TerminalView.swift`: 终端区 SwiftUI 容器视图。
- `ErrorView.swift`: 终端创建失败时的错误占位视图。
- `WorkspaceSidebar.swift`: 侧边栏全部逻辑——项目/对话模型与持久化、拖拽停靠与侧边栏排序、项目行 AI Agent 快捷启动菜单、全部展开/收起、统一工具按钮(WorkspaceToolButton)与即时 tooltip、overlay 滚动条。⚠️ 已超 800 行,待拆分(模型/拖拽/视图)。
- `Window Styles/`: 各窗口样式(titlebar tabs 等)子目录。

## 侧边栏工具区图标(动前必读)

用 **Lucide**(shadcn/ui 同款图标集),SVG 放在 `macos/Assets.xcassets/Icon-*.imageset`,
模板渲染,统一走 `WorkspaceToolIcon`(绘制 15pt / 外框 22pt / 间距 2pt)。

- **不要给单个图标单独设尺寸**。曾为「抹平视觉重量」逐个调字号,
  结果字号不同基线就不同,固定高度框里中线全歪。
- **不要混用 SF Symbols**。实测同为 12pt,SF 六个图标墨迹高度 6.75–11.75pt、
  宽度 8.25–15.25pt;Lucide 同组是 11.5–14pt,且光学中心偏移基本为 0。
- **工具区不要用 SwiftUI `Menu`**。它会把标签塞进自己的控件宿主重新缩放,
  `WorkspaceToolIcon` 设的 15pt 被覆盖,图标比同排按钮大一圈。需要下拉就用
  普通按钮 + AppKit 即时弹菜单(`WorkspaceSortMenuPresenter` / `WorkspaceAgentMenuPresenter`)。
- 新增图标:从 `lucide-icons/lucide` 取 SVG → `currentColor` 换实色 →
  建 imageset(`preserves-vector-representation` + `template-rendering-intent: template`)。
- `sparkles` 系符号已被 Agent 快捷启动占用,别的功能不要再用星星。

**⚠️ 自指声明**:一旦本文件夹新增/删除/修改文件或职责变动,请立即更新本文档。

[PROTOCOL]: 变更时更新此头部,然后检查 CLAUDE.md
