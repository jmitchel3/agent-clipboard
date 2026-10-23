// Agent Clipboard: menu bar list of commands AI agents queued via `agent-clip add`.
// Click the icon (or ⌘⇧C) for the picker; right-click for settings. ⌃⌥C copies the newest command,
// and a toast appears whenever an agent queues something. Shares ~/.agent-clipboard/clips.jsonl
// (and its flock) with the agent-clip CLI.

import AppKit
import Darwin
import Carbon.HIToolbox
import SwiftUI

let storeDir: URL = {
    if let d = ProcessInfo.processInfo.environment["AGENT_CLIPBOARD_DIR"] { return URL(fileURLWithPath: d) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-clipboard")
}()
let storeURL = storeDir.appendingPathComponent("clips.jsonl")
let lockURL = storeDir.appendingPathComponent(".lock")
let menuLimit = 30
let allProjects = "__all__"
let autoProject = "__auto__"
let shellNames: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh"]

typealias Clip = [String: Any]

func withLock<T>(_ body: () -> T) -> T {
    try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    let fd = open(lockURL.path, O_CREAT | O_WRONLY, 0o644)
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    if fd >= 0 { flock(fd, LOCK_EX) }
    return body()
}

func loadClips() -> [Clip] {
    guard let text = try? String(contentsOf: storeURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? Clip
    }
}

func saveClips(_ clips: [Clip]) {
    let lines = clips.compactMap { c -> String? in
        guard let d = try? JSONSerialization.data(withJSONObject: c, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    let tmp = storeDir.appendingPathComponent("clips.tmp")
    try? (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: false, encoding: .utf8)
    _ = rename(tmp.path, storeURL.path)
}

/// Load, mutate, and save under the shared lock.
func mutate(_ body: (inout [Clip]) -> Void) {
    withLock {
        var clips = loadClips()
        body(&clips)
        saveClips(clips)
    }
}

func clipID(_ c: Clip) -> Int { (c["id"] as? NSNumber)?.intValue ?? -1 }
func isArchived(_ c: Clip) -> Bool { (c["archived"] as? Bool) ?? false }
func copyCount(_ c: Clip) -> Int { (c["copies"] as? [Any])?.count ?? 0 }

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

var projectCache: [String: String] = [:]
let projectCacheLock = NSLock()

/// Same rule as the CLI: git repo name (worktrees resolve to the main repo), else the folder name.
/// Cached per directory so repeat lookups skip spawning git.
func projectName(forDirectory dir: String) -> String {
    projectCacheLock.lock()
    let cached = projectCache[dir]
    projectCacheLock.unlock()
    if let cached { return cached }
    let common = run("/usr/bin/git", ["-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    let name = common.isEmpty ? URL(fileURLWithPath: dir).lastPathComponent
        : URL(fileURLWithPath: common).deletingLastPathComponent().lastPathComponent
    projectCacheLock.lock()
    projectCache[dir] = name
    projectCacheLock.unlock()
    return name
}

/// Compiled once; reused on every lookup. Must run on the main thread.
let ttyScript: NSAppleScript? = {
    let s = NSAppleScript(source: "tell application \"Terminal\" to get tty of selected tab of front window")
    var err: NSDictionary?
    s?.compileAndReturnError(&err)
    return s
}()

/// tty of the front Terminal.app tab, if Terminal is frontmost.
func frontTerminalTTY() -> String? {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" else { return nil }
    var err: NSDictionary?
    guard let tty = ttyScript?.executeAndReturnError(&err).stringValue, tty.hasPrefix("/dev/") else { return nil }
    return tty
}

/// Working directory of the innermost shell on a tty, via libproc (no ps/lsof processes).
func shellDirectory(onTTY tty: String) -> String? {
    var st = stat()
    guard stat(tty, &st) == 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: 256)
    let bytes = proc_listpids(UInt32(PROC_TTY_ONLY), UInt32(st.st_rdev), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return nil }
    let shells = pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { pid in
        guard pid > 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return shellNames.contains(String(cString: name))
    }
    // The innermost (newest) shell on the tty reflects the latest `cd`.
    guard let pid = shells.max() else { return nil }
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
}

func preview(_ cmd: String, width: Int = 60) -> String {
    let lines = cmd.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    var line = lines.first ?? ""
    if line.count > width { line = String(line.prefix(width - 1)) + "…" }
    else if lines.count > 1 { line += " …" }
    return line
}

// MARK: - Shared actions

/// Copies a clip to the pasteboard and records the copy in the log.
@discardableResult
func copyClip(id: Int) -> String? {
    var cmd: String?
    mutate { clips in
        guard let i = clips.firstIndex(where: { clipID($0) == id }) else { return }
        cmd = clips[i]["cmd"] as? String
        var copies = (clips[i]["copies"] as? [Any]) ?? []
        copies.append(Date().timeIntervalSince1970)
        clips[i]["copies"] = copies
    }
    if let cmd {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }
    return cmd
}

func archiveClips(_ ids: Set<Int>) {
    mutate { clips in
        for i in clips.indices where ids.contains(clipID(clips[i])) { clips[i]["archived"] = true }
    }
}

struct ClipRow: Identifiable {
    let id: Int
    let cmd: String
    let project: String
    let note: String
    let ts: Double
    let copied: Bool

    init(_ c: Clip) {
        id = clipID(c)
        cmd = ((c["cmd"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        project = (c["project"] as? String) ?? ""
        note = (c["note"] as? String) ?? ""
        ts = (c["ts"] as? NSNumber)?.doubleValue ?? 0
        copied = copyCount(c) > 0
    }

    var age: String {
        let s = Date().timeIntervalSince1970 - ts
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

// MARK: - Global hotkeys (Carbon: no Accessibility permission needed)

var hotKeyHandlers: [UInt32: () -> Void] = [:]
var hotKeyRefs: [EventHotKeyRef?] = []

func registerHotKey(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
    if hotKeyHandlers.isEmpty {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            hotKeyHandlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
    hotKeyHandlers[id] = handler
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4143_4C50), id: id),
                        GetApplicationEventTarget(), 0, &ref)
    hotKeyRefs.append(ref)
}

// MARK: - Floating panels

final class FloatingPanel: NSPanel {
    var focusable = false
    override var canBecomeKey: Bool { focusable }

    init(focusable: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.focusable = focusable
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
}

/// Lets the first click land on a panel that belongs to a background app.
final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func screenWithMouse() -> NSScreen {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

// MARK: - Picker (⌘⇧C)

final class PickerModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    /// Project being shown; nil means all projects.
    @Published var scope: String? { didSet { selection = 0 } }
    @Published var rows: [ClipRow] = []
    /// Project of the front Terminal tab, pinned first in the tab strip.
    var home: String?

    /// Home first, then projects by most recent clip, then All (nil).
    var scopes: [String?] {
        var names: [String] = home.map { [$0] } ?? []
        for r in rows where !names.contains(r.project) { names.append(r.project) }
        return names.map { Optional($0) } + [nil]
    }

    func pending(_ scope: String?) -> Int {
        rows.filter { !$0.copied && (scope == nil || $0.project == scope) }.count
    }

    func step(_ delta: Int) {
        let all = scopes
        let i = all.firstIndex(of: scope) ?? 0
        scope = all[(i + delta + all.count) % all.count]
    }

    var items: [ClipRow] {
        let scoped = rows.filter { scope == nil || $0.project == scope }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(scoped.prefix(50)) }
        return Array(scoped.filter {
            $0.cmd.localizedCaseInsensitiveContains(q) || $0.note.localizedCaseInsensitiveContains(q)
                || $0.project.localizedCaseInsensitiveContains(q)
        }.prefix(50))
    }

    func reload() {
        rows = loadClips().filter { !isArchived($0) }.map(ClipRow.init).reversed()
        selection = min(selection, max(items.count - 1, 0))
    }
}

struct RowView: View {
    let row: ClipRow
    let index: Int
    let selected: Bool
    let showProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index < 9 ? "\(index + 1)" : " ")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.cmd)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if !row.copied { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    if showProject { Text(row.project).fontWeight(.medium) }
                    if !row.note.isEmpty { Text(row.note) }
                    Text(row.age)
                    if row.copied { Image(systemName: "checkmark") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }
}

struct ProjectTabs: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.scopes, id: \.self) { scope in
                        tab(scope).id(scope ?? allProjects).onTapGesture { model.scope = scope }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .onChange(of: model.scope) { _, s in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(s ?? allProjects, anchor: .center) }
            }
        }
    }

    func tab(_ scope: String?) -> some View {
        let selected = scope == model.scope
        let count = model.pending(scope)
        return HStack(spacing: 5) {
            if scope != nil && scope == model.home { Image(systemName: "terminal").font(.system(size: 10)) }
            Text(scope ?? "All").font(.system(size: 12, weight: selected ? .semibold : .regular))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.2)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
        .contentShape(Capsule())
    }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    let onCopy: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                TextField("Search queued commands", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ProjectTabs(model: model)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if items.isEmpty {
                            Text(model.query.isEmpty ? "No commands queued" : "No matches")
                                .foregroundStyle(.secondary)
                                .padding(30)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, row in
                            RowView(row: row, index: i, selected: i == model.selection, showProject: model.scope == nil)
                                .id(row.id)
                                .onTapGesture { onCopy(row.id) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, s in
                    if s < items.count { proxy.scrollTo(items[s].id) }
                }
            }
            .frame(height: 360)
            Divider()
            HStack(spacing: 14) {
                Text("↩ copy")
                Text("⌘1–9 quick copy")
                Text("⌥↩ archive")
                Text("←/→ or tab  project")
                Spacer()
                Text("esc")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .onAppear { focused = true }
    }
}

final class PickerController {
    let model = PickerModel()
    let panel = FloatingPanel(focusable: true)
    var keyMonitor: Any?
    var onCopied: ((Int, String) -> Void)?

    init() {
        let host = ClickThroughHostingView(rootView: PickerView(model: model) { [weak self] id in self?.copy(id) })
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in self?.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show(project: String?) {
        model.home = project
        model.scope = project
        model.query = ""
        model.reload()
        model.selection = 0
        let size = panel.contentView!.fittingSize
        let frame = screenWithMouse().visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - frame.height * 0.18,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
        }
    }

    var lastHidden = Date.distantPast

    func hide() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if panel.isVisible { lastHidden = Date() }
        panel.orderOut(nil)
    }

    func copy(_ id: Int) {
        hide()
        if let cmd = copyClip(id: id) { onCopied?(id, cmd) }
    }

    func handle(_ e: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return e }
        let items = model.items
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(e.keyCode) {
        case kVK_Escape:
            hide()
        case kVK_DownArrow:
            model.selection = min(model.selection + 1, max(items.count - 1, 0))
        case kVK_UpArrow:
            model.selection = max(model.selection - 1, 0)
        case kVK_Tab:
            model.step(mods.contains(.shift) ? -1 : 1)
        case kVK_LeftArrow, kVK_RightArrow:
            // Arrows edit the search text once there is some; otherwise they switch project.
            guard model.query.isEmpty else { return e }
            model.step(Int(e.keyCode) == kVK_RightArrow ? 1 : -1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard model.selection < items.count else { return nil }
            let id = items[model.selection].id
            if mods.contains(.option) {
                archiveClips([id])
                model.reload()
            } else {
                copy(id)
            }
        default:
            if mods.contains(.command), let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                if n - 1 < items.count { copy(items[n - 1].id) }
                return nil
            }
            return e
        }
        return nil
    }
}

// MARK: - Toast

struct ToastView: View {
    let title: String
    let cmd: String
    let note: String
    let footer: String
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(cmd)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if !footer.isEmpty {
                Text(footer).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }
}

final class ToastController {
    let panel = FloatingPanel(focusable: false)
    var dismiss: DispatchWorkItem?
    var onClick: (() -> Void)?
    /// Clip a sticky toast is offering, so it can close once that clip is copied elsewhere.
    var clipID: Int?

    /// `seconds: nil` keeps the toast up until it is clicked or closed.
    func show(title: String, cmd: String, note: String = "", footer: String = "", seconds: Double?,
              clipID: Int? = nil, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        self.clipID = clipID
        let close: (() -> Void)? = seconds == nil ? { [weak self] in self?.hide() } : nil
        let view = ToastView(title: title, cmd: cmd, note: note, footer: footer, onClose: close)
            .onTapGesture { [weak self] in
                let action = self?.onClick
                self?.hide()
                action?()
            }
        let host = ClickThroughHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        let frame = screenWithMouse().visibleFrame
        panel.setFrame(NSRect(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        dismiss?.cancel()
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        dismiss?.cancel()
        clipID = nil
        panel.orderOut(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let picker = PickerController()
    let toast = ToastController()
    var lastMtime: Date?
    var lastSeenID = 0
    /// Project of the front terminal tab, resolved when the menu opens or Terminal is activated.
    var activeProject: String?
    var filterSetting: String {
        get { UserDefaults.standard.string(forKey: "projectFilter") ?? autoProject }
        set { UserDefaults.standard.set(newValue, forKey: "projectFilter") }
    }
    /// The project actually filtered on; Auto falls back to All when no terminal project is known.
    var filter: String {
        filterSetting == autoProject ? (activeProject ?? allProjects) : filterSetting
    }
    var toastsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "toasts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "toasts") }
    }

    func resolveActiveProject() {
        guard filterSetting == autoProject, let tty = frontTerminalTTY(), let dir = shellDirectory(onTTY: tty) else { return }
        activeProject = projectName(forDirectory: dir)
    }

    /// Asks Terminal for the tab on main, does the rest off main, then hands back the project if it changed.
    func resolveActiveProjectAsync(_ changed: @escaping () -> Void) {
        guard filterSetting == autoProject, let tty = frontTerminalTTY() else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            guard let dir = shellDirectory(onTTY: tty) else { return }
            let project = projectName(forDirectory: dir)
            DispatchQueue.main.async {
                guard project != self.activeProject else { return }
                self.activeProject = project
                changed()
            }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        lastSeenID = loadClips().map(clipID).max() ?? 0
        refreshBadge()
        picker.onCopied = { [weak self] id, cmd in self?.confirmCopy(id, cmd) }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollStore() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resolveActiveProjectAsync { self?.refreshBadge() }
        }
        registerHotKey(id: 1, keyCode: kVK_ANSI_C, modifiers: cmdKey | shiftKey) { [weak self] in self?.togglePicker() }
        registerHotKey(id: 2, keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in self?.copyNewest() }
    }

    func visibleClips(_ clips: [Clip]) -> [Clip] {
        clips.filter { !isArchived($0) && (filter == allProjects || ($0["project"] as? String) == filter) }
    }

    func pollStore() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: storeURL.path))?[.modificationDate] as? Date
        guard mtime != lastMtime else { return }
        lastMtime = mtime
        let clips = loadClips()
        let fresh = clips.filter { clipID($0) > lastSeenID && !isArchived($0) }
        lastSeenID = max(lastSeenID, clips.map(clipID).max() ?? 0)
        refreshBadge()
        if picker.isVisible { picker.model.reload() }
        if let id = toast.clipID, clips.contains(where: { clipID($0) == id && (copyCount($0) > 0 || isArchived($0)) }) {
            toast.hide()
        }
        if toastsEnabled, let newest = fresh.last {
            let row = ClipRow(newest)
            let more = fresh.count > 1 ? "  (+\(fresh.count - 1) more)" : ""
            toast.show(title: "\(row.project) · #\(row.id)\(more)", cmd: row.cmd, note: row.note,
                       footer: "Click to copy  ·  ⌘⇧C picker  ·  ⌃⌥C copy newest", seconds: nil,
                       clipID: row.id) { [weak self] in
                if let cmd = copyClip(id: row.id) { self?.confirmCopy(row.id, cmd) }
            }
        }
    }

    func refreshBadge() {
        let pending = visibleClips(loadClips()).filter { copyCount($0) == 0 }.count
        guard let button = statusItem.button else { return }
        let symbol = pending > 0 ? "doc.on.clipboard.fill" : "doc.on.clipboard"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agent Clipboard")
        button.imagePosition = .imageLeading
        button.title = pending > 0 ? " \(pending)" : ""
    }

    func confirmCopy(_ id: Int, _ cmd: String) {
        refreshBadge()
        toast.show(title: "Copied #\(id)", cmd: cmd, seconds: 1.6)
    }

    /// Left click opens the picker; right or ⌃-click shows the settings menu.
    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePicker()
        }
    }

    func togglePicker() {
        if picker.isVisible { picker.hide(); return }
        // Clicking the icon while the picker is open closes it via resign-key first; don't reopen.
        if Date().timeIntervalSince(picker.lastHidden) < 0.3 { return }
        // Draw immediately with the last known project; correct it if the front tab differs.
        picker.show(project: filter == allProjects ? nil : filter)
        DispatchQueue.main.async { [weak self] in
            self?.resolveActiveProjectAsync {
                guard let self, self.picker.isVisible else { return }
                let project = self.filter == allProjects ? nil : self.filter
                self.picker.model.home = project
                self.picker.model.scope = project
                self.picker.model.selection = 0
                self.refreshBadge()
            }
        }
    }

    /// Newest uncopied clip in the current filter, else the newest one.
    func copyNewest() {
        resolveActiveProject()
        let shown = visibleClips(loadClips())
        guard let clip = shown.last(where: { copyCount($0) == 0 }) ?? shown.last else {
            toast.show(title: "Nothing queued", cmd: filter == allProjects ? "" : filter, seconds: 1.6)
            return
        }
        if let cmd = copyClip(id: clipID(clip)) { confirmCopy(clipID(clip), cmd) }
    }

    // Rebuild on every open so the menu always reflects the file.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        resolveActiveProject()
        refreshBadge()
        let clips = loadClips()
        let shown = visibleClips(clips)

        let projectCounts = Dictionary(grouping: clips.filter { !isArchived($0) }) { ($0["project"] as? String) ?? "?" }
            .mapValues(\.count)
        let label = filter == allProjects ? "All" : filter
        let filterItem = NSMenuItem(title: "Project: \(label)\(filterSetting == autoProject ? "  (auto)" : "")", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let autoItem = NSMenuItem(title: "Auto (front Terminal tab)", action: #selector(setFilter(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = autoProject
        autoItem.state = filterSetting == autoProject ? .on : .off
        sub.addItem(autoItem)
        let allItem = NSMenuItem(title: "All", action: #selector(setFilter(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = allProjects
        allItem.state = filterSetting == allProjects ? .on : .off
        sub.addItem(allItem)
        sub.addItem(.separator())
        for name in projectCounts.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let item = NSMenuItem(title: "\(name)  (\(projectCounts[name]!))", action: #selector(setFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = filterSetting == name ? .on : .off
            sub.addItem(item)
        }
        filterItem.submenu = sub
        menu.addItem(filterItem)
        menu.addItem(.separator())

        if shown.isEmpty {
            let empty = NSMenuItem(title: filter == allProjects ? "No commands queued" : "No commands queued for \(filter)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for clip in shown.suffix(menuLimit).reversed() {
            let cmd = (clip["cmd"] as? String) ?? ""
            let project = (clip["project"] as? String) ?? ""
            let note = (clip["note"] as? String) ?? ""
            let prefix = filter == allProjects ? "[\(project)]  " : ""

            let item = NSMenuItem(title: prefix + preview(cmd), action: #selector(copyMenuClip(_:)), keyEquivalent: "")
            item.target = self
            item.tag = clipID(clip)
            item.state = copyCount(clip) > 0 ? .on : .off
            if !note.isEmpty, #available(macOS 14.4, *) { item.subtitle = note }
            item.toolTip = (note.isEmpty ? "" : note + "\n\n") + cmd
            menu.addItem(item)

            let alt = NSMenuItem(title: "Archive: " + preview(cmd), action: #selector(archiveClip(_:)), keyEquivalent: "")
            alt.target = self
            alt.tag = clipID(clip)
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            menu.addItem(alt)
        }

        menu.addItem(.separator())
        addAction("Open picker  (⌘⇧C)", #selector(openPicker))
        addAction("Copy newest  (⌃⌥C)", #selector(copyNewestAction))
        let toastItem = NSMenuItem(title: "Toast on new commands", action: #selector(toggleToasts), keyEquivalent: "")
        toastItem.target = self
        toastItem.state = toastsEnabled ? .on : .off
        menu.addItem(toastItem)
        menu.addItem(.separator())
        addAction("Archive copied", #selector(archiveCopied))
        addAction("Archive all shown", #selector(archiveAllShown))
        addAction("Open log file", #selector(openLog))
        menu.addItem(.separator())
        addAction("Quit Agent Clipboard", #selector(quit))
    }

    func addAction(_ title: String, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc func setFilter(_ sender: NSMenuItem) {
        filterSetting = (sender.representedObject as? String) ?? autoProject
        refreshBadge()
    }

    @objc func copyMenuClip(_ sender: NSMenuItem) {
        copyClip(id: sender.tag)
        refreshBadge()
    }

    @objc func openPicker() { DispatchQueue.main.async { self.togglePicker() } }
    @objc func copyNewestAction() { copyNewest() }
    @objc func toggleToasts() { toastsEnabled.toggle() }

    func archive(where pred: (Clip) -> Bool) {
        archiveClips(Set(loadClips().filter(pred).map(clipID)))
        refreshBadge()
    }

    @objc func archiveClip(_ sender: NSMenuItem) { archive { clipID($0) == sender.tag } }
    @objc func archiveCopied() {
        let ids = Set(visibleClips(loadClips()).filter { copyCount($0) > 0 }.map(clipID))
        archive { ids.contains(clipID($0)) }
    }
    @objc func archiveAllShown() {
        let ids = Set(visibleClips(loadClips()).map(clipID))
        archive { ids.contains(clipID($0)) }
    }
    @objc func openLog() { NSWorkspace.shared.open(storeURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
