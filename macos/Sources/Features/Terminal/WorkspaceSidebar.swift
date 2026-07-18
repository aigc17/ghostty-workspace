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

    var primarySurface: Ghostty.SurfaceView? {
        guard let tree else { return nil }
        return Array(tree).first
    }

    init(id: UUID = UUID(), title: String, workingDirectory: String) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }

    /// Sync the stored title from the live surface, e.g. before persisting.
    func syncTitle() {
        if let t = primarySurface?.title, !t.isEmpty {
            title = t
        }
    }
}

/// 一个「项目」:一个目录 + 其下的对话列表。
class WorkspaceProject: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    let path: String
    @Published var sessions: [WorkspaceSession]
    @Published var expanded: Bool = true

    init(id: UUID = UUID(), name: String, path: String, sessions: [WorkspaceSession] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.sessions = sessions
    }
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

    func project(containing session: WorkspaceSession) -> WorkspaceProject? {
        projects.first { $0.sessions.contains { $0 === session } }
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
        projects.append(project)
        save()
        return project
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
    }

    private struct ProjectDTO: Codable {
        var id: UUID
        var name: String
        var path: String
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
                sessions: project.sessions.map { session in
                    SessionDTO(
                        id: session.id,
                        title: session.title,
                        workingDirectory: session.workingDirectory,
                        surfaceUUID: session.primarySurface?.id ?? session.restoredSurfaceUUID)
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
            project.sessions = pd.sessions.map { sd in
                let session = WorkspaceSession(
                    id: sd.id,
                    title: sd.title,
                    workingDirectory: sd.workingDirectory)
                session.restoredSurfaceUUID = sd.surfaceUUID
                return session
            }
            return project
        }
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
    /// alive in the background.
    func activateWorkspaceSession(_ session: WorkspaceSession) {
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
            tree = .init(view: Ghostty.SurfaceView(app, baseConfig: config))
            session.tree = tree
        }

        // Undo entries reference the previous session's tree; applying them
        // after a switch would graft that tree onto this session.
        undoManager?.removeAllActions(withTarget: self)

        activeWorkspaceSession = session
        workspaceState.activeSessionID = session.id
        surfaceTree = tree

        if let view = Array(tree).first {
            focusedSurface = view
            Ghostty.moveFocus(to: view)
        }
        ProjectManager.shared.save()
    }

    /// Create and show a new session in a project.
    func newWorkspaceSession(in project: WorkspaceProject) {
        let session = ProjectManager.shared.addSession(to: project)
        project.expanded = true
        activateWorkspaceSession(session)
    }

    /// Close a session: kills its processes. If it's shown in a window, that
    /// window switches to the next session (or closes if none remain).
    func closeWorkspaceSession(_ session: WorkspaceSession) {
        let manager = ProjectManager.shared
        guard let owner = TerminalController.all.first(where: {
            $0.activeWorkspaceSession === session
        }) else {
            // Hidden session: dropping the tree releases the surfaces.
            session.tree = nil
            manager.removeSession(session)
            return
        }

        let doClose = {
            // The empty-tree path in surfaceTreeDidChange removes the session
            // and activates the next one (or closes the window).
            owner.surfaceTree = .init()
        }
        if owner.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            owner.confirmClose(
                messageText: "关闭对话?",
                informativeText: "该对话仍有正在运行的进程,关闭后进程将被终止。"
            ) { doClose() }
        } else {
            doClose()
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

    /// Dock a dragged session onto an edge of this window's terminal area:
    /// the session's terminals merge into the current layout as a split
    /// taking half the window (Zed-style), and the dragged session entry
    /// disappears from the sidebar.
    func dockWorkspaceSession(
        _ session: WorkspaceSession,
        edge: SplitTree<Ghostty.SurfaceView>.NewDirection
    ) {
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

        // The dragged session's terminals now live in this session's layout.
        session.tree = nil
        ProjectManager.shared.removeSession(session)
        undoManager?.removeAllActions(withTarget: self)

        guard let root = surfaceTree.root else {
            surfaceTree = .init(root: merged, zoomed: nil)
            return
        }
        let newRoot: SplitTree<Ghostty.SurfaceView>.Node
        switch edge {
        case .left:
            newRoot = .split(.init(direction: .horizontal, ratio: 0.5, left: merged, right: root))
        case .right:
            newRoot = .split(.init(direction: .horizontal, ratio: 0.5, left: root, right: merged))
        case .up:
            newRoot = .split(.init(direction: .vertical, ratio: 0.5, left: merged, right: root))
        case .down:
            newRoot = .split(.init(direction: .vertical, ratio: 0.5, left: root, right: merged))
        }
        surfaceTree = .init(root: newRoot, zoomed: nil)

        let focusView = merged.leftmostLeaf()
        focusedSurface = focusView
        Ghostty.moveFocus(to: focusView)
        ProjectManager.shared.save()
    }

    /// Handle the shown session's tree becoming empty (last surface closed).
    /// Returns true if another session was activated and the window stays open.
    func handleActiveWorkspaceSessionClosed(_ session: WorkspaceSession) -> Bool {
        let manager = ProjectManager.shared
        let project = manager.project(containing: session)
        activeWorkspaceSession = nil
        workspaceState.activeSessionID = nil
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
            self?.activateWorkspaceSession(next)
        }
        return true
    }
}

