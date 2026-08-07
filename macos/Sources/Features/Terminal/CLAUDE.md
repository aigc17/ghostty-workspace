# Folder: macos/Sources/Features/Terminal
> L2 | 父级: ../../../../CLAUDE.md

> macOS 终端窗口层:窗口控制器 + 工作区侧边栏(本 fork 核心改动区)。

## 成员清单
- `BaseTerminalController.swift`: 终端窗口控制器基类,surface 树管理、关闭确认、全屏等通用逻辑。
- `TerminalController.swift`: 主终端窗口控制器,工作区接入点(搜 "Workspace"),窗口生命周期与恢复。
- `TerminalRestorable.swift`: 窗口状态持久化/恢复(NSWindowRestoration)。
- `TerminalView.swift`: 终端区 SwiftUI 容器视图。
- `ErrorView.swift`: 终端创建失败时的错误占位视图。
- `WorkspaceSidebar.swift`: 侧边栏全部逻辑——项目/对话模型与持久化、拖拽停靠与侧边栏排序、AI Agent 快捷启动、全部展开/收起、工具区 tooltip。⚠️ 已超 800 行,待拆分(模型/拖拽/视图)。
- `Window Styles/`: 各窗口样式(titlebar tabs 等)子目录。

**⚠️ 自指声明**:一旦本文件夹新增/删除/修改文件或职责变动,请立即更新本文档。

[PROTOCOL]: 变更时更新此头部,然后检查 CLAUDE.md
