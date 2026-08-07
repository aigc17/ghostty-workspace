/**
 * [INPUT]: TerminalController - 引用自 TerminalController.swift 的 [POS]: 终端窗口控制器,工作区接入点
 * [INPUT]: SplitTree/Ghostty.SurfaceView - 引用自 Splits/SplitTree.swift 与 Ghostty/SurfaceView 的 [POS]: 分屏树与终端 surface
 * [OUTPUT]: ProjectManager, WorkspaceProject/Session, WorkspaceSidebarView, WorkspaceRootView,
 *           WorkspacePaneHeader, WorkspaceAgentLauncher(项目行快捷启动), WorkspaceDragState(停靠 + 侧边栏排序)
 * [POS]: 侧边栏全部逻辑:模型/持久化/拖拽(停靠与排序)/UI,Codex 式「项目/对话」工作区
 *
 * [PROTOCOL]: 变更时更新此头部,然后检查 CLAUDE.md
 */

import SwiftUI
import AppKit
import Combine
import GhosttyKit
import UniformTypeIdentifiers

// MARK: - Workspace Model
//
// 「项目 / 对话」侧边栏(类似 Codex):
//   - 项目 = 一个目录
//   - 对话 = 一个(或一组分屏的)终端 surface,工作目录为项目目录
//
// 只要 WorkspaceSession 持有 SplitTree 的强引用,即使不显示在窗口中,
// 其中的 shell 进程与回滚缓冲区都保持存活(参见 Ghostty.Surface.deinit,
// 只有引用释放时才会 ghostty_surface_free)。

/// 一个「对话」:一个可保活的终端会话。
class WorkspaceSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    var workingDirectory: String

    /// The live splits for this session. Retaining this keeps the PTYs alive
    /// even when the session isn't shown in any window.
    @Published var tree: SplitTree<Ghostty.SurfaceView>? = nil

    /// The primary surface UUID persisted from a previous run, used to match
    /// windows recreated by native window restoration.
    var restoredSurfaceUUID: UUID? = nil

    /// True once the user renamed this session; the title then stops
    /// following the live terminal title.
    var userRenamed: Bool = false

    /// True when a terminal in this session posted a desktop notification
    /// (e.g. an AI CLI finished) that the user hasn't viewed yet.
    @Published var hasUnread: Bool = false

    /// 拖拽并入其他布局后的主 surface id:行保留在侧边栏,点击聚焦
    /// 那个分区;分区关闭后回退为普通记录行。不跨启动持久化。
    @Published var dockedSurfaceID: UUID? = nil

    var primarySurface: Ghostty.SurfaceView? {
        guard let tree else { return nil }
        return Array(tree).first
    }

    init(id: UUID = UUID(), title: String, workingDirectory: String) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || (primarySurface?.title.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// Sync the stored title from the live surface, e.g. before persisting.
    /// User-renamed sessions keep their custom title.
    func syncTitle() {
        guard !userRenamed else { return }
        if let t = primarySurface?.title, !t.isEmpty {
            title = t
        }
    }
}

/// Finder 式颜色标签。
enum WorkspaceColorTag: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    var title: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .gray: return "灰色"
        }
    }

    /// A filled-circle swatch drawn as a plain bitmap so AppKit menus keep
    /// its colors (symbol styling gets stripped there). Selected state draws
    /// a white checkmark on top.
    func menuImage(selected: Bool) -> NSImage {
        let image = NSImage(size: .init(width: 16, height: 16), flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            if selected {
                let check = NSBezierPath()
                check.move(to: .init(x: 4.6, y: 8.1))
                check.line(to: .init(x: 7.0, y: 5.7))
                check.line(to: .init(x: 11.4, y: 10.5))
                check.lineWidth = 1.9
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// 一个「项目」:一个目录 + 其下的对话列表。
class WorkspaceProject: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    let path: String
    @Published var sessions: [WorkspaceSession]
    @Published var expanded: Bool = true

    /// 置顶:显示在项目列表最前。
    @Published var pinned: Bool = false

    /// Finder 式颜色标签(WorkspaceColorTag rawValue),nil 为无标签。
    @Published var colorTag: String? = nil

    /// 最近一次使用(激活其下对话)的时间,用于「最近使用」排序。
    @Published var lastUsedAt: Date? = nil

    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || path.localizedCaseInsensitiveContains(query)
    }

    init(id: UUID = UUID(), name: String, path: String, sessions: [WorkspaceSession] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.sessions = sessions
    }
}

/// 项目列表排序方式。
enum WorkspaceProjectSort: String, CaseIterable, Identifiable {
    case manual, name, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "默认顺序"
        case .name: return "按名称"
        case .recent: return "最近使用"
        }
    }
}

/// 搜索命中高亮:命中片段染成强调色并加粗。
func workspaceHighlight(_ string: String, query: String) -> Text {
    guard !query.isEmpty else { return Text(string) }
    var attr = AttributedString(string)
    if let range = attr.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        attr[range].foregroundColor = .accentColor
        attr[range].font = .system(size: 12, weight: .bold)
    }
    return Text(attr)
}

/// Per-window sidebar UI state.
class WorkspaceState: ObservableObject {
    @Published var activeSessionID: UUID? = nil
    @Published var sidebarVisible: Bool = true
}

/// App-wide project/session store. Owns the strong references that keep
/// hidden sessions alive, and persists the project/session structure to disk.
class ProjectManager: ObservableObject {
    static let shared = ProjectManager()

    @Published private(set) var projects: [WorkspaceProject] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GhosttyWorkspace/projects.json")
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "WorkspaceProjectSortOrder"),
           let sort = WorkspaceProjectSort(rawValue: raw) {
            sortOrder = sort
        }
        load()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil)
    }

    @objc private func appWillTerminate() {
        save()
    }

    var allSessions: [WorkspaceSession] {
        projects.flatMap { $0.sessions }
    }

    /// 项目排序方式,持久化到 UserDefaults。
    @Published var sortOrder: WorkspaceProjectSort = .manual {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "WorkspaceProjectSortOrder") }
    }

    /// Projects in the chosen sort order. The sidebar splits pinned ones
    /// into their own「置顶」section.
    var displayProjects: [WorkspaceProject] {
        switch sortOrder {
        case .manual:
            return projects
        case .name:
            return projects.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .recent:
            return projects.sorted {
                ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
            }
        }
    }

    func togglePin(_ project: WorkspaceProject) {
        objectWillChange.send()
        project.pinned.toggle()
        save()
    }

    /// Stamp the project containing a session as recently used.
    func touchProject(containing session: WorkspaceSession) {
        project(containing: session)?.lastUsedAt = Date()
    }

    func project(containing session: WorkspaceSession) -> WorkspaceProject? {
        projects.first { $0.sessions.contains { $0 === session } }
    }

    /// A terminal posted a desktop notification: flag its session as unread
    /// unless the user is looking at it right now.
    func markUnread(surfaceContaining view: Ghostty.SurfaceView) {
        guard let session = allSessions.first(where: { session in
            guard let tree = session.tree else { return false }
            return tree.contains { $0 === view }
        }) else { return }

        // Being viewed in the key window: the user already sees the result.
        if let owner = TerminalController.all.first(where: { $0.activeWorkspaceSession === session }),
           owner.window?.isKeyWindow ?? false {
            return
        }
        session.hasUnread = true
    }

    /// Find (or create) the project for a directory path.
    func project(forPath path: String) -> WorkspaceProject {
        if let existing = projects.first(where: { $0.path == path }) { return existing }
        let name: String
        if path == NSHomeDirectory() {
            name = "Home"
        } else {
            let last = (path as NSString).lastPathComponent
            name = last.isEmpty ? path : last
        }
        let project = WorkspaceProject(name: name, path: path)
        // 新项目插到最前:置顶组独立展示,所以整体队首即「置顶之外的第一位」。
        projects.insert(project, at: 0)
        save()
        return project
    }

    /// 手动拖拽排序:把项目移动到 target 之前(nil = 移到末尾)。
    func moveProject(_ project: WorkspaceProject, before target: WorkspaceProject?) {
        guard projects.contains(where: { $0 === project }) else { return }
        projects.removeAll { $0 === project }
        if let target, let idx = projects.firstIndex(where: { $0 === target }) {
            projects.insert(project, at: idx)
        } else {
            projects.append(project)
        }
        save()
    }

    /// 项目内对话拖拽排序;对话(终端)不允许跨项目移动。
    func moveSession(
        _ session: WorkspaceSession,
        before target: WorkspaceSession?,
        in project: WorkspaceProject
    ) {
        guard project.sessions.contains(where: { $0 === session }) else { return }
        project.sessions.removeAll { $0 === session }
        if let target, let idx = project.sessions.firstIndex(where: { $0 === target }) {
            project.sessions.insert(session, at: idx)
        } else {
            project.sessions.append(session)
        }
        save()
    }

    /// Match a persisted session to a restored window by surface UUID.
    func session(matchingSurfaceUUIDs uuids: Set<UUID>) -> WorkspaceSession? {
        allSessions.first { session in
            guard session.tree == nil, let uuid = session.restoredSurfaceUUID else { return false }
            return uuids.contains(uuid)
        }
    }

    @discardableResult
    func addSession(to project: WorkspaceProject, workingDirectory: String? = nil) -> WorkspaceSession {
        let session = WorkspaceSession(
            title: "对话 \(project.sessions.count + 1)",
            workingDirectory: workingDirectory ?? project.path)
        project.sessions.append(session)
        save()
        return session
    }

    func removeSession(_ session: WorkspaceSession) {
        for project in projects {
            project.sessions.removeAll { $0 === session }
        }
        save()
    }

    /// Re-insert a previously removed session (undo path). Falls back to the
    /// project matching the session's working directory if the original
    /// project is gone.
    func restore(_ session: WorkspaceSession, into project: WorkspaceProject?) {
        let target: WorkspaceProject
        if let project, projects.contains(where: { $0 === project }) {
            target = project
        } else {
            target = self.project(forPath: session.workingDirectory)
        }
        if !target.sessions.contains(where: { $0 === session }) {
            target.sessions.append(session)
        }
        target.expanded = true
        save()
    }

    func removeProject(_ project: WorkspaceProject) {
        projects.removeAll { $0 === project }
        save()
    }

    // MARK: Persistence

    private struct SessionDTO: Codable {
        var id: UUID
        var title: String
        var workingDirectory: String
        var surfaceUUID: UUID?
        var userRenamed: Bool?
    }

    private struct ProjectDTO: Codable {
        var id: UUID
        var name: String
        var path: String
        var pinned: Bool?
        var colorTag: String?
        var lastUsedAt: Date?
        var sessions: [SessionDTO]
    }

    func save() {
        for project in projects {
            for session in project.sessions { session.syncTitle() }
        }
        let dtos = projects.map { project in
            ProjectDTO(
                id: project.id,
                name: project.name,
                path: project.path,
                pinned: project.pinned ? true : nil,
                colorTag: project.colorTag,
                lastUsedAt: project.lastUsedAt,
                sessions: project.sessions.map { session in
                    SessionDTO(
                        id: session.id,
                        title: session.title,
                        workingDirectory: session.workingDirectory,
                        surfaceUUID: session.primarySurface?.id ?? session.restoredSurfaceUUID,
                        userRenamed: session.userRenamed ? true : nil)
                })
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(dtos)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Ghostty.logger.warning("workspace save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dtos = try? JSONDecoder().decode([ProjectDTO].self, from: data) else { return }
        projects = dtos.map { pd in
            let project = WorkspaceProject(id: pd.id, name: pd.name, path: pd.path)
            project.pinned = pd.pinned ?? false
            project.colorTag = pd.colorTag
            project.lastUsedAt = pd.lastUsedAt
            project.sessions = pd.sessions.map { sd in
                let session = WorkspaceSession(
                    id: sd.id,
                    title: sd.title,
                    workingDirectory: sd.workingDirectory)
                session.restoredSurfaceUUID = sd.surfaceUUID
                session.userRenamed = sd.userRenamed ?? false
                return session
            }
            return project
        }
    }
}

// MARK: - Scrollback snapshots

/// Saves a plain-text snapshot of a session's terminal contents when it is
/// closed, so the record can still be inspected afterwards (read-only).
enum WorkspaceSnapshots {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GhosttyWorkspace/snapshots")
    }

    private static func url(for session: WorkspaceSession) -> URL {
        dir.appendingPathComponent("\(session.id.uuidString).txt")
    }

    /// Capture the current screen+scrollback text of every surface in the
    /// session's live tree. Call before releasing the tree.
    static func save(_ session: WorkspaceSession) {
        guard let tree = session.tree else { return }
        let parts = Array(tree)
            .map { $0.cachedScreenContents.get() }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        let header = "# \(session.title)\n# \(session.workingDirectory)\n\n"
        let text = header + parts.joined(separator: "\n\n────────── 分屏 ──────────\n\n")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: url(for: session), atomically: true, encoding: .utf8)
        } catch {
            Ghostty.logger.warning("workspace snapshot save failed: \(error)")
        }
    }

    static func exists(for session: WorkspaceSession) -> Bool {
        FileManager.default.fileExists(atPath: url(for: session).path)
    }

    static func open(for session: WorkspaceSession) {
        NSWorkspace.shared.open(url(for: session))
    }

    static func remove(for session: WorkspaceSession) {
        try? FileManager.default.removeItem(at: url(for: session))
    }
}