// MARK: - Views

/// The drag type used to drag sessions from the sidebar into the terminal
/// area for Zed-style dock splitting. Own-process only.
let workspaceSessionUTType = UTType(exportedAs: "com.qimu.ghostty-workspace.session")

/// Root content view for a terminal window: sidebar + terminal.
struct WorkspaceRootView: View {
    @ObservedObject var ghostty: Ghostty.App
    weak var controller: TerminalController?
    @ObservedObject var state: WorkspaceState
    @ObservedObject var manager: ProjectManager = .shared

    /// Dock-drop state while dragging a session over the terminal area.
    @State private var dockTargeted = false
    @State private var dockEdge: SplitTree<Ghostty.SurfaceView>.NewDirection? = nil

    var body: some View {
        HStack(spacing: 0) {
            if state.sidebarVisible {
                // 不自绘背景:透出窗口背景色(Ghostty 会把它同步成终端
                // 当前的主题背景色),保证侧边栏与终端面板颜色一致。
                WorkspaceSidebarView(manager: manager, state: state, controller: controller)
                    .frame(width: 240)
            } else {
                WorkspaceCollapsedRail(state: state)
            }

            Divider()

            if let controller {
                GeometryReader { geo in
                    ZStack {
                        TerminalView(
                            ghostty: ghostty,
                            viewModel: controller,
                            delegate: controller
                        )

                        if dockTargeted {
                            WorkspaceDockHighlight(edge: dockEdge, size: geo.size)
                        }

                        // Floating split buttons, Zed-style (top-right).
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 10) {
                                    Button { controller.newWorkspaceSplitTerminal(direction: .right) } label: {
                                        Image(systemName: "rectangle.split.2x1")
                                    }
                                    .buttonStyle(.plain)
                                    .help("向右新建终端")
                                    Button { controller.newWorkspaceSplitTerminal(direction: .down) } label: {
                                        Image(systemName: "rectangle.split.1x2")
                                    }
                                    .buttonStyle(.plain)
                                    .help("向下新建终端")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
                                .padding(8)
                                .opacity(0.75)
                            }
                            Spacer()
                        }
                    }
                    .onDrop(
                        of: [workspaceSessionUTType],
                        delegate: WorkspaceDockDropDelegate(
                            size: geo.size,
                            controller: controller,
                            edge: $dockEdge,
                            targeted: $dockTargeted))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Highlights the half of the terminal area a dragged session would dock into.
struct WorkspaceDockHighlight: View {
    let edge: SplitTree<Ghostty.SurfaceView>.NewDirection?
    let size: CGSize

    var body: some View {
        let rect: CGRect = {
            switch edge {
            case .left: return .init(x: 0, y: 0, width: size.width / 2, height: size.height)
            case .right: return .init(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
            case .up: return .init(x: 0, y: 0, width: size.width, height: size.height / 2)
            case .down: return .init(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
            case nil: return .init(origin: .zero, size: size)
            }
        }()
        return Rectangle()
            .fill(Color.accentColor.opacity(0.16))
            .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeInOut(duration: 0.1), value: rect)
            .allowsHitTesting(false)
    }
}

/// Handles session drags over the terminal area: tracks which edge the cursor
/// is near and performs the dock split on drop.
struct WorkspaceDockDropDelegate: DropDelegate {
    let size: CGSize
    weak var controller: TerminalController?
    @Binding var edge: SplitTree<Ghostty.SurfaceView>.NewDirection?
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [workspaceSessionUTType])
    }

    func dropEntered(info: DropInfo) {
        targeted = true
        edge = Self.dockEdge(at: info.location, in: size)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = Self.dockEdge(at: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        targeted = false
        edge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let finalEdge = edge
        targeted = false
        edge = nil

        guard let provider = info.itemProviders(for: [workspaceSessionUTType]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: workspaceSessionUTType.identifier) { data, _ in
            guard let data,
                  let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                guard let controller,
                      let session = ProjectManager.shared.allSessions.first(where: { $0.id == uuid })
                else { return }
                if let finalEdge {
                    controller.dockWorkspaceSession(session, edge: finalEdge)
                } else {
                    // Dropped in the center: just show that session.
                    controller.activateWorkspaceSession(session)
                }
            }
        }
        return true
    }

    /// Which edge (if any) the point is near. Center returns nil.
    static func dockEdge(
        at point: CGPoint,
        in size: CGSize
    ) -> SplitTree<Ghostty.SurfaceView>.NewDirection? {
        guard size.width > 0, size.height > 0 else { return nil }
        let rx = point.x / size.width
        let ry = point.y / size.height
        let candidates: [(SplitTree<Ghostty.SurfaceView>.NewDirection, CGFloat)] = [
            (.left, rx), (.right, 1 - rx), (.up, ry), (.down, 1 - ry),
        ]
        guard let best = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        return best.1 <= 0.3 ? best.0 : nil
    }
}

/// The project/session sidebar.
struct WorkspaceSidebarView: View {
    @ObservedObject var manager: ProjectManager
    @ObservedObject var state: WorkspaceState
    weak var controller: TerminalController?

    /// True while a folder drag hovers over the sidebar.
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button { controller?.promptNewWorkspaceProject() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .help("新建项目")
                Button { withAnimation(.easeInOut(duration: 0.15)) { state.sidebarVisible = false } } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("收起侧边栏")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
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
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(manager.projects) { project in
                            WorkspaceProjectSection(
                                project: project,
                                state: state,
                                controller: controller)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: project.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(project.path)
                Spacer()
                Button { controller?.newWorkspaceSession(in: project) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("新建对话")
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.12)) { project.expanded.toggle() }
            }
            .contextMenu {
                Button("新建对话") { controller?.newWorkspaceSession(in: project) }
                Button("在访达中打开") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: project.path)])
                }
                Divider()
                Button("移除项目(关闭其所有对话)") { controller?.removeWorkspaceProject(project) }
            }

            if project.expanded {
                if project.sessions.isEmpty {
                    Text("无对话")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary.opacity(0.6))
                        .padding(.leading, 32)
                        .padding(.vertical, 2)
                } else {
                    ForEach(project.sessions) { session in
                        WorkspaceSessionRow(
                            session: session,
                            state: state,
                            controller: controller)
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

    private var isActive: Bool { state.activeSessionID == session.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundColor(isActive ? .primary : .secondary)
            WorkspaceSessionTitle(session: session)
            Spacer()
            if session.tree != nil {
                Circle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .help("会话存活中")
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 21)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { controller?.activateWorkspaceSession(session) }
        .onDrag {
            // Drag a session into the terminal area to dock it as a split.
            let provider = NSItemProvider()
            let uuid = session.id.uuidString
            provider.registerDataRepresentation(
                forTypeIdentifier: workspaceSessionUTType.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(uuid.data(using: .utf8), nil)
                return nil
            }
            return provider
        }
        .contextMenu {
            Button("在访达中打开") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: session.workingDirectory)])
            }
            Divider()
            Button("关闭对话") { controller?.closeWorkspaceSession(session) }
        }
    }
}

/// Session title that live-updates from the terminal title when running.
struct WorkspaceSessionTitle: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        if let surface = session.primarySurface {
            WorkspaceSurfaceTitle(surface: surface, fallback: session.title)
        } else {
            Text(session.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
        }
    }
}

struct WorkspaceSurfaceTitle: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let fallback: String

    var body: some View {
        Text(surface.title.isEmpty ? fallback : surface.title)
            .font(.system(size: 12.5))
            .lineLimit(1)
    }
}