// MARK: - Claude Code integration

/// One-click setup of the Claude Code hooks that power the sidebar's
/// "AI 回复中" spinner: hooks write OSC 9;4 progress sequences to the tty
/// on prompt submit / stop, which Ghostty parses natively.
enum WorkspaceClaudeIntegration {
    private static let events = ["UserPromptSubmit", "Stop", "SessionEnd"]

    private static func command(for event: String) -> String {
        let state = event == "UserPromptSubmit" ? "3" : "0"
        return "{ printf '\\033]9;4;\(state);0\\033\\\\' > /dev/tty; } 2>/dev/null || true"
    }

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// True when every event already carries one of our progress hooks.
    static func isConfigured() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains("]9;4;") ?? false
                }
            }
        }
    }

    /// Merge our hooks into ~/.claude/settings.json, preserving everything
    /// else in the file. Idempotent.
    static func configure() throws {
        let url = settingsURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let already = entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains("]9;4;") ?? false
                }
            }
            guard !already else { continue }
            entries.append(["hooks": [["type": "command", "command": command(for: event)]]])
            hooks[event] = entries
        }
        root["hooks"] = hooks

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - TerminalController workspace actions

extension TerminalController {
    /// Register this window's initial surface as a workspace session so it
    /// shows up in the sidebar. Called once from windowDidLoad.
    func adoptInitialWorkspaceSession() {
        guard activeWorkspaceSession == nil, !surfaceTree.isEmpty else { return }
        let manager = ProjectManager.shared

        // Native window restoration recreates surfaces with their saved UUIDs;
        // match those to persisted sessions instead of creating duplicates.
        let uuids = Set(surfaceTree.map(\.id))
        let session: WorkspaceSession
        if let restored = manager.session(matchingSurfaceUUIDs: uuids) {
            session = restored
        } else {
            let pwd = initialWorkspacePwd ?? NSHomeDirectory()
            session = manager.addSession(to: manager.project(forPath: pwd), workingDirectory: pwd)
        }

        session.tree = surfaceTree
        activeWorkspaceSession = session
        workspaceState.activeSessionID = session.id
        manager.save()
    }

    /// Show a session in this window, keeping the previously shown session
    /// alive in the background. `initialInput` is typed into a freshly
    /// created shell (e.g. "claude --continue\n" to resume an AI conversation);
    /// ignored when the session already has a live tree.
    func activateWorkspaceSession(_ session: WorkspaceSession, initialInput: String? = nil) {
        // 已并入某个分屏布局的会话:聚焦那个分区,而不是再开一份。
        if session.tree == nil, let dockedID = session.dockedSurfaceID {
            if let owner = TerminalController.all.first(where: { $0.surfaceTree.find(id: dockedID) != nil }),
               let node = owner.surfaceTree.find(id: dockedID),
               case .leaf(let view) = node {
                owner.window?.makeKeyAndOrderFront(nil)
                owner.focusedSurface = view
                Ghostty.moveFocus(to: view)
                session.hasUnread = false
                return
            }
            // 那个分区已经关闭:退化为普通记录行,走常规激活。
            session.dockedSurfaceID = nil
        }
        if activeWorkspaceSession === session { return }

        // If the session is already shown in another window, focus that window.
        if let other = TerminalController.all.first(where: {
            $0 !== self && $0.activeWorkspaceSession === session
        }) {
            other.window?.makeKeyAndOrderFront(nil)
            return
        }

        // Keep the current session alive in the background.
        if let current = activeWorkspaceSession {
            current.tree = surfaceTree
            current.syncTitle()
        }

        // Materialize the session's tree if it doesn't have one yet
        // (fresh session, or restored from a previous run).
        let tree: SplitTree<Ghostty.SurfaceView>
        if let existing = session.tree, !existing.isEmpty {
            tree = existing
        } else {
            guard let app = ghostty.app else { return }
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = session.workingDirectory
            config.initialInput = initialInput
            tree = .init(view: Ghostty.SurfaceView(app, baseConfig: config))
            session.tree = tree
        }

        // Undo entries reference the previous session's tree; applying them
        // after a switch would graft that tree onto this session.
        undoManager?.removeAllActions(withTarget: self)

        activeWorkspaceSession = session
        workspaceState.activeSessionID = session.id
        session.hasUnread = false
        ProjectManager.shared.touchProject(containing: session)
        surfaceTree = tree

        if let view = Array(tree).first {
            focusedSurface = view
            Ghostty.moveFocus(to: view)
        }
        ProjectManager.shared.save()
    }

    /// Create and show a new session in a project. `initialInput` 会在新
    /// shell 就绪后自动键入(Agent 快捷启动)。
    func newWorkspaceSession(in project: WorkspaceProject, initialInput: String? = nil) {
        let session = ProjectManager.shared.addSession(to: project)
        project.expanded = true
        activateWorkspaceSession(session, initialInput: initialInput)
    }

    /// Register an expiring undo that restores a closed session (its sidebar
    /// row plus live tree). The captured tree keeps its processes alive until
    /// the undo expires, matching upstream close-terminal semantics.
    func registerWorkspaceSessionUndo(
        _ session: WorkspaceSession,
        project: WorkspaceProject? = nil,
        tree: SplitTree<Ghostty.SurfaceView>? = nil
    ) {
        guard let undoManager else { return }
        guard let tree = tree ?? session.tree, !tree.isEmpty else { return }
        let project = project ?? ProjectManager.shared.project(containing: session)
        session.syncTitle()
        undoManager.setActionName("关闭对话")
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            ProjectManager.shared.restore(session, into: project)
            session.tree = tree
            target.activateWorkspaceSession(session)
        }
    }

    /// Close a session from the sidebar. Always asks for confirmation:
    /// closing destroys a conversation, so an accidental click should never
    /// silently kill it.
    func closeWorkspaceSession(_ session: WorkspaceSession) {
        let manager = ProjectManager.shared
        let owner = TerminalController.all.first(where: {
            $0.activeWorkspaceSession === session
        })

        let running: Bool
        if let owner {
            running = owner.surfaceTree.contains(where: { $0.needsConfirmQuit })
        } else {
            running = session.tree?.contains(where: { $0.needsConfirmQuit }) ?? false
        }
        let alive = owner != nil || session.tree != nil
        let info: String
        if running {
            info = "该对话仍有正在运行的进程,关闭后进程将被终止。"
        } else if alive {
            info = "对话将被关闭并从列表中移除(短时间内可用 ⌘Z 撤销恢复)。"
        } else {
            info = "该对话记录将从列表中移除。"
        }

        confirmClose(messageText: "关闭对话?", informativeText: info) { [weak self] in
            guard let self else { return }
            if let owner {
                // The empty-tree path in surfaceTreeDidChange removes the
                // session and activates the next one (or closes the window).
                owner.surfaceTree = .init()
            } else if session.tree != nil {
                WorkspaceSnapshots.save(session)
                self.registerWorkspaceSessionUndo(session)
                session.tree = nil
                manager.removeSession(session)
            } else {
                // Pure record row: remove it and its snapshot.
                WorkspaceSnapshots.remove(for: session)
                manager.removeSession(session)
            }
        }
    }

    /// Remove a project and close all of its sessions.
    func removeWorkspaceProject(_ project: WorkspaceProject) {
        let manager = ProjectManager.shared
        for session in project.sessions {
            if let owner = TerminalController.all.first(where: {
                $0.activeWorkspaceSession === session
            }) {
                owner.activeWorkspaceSession = nil
                owner.workspaceState.activeSessionID = nil
                // Empty tree closes that window (surfaces freed there).
                owner.surfaceTree = .init()
            }
            session.tree = nil
        }
        manager.removeProject(project)
    }

    /// Simple info alert sheet.
    func showWorkspaceInfoAlert(_ title: String, _ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    /// First-launch offer to enable the Claude Code AI status hooks (开箱即用).
    /// Asked once; the sidebar wand button can configure it any time later.
    func offerClaudeIntegrationIfNeeded() {
        let promptedKey = "WorkspaceClaudeHooksPrompted"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptedKey) else { return }
        guard !WorkspaceClaudeIntegration.isConfigured() else {
            defaults.set(true, forKey: promptedKey)
            return
        }
        defaults.set(true, forKey: promptedKey)

        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "启用 AI 状态提示?"
        alert.informativeText = "为 Claude Code 配置 hooks 后,AI 回复过程中侧边栏会显示加载动画,完成后有绿点提醒。只会向 ~/.claude/settings.json 合并三条无副作用的提示命令,随时可在该文件中删除。"
        alert.addButton(withTitle: "启用")
        alert.addButton(withTitle: "以后再说")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try WorkspaceClaudeIntegration.configure()
            } catch {
                Ghostty.logger.warning("claude hooks configure failed: \(error)")
                self?.showWorkspaceInfoAlert("配置失败", "无法写入 ~/.claude/settings.json:\(error.localizedDescription)")
            }
        }
    }

    /// Show a rename sheet with a text field; calls completion with the
    /// trimmed non-empty result.
    func promptWorkspaceRename(
        title: String,
        current: String,
        completion: @escaping (String) -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: .init(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            completion(value)
        }
    }

    /// 添加自定义 Agent 的弹窗:名称 + 启动命令两个输入框。
    func promptNewWorkspaceAgent(completion: @escaping (String, String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "添加自定义 Agent"
        alert.informativeText = "启动命令会在新终端就绪后自动执行。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let nameField = NSTextField(frame: .init(x: 0, y: 32, width: 260, height: 24))
        nameField.placeholderString = "名称(如 Codex)"
        let commandField = NSTextField(frame: .init(x: 0, y: 0, width: 260, height: 24))
        commandField.placeholderString = "启动命令(如 codex)"
        let container = NSView(frame: .init(x: 0, y: 0, width: 260, height: 56))
        container.addSubview(nameField)
        container.addSubview(commandField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !command.isEmpty else { return }
            completion(title, command)
        }
    }

    /// Prompt for a directory and add it as a project.
    func promptNewWorkspaceProject() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加项目"
        panel.message = "选择一个项目文件夹"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let project = ProjectManager.shared.project(forPath: url.path)
            self.newWorkspaceSession(in: project)
        }
    }

    /// Create a new terminal split next to the focused surface, inheriting
    /// its working directory (Zed-style "+" button).
    func newWorkspaceSplitTerminal(direction: SplitTree<Ghostty.SurfaceView>.NewDirection) {
        guard let target = focusedSurface ?? Array(surfaceTree).first else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = target.pwd ?? activeWorkspaceSession?.workingDirectory
        newSplit(at: target, direction: direction, baseConfig: config)
    }

    /// Build the split node that docks `incoming` against `existing` on `edge`.
    static func workspaceSplitNode(
        edge: SplitTree<Ghostty.SurfaceView>.NewDirection,
        existing: SplitTree<Ghostty.SurfaceView>.Node,
        incoming: SplitTree<Ghostty.SurfaceView>.Node
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch edge {
        case .left: return .split(.init(direction: .horizontal, ratio: 0.5, left: incoming, right: existing))
        case .right: return .split(.init(direction: .horizontal, ratio: 0.5, left: existing, right: incoming))
        case .up: return .split(.init(direction: .vertical, ratio: 0.5, left: incoming, right: existing))
        case .down: return .split(.init(direction: .vertical, ratio: 0.5, left: existing, right: incoming))
        }
    }

    /// Insert `merged` into `tree` at the given dock target. Returns nil if
    /// the target can't be resolved.
    private func workspaceInserting(
        _ merged: SplitTree<Ghostty.SurfaceView>.Node,
        into tree: SplitTree<Ghostty.SurfaceView>,
        at target: WorkspaceDockTarget
    ) -> SplitTree<Ghostty.SurfaceView>? {
        switch target {
        case .windowEdge(let edge):
            guard let root = tree.root else { return .init(root: merged, zoomed: nil) }
            return .init(root: Self.workspaceSplitNode(edge: edge, existing: root, incoming: merged), zoomed: nil)
        case .pane(let id, let edge):
            guard let targetNode = tree.find(id: id) else { return nil }
            let edge = edge ?? .right
            return try? tree.replace(
                node: targetNode,
                with: Self.workspaceSplitNode(edge: edge, existing: targetNode, incoming: merged))
        }
    }

    /// Dock a dragged sidebar session into this window's layout (Zed-style):
    /// its terminals merge in as a split and the session entry disappears
    /// from the sidebar.
    func dockWorkspaceSession(_ session: WorkspaceSession, target: WorkspaceDockTarget) {
        guard activeWorkspaceSession != nil else {
            activateWorkspaceSession(session)
            return
        }
        if activeWorkspaceSession === session { return }

        // Shown in another window: don't steal it, just focus that window.
        if let other = TerminalController.all.first(where: {
            $0 !== self && $0.activeWorkspaceSession === session
        }) {
            other.window?.makeKeyAndOrderFront(nil)
            return
        }

        // The node to merge in: the session's live layout, or a fresh surface.
        let merged: SplitTree<Ghostty.SurfaceView>.Node
        if let tree = session.tree, let root = tree.root {
            merged = root
        } else {
            guard let app = ghostty.app else { return }
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = session.workingDirectory
            merged = .leaf(view: Ghostty.SurfaceView(app, baseConfig: config))
        }

        guard let newTree = workspaceInserting(merged, into: surfaceTree, at: target) else { return }

        // 终端并入本窗口布局,但侧边栏行保留:行记住主 surface,
        // 点击可聚焦那个分区(对话不会从文件树里消失)。
        session.syncTitle()
        session.tree = nil
        undoManager?.removeAllActions(withTarget: self)

        surfaceTree = newTree
        let focusView = merged.leftmostLeaf()
        session.dockedSurfaceID = focusView.id
        focusedSurface = focusView
        Ghostty.moveFocus(to: focusView)
        ProjectManager.shared.save()
    }

    /// 长按触发的拖拽开始:卡片立即以行位置弹出并给触觉反馈,让
    /// 「拿起来了」在移动之前就成立。落点解析等 workspaceDragChanged。
    func workspaceDragBegan(
        payload: WorkspaceDragState.Payload,
        label: String,
        rowFrame: CGRect?
    ) {
        let state = workspaceDragState
        if let current = state.payload, current != payload { state.reset() }
        if state.payload == nil {
            state.payload = payload
            state.label = label
        }
        if let rowFrame {
            state.rootLocation = CGPoint(x: rowFrame.midX, y: rowFrame.midY)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    /// Gesture-driven drag in progress: update the drag state (chip position,
    /// resolved target, highlight). `rootLocation` is in the workspace root
    /// coordinate space.
    func workspaceDragChanged(
        payload: WorkspaceDragState.Payload,
        label: String,
        rootLocation: CGPoint
    ) {
        let state = workspaceDragState
        // A stale payload from a cancelled gesture (onEnded never fired) must
        // not hijack this new drag.
        if let current = state.payload, current != payload {
            state.reset()
        }
        if state.payload == nil {
            state.payload = payload
            state.label = label
        }
        let frame = state.terminalFrame
        let local = CGPoint(x: rootLocation.x - frame.minX, y: rootLocation.y - frame.minY)
        state.location = local
        state.rootLocation = rootLocation

        // 悬停在侧边栏上方:解析为「排序」落点,与终端区停靠互斥。
        if state.sidebarFrame.contains(rootLocation),
           let reorder = resolveWorkspaceReorder(payload: payload, at: rootLocation) {
            if state.target != nil { state.target = nil }
            if state.highlight != nil { state.highlight = nil }
            if state.reorderTarget != reorder.target {
                state.reorderTarget = reorder.target
                // 落点切换时的触觉反馈:拖拽有「吸附」手感。
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
            if state.reorderIndicatorY != reorder.indicatorY { state.reorderIndicatorY = reorder.indicatorY }
            return
        }
        if state.reorderTarget != nil { state.reorderTarget = nil }
        if state.reorderIndicatorY != nil { state.reorderIndicatorY = nil }

        // Single spatial pass per event; publish only actual changes.
        let (target, highlight) = WorkspaceDockResolver.resolve(
            at: local, size: frame.size, tree: surfaceTree)
        if state.target != target {
            state.target = target
            if target != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        }
        if state.highlight != highlight { state.highlight = highlight }
    }

    /// 解析侧边栏内的拖拽排序落点。返回插入目标与指示线 Y(root 坐标系)。
    /// 屏幕上的行 frame 即真序:直接按 Y 轴比较,不需要关心置顶分组。
    private func resolveWorkspaceReorder(
        payload: WorkspaceDragState.Payload,
        at point: CGPoint
    ) -> (target: WorkspaceReorderTarget, indicatorY: CGFloat)? {
        let state = workspaceDragState
        let manager = ProjectManager.shared
        switch payload {
        case .pane:
            // 分区面板不参与侧边栏排序。
            return nil

        case .project(let uuid):
            // 只有手动排序下拖拽调序才有意义,其余模式顺序由规则决定。
            guard manager.sortOrder == .manual else { return nil }
            let rows = state.projectRowFrames
                .filter { $0.key != uuid }
                .sorted { $0.value.minY < $1.value.minY }
            guard let last = rows.last else { return nil }
            if let hit = rows.first(where: { point.y < $0.value.midY }) {
                return (.project(before: hit.key), hit.value.minY - 3)
            }
            return (.project(before: nil), last.value.maxY + 3)

        case .session(let uuid):
            guard let session = manager.allSessions.first(where: { $0.id == uuid }),
                  let project = manager.project(containing: session) else { return nil }
            // 终端(对话)不可跨项目:候选行只取本项目内的兄弟对话。
            let rows = project.sessions
                .filter { $0.id != uuid }
                .compactMap { sibling in
                    state.sessionRowFrames[sibling.id].map { (sibling.id, $0) }
                }
                .sorted { $0.1.minY < $1.1.minY }
            guard let first = rows.first, let last = rows.last else { return nil }
            // 限定在本项目对话区附近,指示线不会飞到别的项目里。
            guard point.y > first.1.minY - 14, point.y < last.1.maxY + 14 else { return nil }
            if let hit = rows.first(where: { point.y < $0.1.midY }) {
                return (.session(inProject: project.id, before: hit.0), hit.1.minY - 1)
            }
            return (.session(inProject: project.id, before: nil), last.1.maxY + 1)
        }
    }

    /// 执行侧边栏排序落点:项目重排 / 项目内对话重排。
    private func performWorkspaceReorder(
        payload: WorkspaceDragState.Payload,
        target: WorkspaceReorderTarget
    ) {
        let manager = ProjectManager.shared
        switch (payload, target) {
        case (.project(let uuid), .project(let beforeID)):
            guard let project = manager.projects.first(where: { $0.id == uuid }) else { return }
            let before = beforeID.flatMap { id in manager.projects.first { $0.id == id } }
            manager.moveProject(project, before: before)

        case (.session(let uuid), .session(let projectID, let beforeID)):
            guard let project = manager.projects.first(where: { $0.id == projectID }),
                  let session = project.sessions.first(where: { $0.id == uuid }) else { return }
            let before = beforeID.flatMap { id in project.sessions.first { $0.id == id } }
            manager.moveSession(session, before: before, in: project)

        default:
            break
        }
    }

    /// Gesture-driven drag finished: perform the reorder/dock and clear the state.
    func workspaceDragEnded() {
        let state = workspaceDragState
        let payload = state.payload
        let target = state.target
        let reorder = state.reorderTarget
        state.reset()

        guard let payload else { return }
        // 落在侧边栏内:执行排序,不再走停靠逻辑。
        if let reorder {
            performWorkspaceReorder(payload: payload, target: reorder)
            return
        }
        guard let target else { return }
        switch payload {
        case .pane(let uuid):
            moveWorkspacePane(surfaceID: uuid, to: target)
        case .session(let uuid):
            guard let session = ProjectManager.shared.allSessions.first(where: { $0.id == uuid })
            else { return }
            switch target {
            case .windowEdge, .pane(_, .some):
                dockWorkspaceSession(session, target: target)
            case .pane(_, nil):
                // Center: just show that session.
                activateWorkspaceSession(session)
            }
        case .project(let uuid):
            guard let project = ProjectManager.shared.projects.first(where: { $0.id == uuid })
            else { return }
            dockWorkspaceProject(project, target: target)
        }
    }

    /// Dock a dragged project: open a fresh terminal in the project's
    /// directory as a split at the drop position. This is how a single
    /// layout mixes terminals from multiple projects.
    func dockWorkspaceProject(_ project: WorkspaceProject, target: WorkspaceDockTarget) {
        guard activeWorkspaceSession != nil, !surfaceTree.isEmpty else {
            // Nothing to split against: open a normal session instead.
            newWorkspaceSession(in: project)
            return
        }
        guard let app = ghostty.app else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = project.path
        let merged: SplitTree<Ghostty.SurfaceView>.Node =
            .leaf(view: Ghostty.SurfaceView(app, baseConfig: config))

        guard let newTree = workspaceInserting(merged, into: surfaceTree, at: target) else { return }
        undoManager?.removeAllActions(withTarget: self)
        surfaceTree = newTree

        let focusView = merged.leftmostLeaf()
        focusedSurface = focusView
        Ghostty.moveFocus(to: focusView)
    }

    /// Move an existing pane (dragged by its grip) to a new dock target:
    /// another pane's edge (split there), another pane's center (swap the
    /// two panes), or a window edge (half the window).
    func moveWorkspacePane(surfaceID: UUID, to target: WorkspaceDockTarget) {
        guard let node = surfaceTree.find(id: surfaceID),
              case .leaf(let view) = node else { return }

        switch target {
        case .pane(let targetID, nil):
            // Center of another pane: swap the two panes in place.
            guard targetID != surfaceID,
                  let targetNode = surfaceTree.find(id: targetID),
                  case .leaf(let targetView) = targetNode,
                  let root = surfaceTree.root else { return }
            surfaceTree = .init(
                root: Self.workspaceSwappingLeaves(root, view, targetView),
                zoomed: nil)

        case .pane(let targetID, .some):
            guard targetID != surfaceID else { return }
            let removed = surfaceTree.remove(node)
            guard let newTree = workspaceInserting(.leaf(view: view), into: removed, at: target) else { return }
            surfaceTree = newTree

        case .windowEdge:
            let removed = surfaceTree.remove(node)
            // Dragging the only pane to a window edge is a no-op.
            guard removed.root != nil else { return }
            guard let newTree = workspaceInserting(.leaf(view: view), into: removed, at: target) else { return }
            surfaceTree = newTree
        }

        undoManager?.removeAllActions(withTarget: self)
        focusedSurface = view
        Ghostty.moveFocus(to: view)
    }

    /// Rebuild the node tree with two leaf views swapped.
    private static func workspaceSwappingLeaves(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        _ a: Ghostty.SurfaceView,
        _ b: Ghostty.SurfaceView
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch node {
        case .leaf(let view):
            if view === a { return .leaf(view: b) }
            if view === b { return .leaf(view: a) }
            return node
        case .split(let split):
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: workspaceSwappingLeaves(split.left, a, b),
                right: workspaceSwappingLeaves(split.right, a, b)))
        }
    }

    /// Handle the shown session's tree becoming empty (last surface closed).
    /// Returns true if another session was activated and the window stays open.
    func handleActiveWorkspaceSessionClosed(_ session: WorkspaceSession) -> Bool {
        let manager = ProjectManager.shared
        let project = manager.project(containing: session)
        activeWorkspaceSession = nil
        workspaceState.activeSessionID = nil
        // session.tree still holds the pre-close tree (kept in sync while the
        // session was shown); hold onto it so Cmd+Z can restore the whole
        // conversation with scrollback and processes.
        WorkspaceSnapshots.save(session)
        let deadTree = session.tree
        session.tree = nil
        manager.removeSession(session)
        undoManager?.removeAllActions(withTarget: self)

        // Find a session not shown in any window: prefer the same project.
        let attached = Set(TerminalController.all.compactMap { $0.activeWorkspaceSession?.id })
        let candidates = (project?.sessions ?? []) + manager.allSessions
        guard let next = candidates.first(where: { !attached.contains($0.id) }) else {
            return false
        }
        DispatchQueue.main.async { [weak self] in
            // The window may be mid-close (e.g. a closing tab group empties
            // our tree); don't resurrect sessions into a dying window.
            guard let self, let window = self.window, window.isVisible else { return }
            self.activateWorkspaceSession(next)
            // Register after activation (which clears cross-session undo
            // entries) so this restore entry survives.
            self.registerWorkspaceSessionUndo(session, project: project, tree: deadTree)
        }
        return true
    }
}

// MARK: - Views

/// Where a drag over the terminal area would dock.
enum WorkspaceDockTarget: Equatable {
    /// Dock against a window edge: takes half the whole terminal area.
    case windowEdge(SplitTree<Ghostty.SurfaceView>.NewDirection)
    /// Dock against a specific pane (by surface UUID). nil edge = pane center.
    case pane(UUID, SplitTree<Ghostty.SurfaceView>.NewDirection?)
}

/// Live state of an in-progress workspace drag (pane header or sidebar
/// session). We implement dragging with SwiftUI gestures instead of system
/// drag & drop because the terminal's AppKit/Metal views intercept system
/// drag routing, which made drops unreliable.
final class WorkspaceDragState: ObservableObject {
    enum Payload: Equatable {
        case pane(UUID)
        case session(UUID)
        /// Dragging a project row: dock creates a fresh terminal in the
        /// project's directory (multi-project splits).
        case project(UUID)
    }

    /// What's being dragged; nil when no drag is active.
    @Published var payload: Payload? = nil
    /// A short label shown on the floating drag chip.
    @Published var label: String = ""
    /// Cursor location in the terminal area's local coordinates.
    @Published var location: CGPoint = .zero
    /// Cursor location in the workspace root space: the floating chip is
    /// drawn at root level so it stays visible over the sidebar too.
    @Published var rootLocation: CGPoint = .zero
    /// Resolved dock target under the cursor.
    @Published var target: WorkspaceDockTarget? = nil
    /// Highlight rect in the terminal area's local coordinates.
    @Published var highlight: CGRect? = nil

    /// The terminal area's frame in the window root coordinate space,
    /// kept up to date by the root view's geometry reader.
    var terminalFrame: CGRect = .zero

    /// 侧边栏整体 frame(root 坐标系):拖拽悬停其上时进入「排序」模式。
    var sidebarFrame: CGRect = .zero
    /// 侧边栏各行的 frame(root 坐标系),由行视图上报,用于计算插入位置。
    /// 非 @Published:随滚动高频更新,不应触发视图刷新。
    var projectRowFrames: [UUID: CGRect] = [:]
    var sessionRowFrames: [UUID: CGRect] = [:]
    /// 侧边栏内的排序落点;nil = 当前不在排序模式。
    @Published var reorderTarget: WorkspaceReorderTarget? = nil
    /// 排序插入指示线的 Y(root 坐标系)。
    @Published var reorderIndicatorY: CGFloat? = nil

    func reset() {
        payload = nil
        label = ""
        target = nil
        highlight = nil
        reorderTarget = nil
        reorderIndicatorY = nil
    }
}

/// 侧边栏拖拽排序的落点:插入到某行之前(before = nil 表示移到末尾)。
enum WorkspaceReorderTarget: Equatable {
    case project(before: UUID?)
    case session(inProject: UUID, before: UUID?)
}

/// Pure geometry: resolve dock targets and highlight rects for a point in
/// the terminal area. One spatial layout pass per call.
enum WorkspaceDockResolver {
    static func resolve(
        at point: CGPoint,
        size: CGSize,
        tree: SplitTree<Ghostty.SurfaceView>
    ) -> (target: WorkspaceDockTarget?, highlight: CGRect?) {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height
        else { return (nil, nil) }

        // Near a window edge: dock against the whole terminal area.
        let margin: CGFloat = 28
        let edgeTarget: SplitTree<Ghostty.SurfaceView>.NewDirection?
        if point.x < margin { edgeTarget = .left }
        else if point.x > size.width - margin { edgeTarget = .right }
        else if point.y < margin { edgeTarget = .up }
        else if point.y > size.height - margin { edgeTarget = .down }
        else { edgeTarget = nil }
        if let edge = edgeTarget {
            let rect: CGRect
            switch edge {
            case .left: rect = .init(x: 0, y: 0, width: size.width / 2, height: size.height)
            case .right: rect = .init(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
            case .up: rect = .init(x: 0, y: 0, width: size.width, height: size.height / 2)
            case .down: rect = .init(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
            }
            return (.windowEdge(edge), rect)
        }

        // Otherwise target the pane under the cursor. Single layout pass.
        guard let root = tree.root else { return (nil, nil) }
        let slots = root.spatial(within: size).slots
        guard let slot = slots.first(where: { slot in
            if case .leaf = slot.node { return slot.bounds.contains(point) }
            return false
        }), case .leaf(let view) = slot.node else { return (nil, nil) }

        let b = slot.bounds
        let rx = (point.x - b.minX) / b.width
        let ry = (point.y - b.minY) / b.height
        let candidates: [(SplitTree<Ghostty.SurfaceView>.NewDirection, CGFloat)] = [
            (.left, rx), (.right, 1 - rx), (.up, ry), (.down, 1 - ry),
        ]
        let best = candidates.min { $0.1 < $1.1 }!
        guard best.1 <= 0.33 else { return (.pane(view.id, nil), b) }

        let rect: CGRect
        switch best.0 {
        case .left: rect = .init(x: b.minX, y: b.minY, width: b.width / 2, height: b.height)
        case .right: rect = .init(x: b.midX, y: b.minY, width: b.width / 2, height: b.height)
        case .up: rect = .init(x: b.minX, y: b.minY, width: b.width, height: b.height / 2)
        case .down: rect = .init(x: b.minX, y: b.midY, width: b.width, height: b.height / 2)
        }
        return (.pane(view.id, best.0), rect)
    }
}

/// The named coordinate space covering the whole workspace root view.
let workspaceRootSpace = "workspaceRoot"

/// 悬浮即显的功能名气泡:系统 .help 延迟长且不显眼,顶部工具区的
/// 小 icon 用它在 0.35s 内给出即时命名反馈,消除「这按钮是干嘛的」。
struct WorkspaceTooltip: ViewModifier {
    let text: String
    @State private var visible = false
    @State private var pending: DispatchWorkItem? = nil

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                guard inside else {
                    withAnimation(.easeOut(duration: 0.1)) { visible = false }
                    return
                }
                let work = DispatchWorkItem {
                    withAnimation(.easeOut(duration: 0.1)) { visible = true }
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
            .overlay(alignment: .bottom) {
                if visible {
                    Text(text)
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.thickMaterial)
                                .shadow(color: .black.opacity(0.25), radius: 4, y: 1))
                        .fixedSize()
                        .offset(y: 26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

extension View {
    func workspaceTooltip(_ text: String) -> some View {
        modifier(WorkspaceTooltip(text: text))
    }
}

/// 工具区统一按钮:统一字号 / 命中区 / 悬停底色,消除图标风格漂移。
struct WorkspaceToolButton: View {
    let icon: String
    let tip: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(hovered ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? Color.primary.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tip)
        .workspaceTooltip(tip)
    }
}

/// 只画滑块、不画轨道的 scroller:接鼠标时系统会强制 legacy 样式
/// (带轨道),单纯改 scrollerStyle 会被拽回去,自绘才是硬保证。
final class WorkspaceKnobOnlyScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    // 只画 knob,轨道与背景一概不画,透出侧边栏底色。
    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// 把所在 ScrollView 的滚动条换成「只有滑块」的样式。
/// 放在 ScrollView 内容的 background 上生效。
struct WorkspaceOverlayScrollerStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: nsView) }
    }

    private static func apply(from view: NSView) {
        var current: NSView? = view
        while let v = current, !(v is NSScrollView) { current = v.superview }
        guard let scroll = current as? NSScrollView else { return }
        scroll.autohidesScrollers = true
        scroll.horizontalScroller?.isHidden = true
        if !(scroll.verticalScroller is WorkspaceKnobOnlyScroller) {
            let scroller = WorkspaceKnobOnlyScroller()
            scroller.controlSize = .small
            scroll.verticalScroller = scroller
        }
    }
}

/// 行拖拽手势(项目行 / 对话行共用):按住 ~0.2s 卡片立即弹出,
/// 随后拖动跟手。快速点击(< 0.2s)不受影响,仍走行的 onTap。
func workspaceRowDragGesture(
    controller: TerminalController?,
    payload: WorkspaceDragState.Payload,
    label: @escaping () -> String,
    rowFrame: @escaping () -> CGRect?,
    dragging: Binding<Bool>
) -> some Gesture {
    LongPressGesture(minimumDuration: 0.18, maximumDistance: 10000)
        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(workspaceRootSpace)))
        .onChanged { value in
            switch value {
            case .first(true):
                if !dragging.wrappedValue {
                    withAnimation(.easeOut(duration: 0.12)) { dragging.wrappedValue = true }
                }
                controller?.workspaceDragBegan(payload: payload, label: label(), rowFrame: rowFrame())
            case .second(true, let drag):
                guard let drag else { break }
                controller?.workspaceDragChanged(payload: payload, label: label(), rootLocation: drag.location)
            default:
                break
            }
        }
        .onEnded { _ in
            withAnimation(.easeOut(duration: 0.12)) { dragging.wrappedValue = false }
            controller?.workspaceDragEnded()
        }
}

/// 把行 frame(root 坐标系)上报给拖拽状态,用于排序落点计算。
/// 作为 background 使用,不参与布局。
struct WorkspaceRowFrameReporter: View {
    let update: (CGRect) -> Void
    let remove: () -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { update(geo.frame(in: .named(workspaceRootSpace))) }
                .onChange(of: geo.frame(in: .named(workspaceRootSpace))) { update($0) }
                .onDisappear { remove() }
        }
    }
}

/// 拖拽排序时的插入位置指示线。挂在侧边栏 overlay 上,只有它在
/// 拖拽期间随状态刷新,不拖累整个侧边栏。
struct WorkspaceReorderIndicator: View {
    @ObservedObject var dragState: WorkspaceDragState

    var body: some View {
        GeometryReader { geo in
            if dragState.payload != nil, let y = dragState.reorderIndicatorY {
                let localY = y - geo.frame(in: .named(workspaceRootSpace)).minY
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width - 24), height: 2)
                    .position(x: geo.size.width / 2, y: localY)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - AI Agent 快捷启动

/// 项目行上的 AI Agent 快捷启动:选一个 Agent,在该项目下新开对话并
/// 自动执行启动命令。固定集合,品牌色记号。
enum WorkspaceAgentLauncher: String, CaseIterable, Identifiable {
    case claude, grok, kimi, pi, droid

    var id: String { rawValue }

    /// 菜单显示名。
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        case .pi: return "Pi"
        case .droid: return "Droid"
        }
    }

    /// 新终端的初始输入:命令 + 换行,shell 就绪后直接执行。
    var launchInput: String { rawValue + "\n" }

    /// 记号内的品牌字符。
    var glyph: String {
        switch self {
        case .claude: return "C"
        case .grok: return "G"
        case .kimi: return "K"
        case .pi: return "π"
        case .droid: return "D"
        }
    }

    /// 品牌近似色。真品牌 logo 需要素材文件进 Assets,先用色标记号。
    var nsColor: NSColor {
        switch self {
        case .claude: return NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1) // Anthropic 珊瑚橙
        case .grok: return NSColor(red: 0.55, green: 0.57, blue: 0.60, alpha: 1)   // xAI 石墨灰
        case .kimi: return NSColor(red: 0.39, green: 0.40, blue: 0.95, alpha: 1)   // Kimi 靛蓝
        case .pi: return NSColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1)     // Pi 青绿
        case .droid: return NSColor(red: 0.22, green: 0.67, blue: 0.97, alpha: 1)  // Factory 天蓝
        }
    }

    /// 菜单用品牌 logo:优先 Assets 里的官方图(AgentLogo-*,缓存 16pt
    /// 稳定实例;Grok/Kimi 为 template 自适应菜单深浅色),缺素材的
    /// 品牌(pi)回退到色标记号。
    func menuImage() -> NSImage {
        let key = "logo-\(rawValue)"
        if let cached = workspaceAgentBadgeCache[key] { return cached }
        guard let asset = NSImage(named: "AgentLogo-\(rawValue)") else {
            return workspaceAgentBadgeImage(glyph: glyph, color: nsColor)
        }
        let isTemplate = asset.isTemplate
        let image = NSImage(size: .init(width: 16, height: 16), flipped: false) { rect in
            asset.draw(in: rect)
            return true
        }
        image.isTemplate = isTemplate
        workspaceAgentBadgeCache[key] = image
        return image
    }
}

/// 记号位图缓存:菜单每次求值都拿到全新 NSImage 会让 SwiftUI 菜单
/// 适配器反复重建菜单项(项目一多会拖垮主线程),稳定实例是硬要求。
private var workspaceAgentBadgeCache: [String: NSImage] = [:]

/// 记号位图:彩圆底 + 白色字符。菜单会剥离符号配色,自绘位图不受
/// 影响(同 WorkspaceColorTag.menuImage)。内置与自定义 Agent 共用。
func workspaceAgentBadgeImage(glyph: String, color: NSColor) -> NSImage {
    let key = "\(glyph)#\(color.description)"
    if let cached = workspaceAgentBadgeCache[key] { return cached }
    let image = NSImage(size: .init(width: 16, height: 16), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        let text = NSAttributedString(string: glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: .init(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        return true
    }
    image.isTemplate = false
    workspaceAgentBadgeCache[key] = image
    return image
}

/// 闭包式 NSMenuItem 的 target 蹦床(NSMenuItem 只认 target/action)。
final class WorkspaceMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) { handler() }
}

/// 点击时即时构建并弹出 Agent 菜单(AppKit)。不给每个项目行常驻
/// SwiftUI Menu 适配器:行多时适配器反复重建菜单项会拖垮主线程。
enum WorkspaceAgentMenuPresenter {
    static func present(for project: WorkspaceProject, controller: TerminalController?) {
        let menu = NSMenu()

        func launch(_ title: String, _ image: NSImage, _ input: String) {
            menu.addItem(item(title, image: image) { [weak controller] in
                controller?.newWorkspaceSession(in: project, initialInput: input)
            })
        }

        for agent in WorkspaceAgentLauncher.allCases {
            launch(agent.title, agent.menuImage(), agent.launchInput)
        }
        let custom = WorkspaceAgentStore.shared.custom
        if !custom.isEmpty {
            menu.addItem(.separator())
            for agent in custom {
                launch(agent.title, agent.menuImage(), agent.command + "\n")
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("添加自定义 Agent…", image: nil) { [weak controller] in
            controller?.promptNewWorkspaceAgent { title, command in
                WorkspaceAgentStore.shared.add(title: title, command: command)
            }
        })
        if !custom.isEmpty {
            let submenu = NSMenu()
            for agent in custom {
                submenu.addItem(item(agent.title, image: agent.menuImage()) {
                    WorkspaceAgentStore.shared.remove(agent)
                })
            }
            let holder = NSMenuItem(title: "删除自定义 Agent", action: nil, keyEquivalent: "")
            holder.submenu = submenu
            menu.addItem(holder)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func item(
        _ title: String,
        image: NSImage?,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let action = WorkspaceMenuAction(handler)
        let item = NSMenuItem(
            title: title,
            action: #selector(WorkspaceMenuAction.run(_:)),
            keyEquivalent: "")
        item.target = action
        // NSMenuItem 不持有 target,借 representedObject 保活闭包蹦床。
        item.representedObject = action
        item.image = image
        return item
    }
}

/// 自定义 Agent:用户添加的「名称 + 启动命令」,后续新 AI CLI 无需改代码。
struct WorkspaceCustomAgent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var command: String

    /// 记号色:按名称确定性取色,重启不变。
    var nsColor: NSColor {
        let palette: [NSColor] = [
            .systemTeal, .systemPink, .systemIndigo, .systemBrown,
            .systemOrange, .systemPurple, .systemGreen,
        ]
        let sum = title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    func menuImage() -> NSImage {
        workspaceAgentBadgeImage(
            glyph: String(title.prefix(1)).uppercased(),
            color: nsColor)
    }
}

/// 自定义 Agent 列表,持久化到 UserDefaults。
final class WorkspaceAgentStore: ObservableObject {
    static let shared = WorkspaceAgentStore()

    @Published private(set) var custom: [WorkspaceCustomAgent] = []
    private let key = "WorkspaceCustomAgents"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([WorkspaceCustomAgent].self, from: data)
        else { return }
        custom = list
    }

    func add(title: String, command: String) {
        custom.append(.init(title: title, command: command))
        save()
    }

    func remove(_ agent: WorkspaceCustomAgent) {
        custom.removeAll { $0.id == agent.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Agent 快捷启动菜单项列表(项目行 sparkles 菜单与右键菜单共用):
/// 内置 Agent + 用户自定义 Agent + 添加/删除入口。
struct WorkspaceAgentMenuItems: View {
    let project: WorkspaceProject
    weak var controller: TerminalController?
    @ObservedObject private var store: WorkspaceAgentStore = .shared

    var body: some View {
        ForEach(WorkspaceAgentLauncher.allCases) { agent in
            launchButton(agent.title, image: agent.menuImage(), input: agent.launchInput)
        }
        if !store.custom.isEmpty {
            Divider()
            ForEach(store.custom) { agent in
                launchButton(agent.title, image: agent.menuImage(), input: agent.command + "\n")
            }
        }
        Divider()
        Button("添加自定义 Agent…") {
            controller?.promptNewWorkspaceAgent { title, command in
                WorkspaceAgentStore.shared.add(title: title, command: command)
            }
        }
        if !store.custom.isEmpty {
            Menu("删除自定义 Agent") {
                ForEach(store.custom) { agent in
                    Button(agent.title) { WorkspaceAgentStore.shared.remove(agent) }
                }
            }
        }
    }

    private func launchButton(_ title: String, image: NSImage, input: String) -> some View {
        Button {
            controller?.newWorkspaceSession(in: project, initialInput: input)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: image)
            }
        }
    }
}

/// Finder 式颜色标签选择器:一排彩色圆点,点击选中、再点同色取消。
struct WorkspaceTagPicker: View {
    @ObservedObject var project: WorkspaceProject

    var body: some View {
        if #available(macOS 14.0, *) {
            ControlGroup {
                ForEach(WorkspaceColorTag.allCases) { tag in
                    tagButton(tag)
                }
            }
            .controlGroupStyle(.palette)
        } else {
            Menu("标签") {
                ForEach(WorkspaceColorTag.allCases) { tag in
                    Button(tag.title) { set(tag.rawValue) }
                }
                Divider()
                Button("移除标签") { set(nil) }
            }
        }
    }

    private func tagButton(_ tag: WorkspaceColorTag) -> some View {
        let selected = project.colorTag == tag.rawValue
        return Button {
            set(selected ? nil : tag.rawValue)
        } label: {
            // 自绘位图:彩色圆底 + 选中时白色对勾,菜单不会篡改颜色。
            Image(nsImage: tag.menuImage(selected: selected))
        }
        .tint(tag.color)
        .help(tag.title)
    }

    private func set(_ value: String?) {
        project.colorTag = value
        ProjectManager.shared.save()
    }
}

/// 分区标签栏上的项目徽章:用实时 pwd 匹配项目,名称与颜色标签同色,
/// 让多项目混排布局里每个终端的归属一目了然。
struct WorkspaceProjectBadge: View {
    @ObservedObject var project: WorkspaceProject

    private var tagColor: Color? {
        project.colorTag.flatMap { WorkspaceColorTag(rawValue: $0)?.color }
    }

    var body: some View {
        Text(project.name)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .foregroundColor(tagColor ?? .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((tagColor ?? Color.primary).opacity(0.15)))
    }
}

/// The tab-like header bar on top of each terminal pane. The whole bar is a
/// drag handle for re-docking the pane; hovering reveals a close button.
struct WorkspacePaneHeader: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject private var manager: ProjectManager = .shared
    @State private var hovered = false

    private var controller: TerminalController? {
        surface.window?.windowController as? TerminalController
    }

    /// The project this pane currently belongs to, by longest path match of
    /// the live working directory (follows `cd` between projects honestly).
    private var matchedProject: WorkspaceProject? {
        guard let pwd = surface.pwd, !pwd.isEmpty else { return nil }
        return manager.projects
            .filter { pwd == $0.path || pwd.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            if let project = matchedProject {
                WorkspaceProjectBadge(project: project)
            }
            Text(surface.title.isEmpty ? "终端" : surface.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            if hovered {
                HStack(spacing: 9) {
                    Button { split(.right) } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("向右分屏")
                    Button { split(.down) } label: {
                        Image(systemName: "rectangle.split.1x2")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("向下分屏")
                    Button {
                        closePane()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭此终端")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(hovered ? 0.3 : 0.16))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("拖动标签栏可把此终端停靠到其他分区")
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(workspaceRootSpace))
                .onChanged { value in
                    controller?.workspaceDragChanged(
                        payload: .pane(surface.id),
                        label: surface.title.isEmpty ? "终端" : surface.title,
                        rootLocation: value.location)
                }
                .onEnded { _ in
                    controller?.workspaceDragEnded()
                }
        )
    }

    /// Split this specific pane, inheriting its working directory.
    private func split(_ direction: SplitTree<Ghostty.SurfaceView>.NewDirection) {
        guard let controller else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = surface.pwd
        controller.newSplit(at: surface, direction: direction, baseConfig: config)
    }

    private func closePane() {
        guard let controller else {
            (surface.window?.windowController as? BaseTerminalController)?.closeSurface(surface)
            return
        }
        // A lone pane closes through the workspace path so the window switches
        // to the next session instead of closing outright.
        if case .leaf = controller.surfaceTree.root,
           let session = controller.activeWorkspaceSession {
            controller.closeWorkspaceSession(session)
        } else {
            controller.closeSurface(surface)
        }
    }
}

/// Root content view for a terminal window: sidebar + terminal.
struct WorkspaceRootView: View {
    @ObservedObject var ghostty: Ghostty.App
    weak var controller: TerminalController?
    @ObservedObject var state: WorkspaceState
    @ObservedObject var manager: ProjectManager = .shared

    /// 侧边栏宽度,可拖拽调节并持久化。
    @AppStorage("WorkspaceSidebarWidth") private var sidebarWidth: Double = 300

    var body: some View {
        HStack(spacing: 0) {
            if state.sidebarVisible {
                // 不自绘背景:透出窗口背景色(Ghostty 会把它同步成终端
                // 当前的主题背景色),保证侧边栏与终端面板颜色一致。
                WorkspaceSidebarView(manager: manager, state: state, controller: controller)
                    .frame(width: CGFloat(min(480, max(200, sidebarWidth))))
                WorkspaceSidebarResizeHandle(width: $sidebarWidth)
            } else {
                WorkspaceCollapsedRail(state: state)
                Divider()
            }

            if let controller {
                WorkspaceTerminalArea(
                    ghostty: ghostty,
                    controller: controller,
                    dragState: controller.workspaceDragState)
            }
        }
        .overlay(dragChip)
        .coordinateSpace(name: workspaceRootSpace)
    }

    /// 根层拖拽浮卡:覆盖侧边栏 + 终端区,拖到哪都跟手。
    @ViewBuilder
    private var dragChip: some View {
        if let controller {
            WorkspaceDragChipOverlay(dragState: controller.workspaceDragState)
        }
    }
}

/// 拖拽中的悬浮小卡片:跟随光标、带阴影抬升感,在整个窗口范围内可见。
struct WorkspaceDragChipOverlay: View {
    @ObservedObject var dragState: WorkspaceDragState

    var body: some View {
        ZStack {
            if dragState.payload != nil {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text(dragState.label)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .position(x: dragState.rootLocation.x, y: dragState.rootLocation.y - 18)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        // 长按弹出时带一点弹性,强化「拿起来了」。
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: dragState.payload != nil)
        .allowsHitTesting(false)
    }
}

/// The draggable divider between the sidebar and the terminal area.
struct WorkspaceSidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double? = nil

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
        .frame(width: 6)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if startWidth == nil { startWidth = width }
                    width = min(480, max(200, (startWidth ?? width) + value.translation.width))
                }
                .onEnded { _ in startWidth = nil }
        )
    }
}

/// The terminal side of the window: terminal view + drag overlay.
///
/// Deliberately does NOT observe the drag state: only the lightweight
/// WorkspaceDragOverlay re-renders during a drag, so the terminal subtree
/// isn't re-evaluated at pointer-event rate.
struct WorkspaceTerminalArea: View {
    @ObservedObject var ghostty: Ghostty.App
    let controller: TerminalController
    let dragState: WorkspaceDragState

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TerminalView(
                    ghostty: ghostty,
                    viewModel: controller,
                    delegate: controller,
                    showsPaneHeaders: true
                )

                WorkspaceDragOverlay(dragState: dragState)
            }
            .onAppear {
                dragState.terminalFrame = geo.frame(in: .named(workspaceRootSpace))
            }
            .onChange(of: geo.frame(in: .named(workspaceRootSpace))) { newValue in
                dragState.terminalFrame = newValue
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The dock highlight + cursor chip shown during a workspace drag. Isolated
/// so pointer-rate state changes only invalidate this small view.
struct WorkspaceDragOverlay: View {
    @ObservedObject var dragState: WorkspaceDragState

    var body: some View {
        ZStack {
            if dragState.payload != nil, let rect = dragState.highlight {
                WorkspaceDockHighlight(rect: rect)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Highlights the region a dragged session/pane would dock into.
struct WorkspaceDockHighlight: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.16))
            .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeInOut(duration: 0.1), value: rect)
            .allowsHitTesting(false)
    }
}


/// The project/session sidebar.
struct WorkspaceSidebarView: View {
    @ObservedObject var manager: ProjectManager
    @ObservedObject var state: WorkspaceState
    weak var controller: TerminalController?

    /// True while a folder drag hovers over the sidebar.
    @State private var isDropTargeted = false

    /// 搜索关键字(项目名/路径/对话标题)。
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// 排序 + 搜索过滤后的展示列表。
    private var visibleProjects: [WorkspaceProject] {
        let base = manager.displayProjects
        guard !query.isEmpty else { return base }
        return base.filter { project in
            project.matches(query) || project.sessions.contains { $0.matches(query) }
        }
    }

    private var pinnedProjects: [WorkspaceProject] { visibleProjects.filter(\.pinned) }
    private var normalProjects: [WorkspaceProject] { visibleProjects.filter { !$0.pinned } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Text("工作区")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                WorkspaceToolButton(icon: "chevron.up.chevron.down", tip: "全部展开 / 收起") {
                    // 任意一个项目展开则全部收起,否则全部展开:单键往复。
                    let anyExpanded = manager.projects.contains { $0.expanded }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.projects.forEach { $0.expanded = !anyExpanded }
                    }
                }
                Menu {
                    ForEach(WorkspaceProjectSort.allCases) { sort in
                        Button {
                            manager.sortOrder = sort
                        } label: {
                            if manager.sortOrder == sort {
                                Label(sort.title, systemImage: "checkmark")
                            } else {
                                Text(sort.title)
                            }
                        }
                    }
                } label: {
                    // 与 WorkspaceToolButton 同规格,保持工具区视觉一致。
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("排序方式")
                .workspaceTooltip("排序方式")
                WorkspaceToolButton(icon: "square.and.pencil", tip: "新建对话") {
                    guard let controller else { return }
                    // 临时对话:挂在主目录(Home)项目下的纯终端。
                    let home = ProjectManager.shared.project(forPath: NSHomeDirectory())
                    controller.newWorkspaceSession(in: home)
                }
                WorkspaceToolButton(icon: "wand.and.stars", tip: "配置 AI 状态提示") {
                    guard let controller else { return }
                    if WorkspaceClaudeIntegration.isConfigured() {
                        controller.showWorkspaceInfoAlert(
                            "已配置",
                            "Claude Code 状态提示已启用:AI 回复中显示加载动画,完成后绿点提醒。")
                        return
                    }
                    do {
                        try WorkspaceClaudeIntegration.configure()
                        controller.showWorkspaceInfoAlert(
                            "配置完成",
                            "已写入 ~/.claude/settings.json。新开的 Claude Code 会话即可生效(已在运行的会话输入 /hooks 重载一次)。")
                    } catch {
                        controller.showWorkspaceInfoAlert(
                            "配置失败",
                            "无法写入 ~/.claude/settings.json:\(error.localizedDescription)")
                    }
                }
                WorkspaceToolButton(icon: "folder.badge.plus", tip: "新建项目") {
                    controller?.promptNewWorkspaceProject()
                }
                WorkspaceToolButton(icon: "sidebar.left", tip: "收起侧边栏") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.sidebarVisible = false }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            // 工具区气泡向下弹出,压过搜索框绘制。
            .zIndex(2)

            // 搜索框
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("搜索项目 / 对话", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if manager.projects.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("还没有项目")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Button("添加项目文件夹") {
                        controller?.promptNewWorkspaceProject()
                    }
                    .font(.system(size: 12))
                }
                Spacer()
            } else if visibleProjects.isEmpty {
                Spacer()
                Text("无匹配结果")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // 置顶项目独立成组(仿 Codex)。
                        if !pinnedProjects.isEmpty {
                            sectionLabel("置顶")
                            projectRows(pinnedProjects)
                            if !normalProjects.isEmpty {
                                // 分组之间的分割线:比组内分隔更实,拉开层级。
                                Divider()
                                    .padding(.horizontal, 4)
                                    .padding(.top, 10)
                                    .padding(.bottom, 8)
                                sectionLabel("项目")
                            }
                        }
                        projectRows(normalProjects)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    // 滚动条只留滑块、去掉轨道,不滚动时自动隐藏。
                    .background(WorkspaceOverlayScrollerStyler())
                }
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(4)
                .opacity(isDropTargeted ? 1 : 0)
        )
        // 上报侧边栏 frame(root 坐标系):拖拽悬停其上时切换为排序模式。
        .background(WorkspaceRowFrameReporter(
            update: { [weak controller] in controller?.workspaceDragState.sidebarFrame = $0 },
            remove: { [weak controller] in controller?.workspaceDragState.sidebarFrame = .zero }))
        .overlay(reorderIndicator)
    }

    /// 拖拽排序的插入指示线覆盖层。
    @ViewBuilder
    private var reorderIndicator: some View {
        if let dragState = controller?.workspaceDragState {
            WorkspaceReorderIndicator(dragState: dragState)
        }
    }

    /// 分组小标题(置顶 / 项目)。
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Color.secondary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
    }

    /// 一组项目行(组内含分隔线)。
    @ViewBuilder
    private func projectRows(_ list: [WorkspaceProject]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, project in
            if index > 0 {
                if index % 5 == 0 {
                    // 每 5 个项目一道加重分隔条:项目多时形成视觉分块,
                    // 扫读时以块为单位定位,缓解视觉疲劳。
                    Capsule()
                        .fill(Color.primary.opacity(0.16))
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 9)
                } else {
                    // 组内分隔:淡线 + 留白。
                    Divider()
                        .opacity(0.4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            WorkspaceProjectSection(
                project: project,
                state: state,
                controller: controller,
                searchQuery: query)
        }
    }

    /// Accept folders dragged from Finder and add them as projects.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else {
                    url = nil
                }
                guard let url else { return }

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else { return }

                DispatchQueue.main.async {
                    let project = ProjectManager.shared.project(forPath: url.path)
                    project.expanded = true
                }
            }
        }
        return accepted
    }
}

/// Narrow rail shown when the sidebar is collapsed.
struct WorkspaceCollapsedRail: View {
    @ObservedObject var state: WorkspaceState

    var body: some View {
        VStack {
            Button { withAnimation(.easeInOut(duration: 0.15)) { state.sidebarVisible = true } } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help("展开侧边栏")
            .padding(.top, 10)
            Spacer()
        }
        .frame(width: 28)
        .frame(maxHeight: .infinity)
    }
}

/// One project with its session list.
struct WorkspaceProjectSection: View {
    @ObservedObject var project: WorkspaceProject
    @ObservedObject var state: WorkspaceState
    weak var controller: TerminalController?

    /// 搜索关键字;非空时区块强制展开并只显示命中的对话。
    var searchQuery: String = ""

    @State private var hovered = false
    /// 拖拽中:行半透明「抬起」,给出明确的拖拽反馈。
    @State private var dragging = false

    private var isExpanded: Bool {
        searchQuery.isEmpty ? project.expanded : true
    }

    private var visibleSessions: [WorkspaceSession] {
        guard !searchQuery.isEmpty else { return project.sessions }
        // 项目本身命中则显示全部对话,否则只显示命中的对话。
        if project.matches(searchQuery) { return project.sessions }
        return project.sessions.filter { $0.matches(searchQuery) }
    }

    /// 颜色标签对应的填充色;无标签时按悬停态取灰调。
    private var folderColor: Color {
        if let tag = project.colorTag.flatMap({ WorkspaceColorTag(rawValue: $0) }) {
            return tag.color
        }
        return hovered ? .primary : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .font(.system(size: 12.5))
                    .foregroundColor(folderColor)
                workspaceHighlight(project.name, query: searchQuery)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .help(project.path)
                if project.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(Color.secondary.opacity(0.7))
                        .help("已置顶")
                }
                Spacer()
                // Agent 快捷启动:常驻标签(低调),点击即时弹出 AppKit
                // 菜单选 Agent,在该项目下新开对话并执行启动命令。
                Button {
                    WorkspaceAgentMenuPresenter.present(for: project, controller: controller)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5))
                        .foregroundColor(hovered ? .primary : Color.secondary.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("快捷启动 AI Agent")
                // 新建对话仍只在悬停时出现,减少静态视觉噪声。
                if hovered {
                    Button { controller?.newWorkspaceSession(in: project) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("新建对话")
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .background(WorkspaceRowFrameReporter(
                update: { [weak controller] in
                    controller?.workspaceDragState.projectRowFrames[project.id] = $0
                },
                remove: { [weak controller] in
                    controller?.workspaceDragState.projectRowFrames.removeValue(forKey: project.id)
                }))
            .opacity(dragging ? 0.35 : 1)
            .contentShape(Rectangle())
            .onHover { value in
                withAnimation(.easeOut(duration: 0.12)) { hovered = value }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { project.expanded.toggle() }
            }
            .gesture(
                // 拖到终端区在落点新开该项目目录的终端(跨项目分屏),
                // 拖回侧边栏则调整项目顺序。
                workspaceRowDragGesture(
                    controller: controller,
                    payload: .project(project.id),
                    label: { project.name },
                    rowFrame: { [weak controller] in
                        controller?.workspaceDragState.projectRowFrames[project.id]
                    },
                    dragging: $dragging)
            )
            .onDisappear {
                if controller?.workspaceDragState.payload == .project(project.id) {
                    controller?.workspaceDragState.reset()
                }
            }
            .contextMenu {
                Button("新建对话") { controller?.newWorkspaceSession(in: project) }
                Menu("快捷启动 Agent") {
                    WorkspaceAgentMenuItems(project: project, controller: controller)
                }
                Divider()
                Button(project.pinned ? "取消置顶" : "置顶项目") {
                    ProjectManager.shared.togglePin(project)
                }
                WorkspaceTagPicker(project: project)
                Divider()
                Button("在访达中打开") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: project.path)])
                }
                Button("复制项目路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(project.path, forType: .string)
                }
                Button("重命名项目…") {
                    controller?.promptWorkspaceRename(title: "重命名项目", current: project.name) { name in
                        project.name = name
                        ProjectManager.shared.save()
                    }
                }
                Divider()
                Button("全部展开") {
                    ProjectManager.shared.projects.forEach { $0.expanded = true }
                }
                Button("全部折叠") {
                    ProjectManager.shared.projects.forEach { $0.expanded = false }
                }
                Divider()
                Button("移除项目(关闭其所有对话)") { controller?.removeWorkspaceProject(project) }
            }

            if isExpanded {
                if visibleSessions.isEmpty {
                    Text("无对话")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary.opacity(0.6))
                        .padding(.leading, 32)
                        .padding(.vertical, 2)
                } else {
                    ForEach(visibleSessions) { session in
                        WorkspaceSessionRow(
                            session: session,
                            state: state,
                            controller: controller,
                            searchQuery: searchQuery)
                    }
                }
            }
        }
    }
}

/// One session row.
struct WorkspaceSessionRow: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var state: WorkspaceState
    weak var controller: TerminalController?

    /// 搜索关键字,用于标题命中高亮。
    var searchQuery: String = ""

    @State private var hovered = false
    /// 拖拽中:行半透明「抬起」,给出明确的拖拽反馈。
    @State private var dragging = false

    private var isActive: Bool { state.activeSessionID == session.id }

    /// 已并入其他分屏布局(行保留,点击聚焦那个分区)。
    private var isDocked: Bool { session.tree == nil && session.dockedSurfaceID != nil }

    private var rowBackground: Color {
        if isActive { return Color.accentColor.opacity(0.24) }
        if hovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDocked ? "rectangle.split.2x1" : "terminal")
                .font(.system(size: 9.5))
                .foregroundColor(isActive || hovered ? .primary : Color.secondary.opacity(0.75))
                .help(isDocked ? "已并入分屏,点击聚焦该分区" : "")
            WorkspaceSessionTitle(session: session, searchQuery: searchQuery)
                .foregroundColor(isActive || hovered ? .primary : .secondary)
            Spacer()
            if hovered {
                Button { controller?.closeWorkspaceSession(session) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭对话")
                .transition(.opacity)
            } else {
                WorkspaceSessionStatus(session: session)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 21)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground)
        )
        .background(WorkspaceRowFrameReporter(
            update: { [weak controller] in
                controller?.workspaceDragState.sessionRowFrames[session.id] = $0
            },
            remove: { [weak controller] in
                controller?.workspaceDragState.sessionRowFrames.removeValue(forKey: session.id)
            }))
        .opacity(dragging ? 0.35 : 1)
        .onHover { value in
            withAnimation(.easeOut(duration: 0.12)) { hovered = value }
        }
        .contentShape(Rectangle())
        .onTapGesture { controller?.activateWorkspaceSession(session) }
        .gesture(
            // 拖到终端区停靠分屏,拖回侧边栏排序(项目内)。
            workspaceRowDragGesture(
                controller: controller,
                payload: .session(session.id),
                label: { session.title },
                rowFrame: { [weak controller] in
                    controller?.workspaceDragState.sessionRowFrames[session.id]
                },
                dragging: $dragging)
        )
        .onDisappear {
            // Row removed mid-drag: the gesture is cancelled without onEnded.
            if controller?.workspaceDragState.payload == .session(session.id) {
                controller?.workspaceDragState.reset()
            }
        }
        .contextMenu {
            if session.tree == nil {
                Button("恢复 AI 对话(claude --continue)") {
                    controller?.activateWorkspaceSession(session, initialInput: "claude --continue\n")
                }
                if WorkspaceSnapshots.exists(for: session) {
                    Button("查看关闭前的记录") {
                        WorkspaceSnapshots.open(for: session)
                    }
                }
                Divider()
            }
            Button("重命名对话…") {
                controller?.promptWorkspaceRename(title: "重命名对话", current: session.title) { name in
                    session.title = name
                    session.userRenamed = true
                    ProjectManager.shared.save()
                }
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.workingDirectory, forType: .string)
            }
            Button("在访达中打开") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: session.workingDirectory)])
            }
            Divider()
            Button("关闭对话") { controller?.closeWorkspaceSession(session) }
        }
    }
}

/// Trailing status for a session row: a spinner while the terminal reports
/// progress (AI 回复中,由 OSC 9;4 驱动), else the green unread dot.
struct WorkspaceSessionStatus: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        if let surface = session.primarySurface {
            WorkspaceSurfaceStatus(surface: surface, hasUnread: session.hasUnread)
        } else if session.hasUnread {
            WorkspaceUnreadDot()
        }
    }
}

struct WorkspaceSurfaceStatus: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let hasUnread: Bool

    var body: some View {
        if surface.progressReport != nil {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 12, height: 12)
                .help("AI 回复中…")
        } else if hasUnread {
            WorkspaceUnreadDot()
        }
    }
}

/// 绿点 = 有新消息(用户约定的交互认知)。
struct WorkspaceUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 7, height: 7)
            .help("有新消息")
    }
}

/// Session title that live-updates from the terminal title when running.
struct WorkspaceSessionTitle: View {
    @ObservedObject var session: WorkspaceSession

    var searchQuery: String = ""

    var body: some View {
        if !session.userRenamed, let surface = session.primarySurface {
            WorkspaceSurfaceTitle(surface: surface, fallback: session.title, searchQuery: searchQuery)
        } else {
            workspaceHighlight(session.title, query: searchQuery)
                .font(.system(size: 12))
                .lineLimit(1)
        }
    }
}

struct WorkspaceSurfaceTitle: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let fallback: String

    var searchQuery: String = ""

    var body: some View {
        workspaceHighlight(surface.title.isEmpty ? fallback : surface.title, query: searchQuery)
            .font(.system(size: 12))
            .lineLimit(1)
    }
}
