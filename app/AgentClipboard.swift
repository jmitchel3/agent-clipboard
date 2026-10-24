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

/// One line of clips.jsonl. Lines that don't parse are written back verbatim, never dropped.
struct StoreLine {
    var raw: String
    var clip: Clip?
}

/// `match` limits JSON parsing to lines that could be relevant; the rest stay raw.
func loadLines(parsing match: (String) -> Bool = { _ in true }) -> [StoreLine] {
    guard let data = try? Data(contentsOf: storeURL) else { return [] }
    return data.split(separator: UInt8(ascii: "\n")).compactMap { slice in
        let raw = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let clip = match(raw) ? (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? Clip : nil
        return StoreLine(raw: raw, clip: clip)
    }
}

func saveLines(_ lines: [StoreLine]) {
    var text = ""
    text.reserveCapacity(lines.reduce(0) { $0 + $1.raw.utf8.count + 1 })
    for l in lines { text += l.raw; text += "\n" }
    let tmp = storeDir.appendingPathComponent("clips.tmp")
    guard (try? text.write(to: tmp, atomically: false, encoding: .utf8)) != nil else { return }
    _ = rename(tmp.path, storeURL.path)
}

/// Load, mutate the clips with these ids, and save, all under the shared lock. Only lines that
/// mention one of the ids are parsed; everything else is copied through untouched.
@discardableResult
func mutate(ids: Set<Int>, _ body: (inout Clip) -> Void) -> [Clip] {
    withLock {
        let needles = ids.count <= 32 ? ids.map(String.init) : nil
        var lines = loadLines { raw in needles?.contains { raw.contains($0) } ?? true }
        var changed: [Clip] = []
        for i in lines.indices {
            guard var c = lines[i].clip, ids.contains(clipID(c)) else { continue }
            body(&c)
            guard let d = try? JSONSerialization.data(withJSONObject: c, options: [.withoutEscapingSlashes]),
                  let raw = String(data: d, encoding: .utf8) else { continue }
            lines[i] = StoreLine(raw: raw, clip: c)
            changed.append(c)
        }
        if !changed.isEmpty { saveLines(lines) }
        return changed
    }
}

func clipID(_ c: Clip) -> Int { (c["id"] as? NSNumber)?.intValue ?? -1 }
func copyCount(_ c: Clip) -> Int { (c["copies"] as? [Any])?.count ?? 0 }

/// A real `"archived": true` key; inside a JSON string the quotes would be escaped, so this can't
/// match command text. Lets the store skip parsing archived lines, which are most of the log.
func isArchivedLine(_ raw: String) -> Bool {
    raw.contains("\"archived\":true") || raw.contains("\"archived\": true")
}

/// In-memory view of the non-archived clips, reparsed only when the file actually changes.
final class ClipStore {
    private(set) var rows: [ClipRow] = []
    private var stamp: [Int] = []

    /// Returns true if the file changed since the last call.
    @discardableResult
    func refresh() -> Bool {
        var st = stat()
        let now = stat(storeURL.path, &st) == 0
            ? [Int(st.st_ino), Int(st.st_size), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec] : []
        guard now != stamp else { return false }
        stamp = now
        rows = loadLines { !isArchivedLine($0) }.compactMap { line in
            guard let c = line.clip, (c["archived"] as? Bool) != true, clipID(c) >= 0 else { return nil }
            return ClipRow(c)
        }
        return true
    }
}

/// Watches the store directory (atomic renames) and the file itself (appends) with kqueue,
/// so the app sleeps until something writes instead of polling.
final class StoreWatcher {
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var scheduled = false
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        dirSource = watch(storeDir.path, [.write]) { [weak self] in self?.changed() }
        watchFile()
    }

    private func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                       _ handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler(handler: handler)
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    /// Re-armed on every event: a rename replaces the inode the old source was watching.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = watch(storeURL.path, [.write, .extend, .delete, .rename]) { [weak self] in self?.changed() }
    }

    private func changed() {
        watchFile()
        guard !scheduled else { return }
        scheduled = true
        // Coalesce the burst of events one write produces.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.scheduled = false
            self?.onChange()
        }
    }
}

func realPath(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}

/// What `git rev-parse --git-common-dir` prints, read straight from .git (no git process).
func gitCommonDir(from dir: String) -> String? {
    let fm = FileManager.default
    var url = URL(fileURLWithPath: dir)
    while true {
        let dotgit = url.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotgit.path, isDirectory: &isDir) {
            if isDir.boolValue {
                if fm.fileExists(atPath: dotgit.appendingPathComponent("HEAD").path) { return dotgit.path }
            } else if let text = try? String(contentsOf: dotgit, encoding: .utf8), text.hasPrefix("gitdir:") {
                let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                let gitdir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
                if fm.fileExists(atPath: gitdir.appendingPathComponent("HEAD").path) {
                    guard let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8)
                    else { return gitdir.path }
                    let c = common.trimmingCharacters(in: .newlines)
                    return c.hasPrefix("/") ? c : gitdir.appendingPathComponent(c).path
                }
            }
        }
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path { return nil }
        url = parent
    }
}

/// Same rule as the CLI: git repo name (worktrees resolve to the main repo), else the folder name.
func projectName(forDirectory dir: String) -> String {
    guard let common = gitCommonDir(from: dir) else { return URL(fileURLWithPath: dir).lastPathComponent }
    return URL(fileURLWithPath: realPath(common)).deletingLastPathComponent().lastPathComponent
}

func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

func objectSpecifier(_ want: String, in container: NSAppleEventDescriptor, form: String,
                     _ data: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    let rec = NSAppleEventDescriptor.record()
    rec.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(want)), forKeyword: AEKeyword(keyAEDesiredClass))
    rec.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
    rec.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC(form)), forKeyword: AEKeyword(keyAEKeyForm))
    rec.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
    return rec.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? rec
}

/// `get tty of selected tab of front window` as a raw Apple Event. Same answer and permission as the
/// AppleScript, without loading the AppleScript interpreter (about 15 MB and 50 ms on first use).
let ttyEvent: NSAppleEventDescriptor = {
    let window = objectSpecifier("cwin", in: .null(), form: "indx", NSAppleEventDescriptor(int32: 1))
    let tab = objectSpecifier("prop", in: window, form: "prop", NSAppleEventDescriptor(typeCode: fourCC("tcnt")))
    let tty = objectSpecifier("prop", in: tab, form: "prop", NSAppleEventDescriptor(typeCode: fourCC("ttty")))
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                       targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal"),
                                       returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(tty, forKeyword: AEKeyword(keyDirectObject))
    return event
}()

/// tty of the front Terminal.app tab, if Terminal is frontmost.
func frontTerminalTTY() -> String? {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal",
          let reply = try? ttyEvent.sendEvent(options: [.waitForReply], timeout: 1),
          let tty = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
          tty.hasPrefix("/dev/") else { return nil }
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
    let cmd = mutate(ids: [id]) { c in
        c["copies"] = ((c["copies"] as? [Any]) ?? []) + [Date().timeIntervalSince1970]
    }.first?["cmd"] as? String
    if let cmd {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }
    return cmd
}

func archiveClips(_ ids: Set<Int>) {
    mutate(ids: ids) { $0["archived"] = true }
}

struct ClipRow: Identifiable {
    let id: Int
    let cmd: String
    let project: String
    let note: String
    let ts: Double
    let copies: Int
    var copied: Bool { copies > 0 }

    init(_ c: Clip) {
        id = clipID(c)
        cmd = ((c["cmd"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        project = (c["project"] as? String) ?? ""
        note = (c["note"] as? String) ?? ""
        ts = (c["ts"] as? NSNumber)?.doubleValue ?? 0
        copies = copyCount(c)
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

/// Lets the first click land on a panel that belongs to a background app, and reports hover even
/// though this app is never active (SwiftUI's onHover only fires in the active app).
final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    var onHover: ((Bool) -> Void)? { didSet { updateTrackingAreas() } }
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard onHover != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHover?(false) }
    }
}

func screenWithMouse() -> NSScreen {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

// MARK: - Picker (⌘⇧C)

final class PickerModel: ObservableObject {
    @Published var query = "" { didSet { refilter() } }
    @Published var selection = 0
    /// Project being shown; nil means all projects.
    @Published var scope: String? { didSet { refilter() } }
    /// Filtered rows for the current scope and query, recomputed only when one of those changes.
    @Published private(set) var items: [ClipRow] = []
    /// Home first, then projects by most recent clip, then All (nil).
    @Published private(set) var scopes: [String?] = [nil]
    /// Project of the front Terminal tab, pinned first in the tab strip.
    var home: String? { didSet { rebuildScopes() } }
    private var rows: [ClipRow] = []
    private var pendingByProject: [String: Int] = [:]
    private var pendingTotal = 0

    func pending(_ scope: String?) -> Int {
        scope.map { pendingByProject[$0] ?? 0 } ?? pendingTotal
    }

    func step(_ delta: Int) {
        let all = scopes
        let i = all.firstIndex(of: scope) ?? 0
        scope = all[(i + delta + all.count) % all.count]
    }

    /// Newest first.
    func load(_ newest: [ClipRow]) {
        rows = newest
        pendingByProject = [:]
        for r in rows where !r.copied { pendingByProject[r.project, default: 0] += 1 }
        pendingTotal = pendingByProject.values.reduce(0, +)
        rebuildScopes()
        let keep = selection
        refilter()
        selection = min(keep, max(items.count - 1, 0))
    }

    private func rebuildScopes() {
        var names: [String] = home.map { [$0] } ?? []
        var seen = Set(names)
        for r in rows where seen.insert(r.project).inserted { names.append(r.project) }
        scopes = names.map { Optional($0) } + [nil]
    }

    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        defer { selection = 0 }
        // Typing 34 or #34 jumps straight to that clip, in any project.
        if let id = Int(q.hasPrefix("#") ? String(q.dropFirst()) : q), let hit = rows.first(where: { $0.id == id }) {
            items = [hit]
            return
        }
        var out: [ClipRow] = []
        for r in rows where scope == nil || r.project == scope {
            if q.isEmpty || r.cmd.localizedCaseInsensitiveContains(q) || r.note.localizedCaseInsensitiveContains(q)
                || r.project.localizedCaseInsensitiveContains(q) {
                out.append(r)
                if out.count == 50 { break }
            }
        }
        items = out
    }
}

struct RowView: View {
    let row: ClipRow
    let index: Int
    let selected: Bool
    let showProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("#\(row.id)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
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
                    Spacer(minLength: 0)
                    if index < 9 { Text("⌘\(index + 1)").font(.system(size: 10, design: .monospaced)) }
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
    let store: ClipStore
    var keyMonitor: Any?
    var onCopied: ((Int, String) -> Void)?

    init(store: ClipStore) {
        self.store = store
        let host = ClickThroughHostingView(rootView: PickerView(model: model) { [weak self] id in self?.copy(id) })
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in self?.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func reload() {
        store.refresh()
        model.load(store.rows.reversed())
    }

    func show(project: String?) {
        model.home = project
        model.query = ""
        reload()
        model.scope = project
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
                reload()
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

final class ToastModel: ObservableObject {
    enum Style { case pending, copied, info }
    @Published var style = Style.info
    @Published var title = ""
    @Published var cmd = ""
    @Published var note = ""
    @Published var footer = ""
    /// Brief green wash when a copied toast is clicked again.
    @Published var flash = false
}

struct ToastView: View {
    @ObservedObject var model: ToastModel
    var onClose: () -> Void

    var body: some View {
        let copied = model.style == .copied
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
                Text(model.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : Color.primary)
                Spacer()
                if model.style != .info {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !model.cmd.isEmpty {
                Text(model.cmd)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.note.isEmpty {
                Text(model.note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if !model.footer.isEmpty {
                Text(model.footer).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(model.flash ? 0.25 : copied ? 0.08 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(copied ? Color.green.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: copied ? 1.5 : 1))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: model.style)
        .animation(.easeOut(duration: 0.25), value: model.flash)
    }
}

/// One toast that changes state in place: pending (sticky, offers a new clip), copied (green, fades
/// slowly; hover holds it, click copies again), info (brief). ✕ shatters it.
final class ToastController {
    let model = ToastModel()
    let panel = FloatingPanel(focusable: false)
    var onClick: (() -> Void)?
    /// Clip a pending toast is offering, so it can close once that clip is copied elsewhere.
    var clipID: Int?
    private var host: ClickThroughHostingView<AnyView>?
    private var timer: DispatchWorkItem?
    /// Bumped on every state change so stale fade completions are ignored.
    private var generation = 0
    private var hovering = false
    private var hold: Double?
    private var fade = 0.0
    private var shards: NSPanel?

    func show(_ style: ToastModel.Style, title: String, cmd: String, note: String = "", footer: String = "",
              clipID: Int? = nil, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        self.clipID = style == .pending ? clipID : nil
        let wasCopied = panel.isVisible && model.style == .copied && style == .copied
        model.style = style
        model.title = title
        model.cmd = cmd
        model.note = note
        model.footer = footer
        switch style {
        case .pending: (hold, fade) = (nil, 0)
        case .copied: (hold, fade) = (1.5, 3.5)
        case .info: (hold, fade) = (1.2, 0.6)
        }
        if wasCopied { pulse() }
        present()
        schedule()
    }

    private func present() {
        if host == nil {
            let view = ToastView(model: model) { [weak self] in self?.shatter() }
                .onTapGesture { [weak self] in self?.onClick?() }
            let h = ClickThroughHostingView(rootView: AnyView(view))
            h.onHover = { [weak self] inside in self?.hover(inside) }
            host = h
            panel.contentView = h
        }
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? .zero
        // Keep the top-right corner pinned while the height changes between states.
        let screen = panel.isVisible ? (panel.screen ?? screenWithMouse()) : screenWithMouse()
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func pulse() {
        model.flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.model.flash = false }
    }

    /// Hold fully visible, then fade out; hovering cancels and restarts it on exit.
    private func schedule() {
        generation += 1
        timer?.cancel()
        guard let hold, !hovering else { return }
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = self.fade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, gen == self.generation else { return }
                self.hide()
            })
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    func hover(_ inside: Bool) {
        hovering = inside
        guard panel.isVisible, hold != nil else { return }
        if inside {
            generation += 1
            timer?.cancel()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            schedule()
        }
    }

    func hide() {
        generation += 1
        timer?.cancel()
        clipID = nil
        onClick = nil
        hovering = false
        panel.orderOut(nil)
        panel.contentView = nil
        host = nil
    }

    // MARK: Shatter

    /// Breaks the toast into glass shards that burst away from the ✕ and fall.
    func shatter() {
        guard panel.isVisible, let host, let image = snapshot(host) else { hide(); return }
        let size = host.bounds.size
        let pad: CGFloat = 260
        let overlay = FloatingPanel(focusable: false)
        overlay.ignoresMouseEvents = true
        overlay.hasShadow = false
        overlay.setFrame(panel.frame.insetBy(dx: -pad, dy: -pad), display: false)
        let root = NSView(frame: NSRect(origin: .zero, size: overlay.frame.size))
        root.wantsLayer = true
        overlay.contentView = root
        let scale = panel.backingScaleFactor

        // Jittered grid, each cell split into two triangles.
        let cols = 9, rows = 4
        var pts: [[CGPoint]] = []
        for r in 0...rows {
            pts.append((0...cols).map { c in
                let edgeX = c == 0 || c == cols, edgeY = r == 0 || r == rows
                let jx = edgeX ? 0 : CGFloat.random(in: -0.35...0.35) * size.width / CGFloat(cols)
                let jy = edgeY ? 0 : CGFloat.random(in: -0.35...0.35) * size.height / CGFloat(rows)
                return CGPoint(x: CGFloat(c) * size.width / CGFloat(cols) + jx,
                               y: CGFloat(r) * size.height / CGFloat(rows) + jy)
            })
        }
        // ✕ sits top-right; layer space is y-up.
        let impact = CGPoint(x: size.width - 20, y: size.height - 18)
        var longest = 0.0
        for r in 0..<rows {
            for c in 0..<cols {
                let a = pts[r][c], b = pts[r][c + 1], d = pts[r + 1][c], e = pts[r + 1][c + 1]
                for tri in [[a, b, e], [a, e, d]] {
                    longest = max(longest, addShard(tri, image: image, size: size, pad: pad, scale: scale,
                                                    impact: impact, to: root.layer!))
                }
            }
        }
        panel.orderOut(nil)
        overlay.orderFrontRegardless()
        shards = overlay
        let finish = { [weak self, weak overlay] in
            overlay?.orderOut(nil)
            if self?.shards === overlay { self?.shards = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + longest + 0.05, execute: finish)
        hide()
    }

    private func addShard(_ tri: [CGPoint], image: CGImage, size: CGSize, pad: CGFloat, scale: CGFloat,
                          impact: CGPoint, to root: CALayer) -> Double {
        let minX = tri.map(\.x).min()!, maxX = tri.map(\.x).max()!
        let minY = tri.map(\.y).min()!, maxY = tri.map(\.y).max()!
        let box = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))

        let shard = CALayer()
        shard.frame = box.offsetBy(dx: pad, dy: pad)
        let picture = CALayer()
        picture.frame = CGRect(x: -box.minX, y: -box.minY, width: size.width, height: size.height)
        picture.contents = image
        picture.contentsScale = scale
        shard.addSublayer(picture)
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addLines(between: tri.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) })
        path.closeSubpath()
        mask.path = path
        shard.mask = mask
        root.addSublayer(shard)

        let center = CGPoint(x: box.midX, y: box.midY)
        var dx = center.x - impact.x, dy = center.y - impact.y
        let dist = max(hypot(dx, dy), 1)
        (dx, dy) = (dx / dist, dy / dist)
        // Shards near the ✕ fly hardest.
        let force = CGFloat.random(in: 90...170) * (1.4 - min(dist / size.width, 1))
        let duration = Double.random(in: 0.55...0.85)
        let start = shard.position
        let end = CGPoint(x: start.x + dx * force * 1.6 + CGFloat.random(in: -20...20),
                          y: start.y + dy * force * 0.6 - CGFloat.random(in: 120...220))

        let move = CAKeyframeAnimation(keyPath: "position")
        let arc = CGMutablePath()
        arc.move(to: start)
        arc.addQuadCurve(to: end, control: CGPoint(x: start.x + dx * force, y: start.y + max(dy, 0) * force + 30))
        move.path = arc
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.toValue = CGFloat.random(in: -3...3)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.toValue = CGFloat.random(in: 0.5...0.85)
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 1
        vanish.toValue = 0
        vanish.timingFunction = CAMediaTimingFunction(controlPoints: 0.6, 0, 1, 1)

        let group = CAAnimationGroup()
        group.animations = [move, spin, shrink, vanish]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        shard.opacity = 0
        shard.add(group, forKey: "shatter")
        return duration
    }

    /// The material background doesn't render offscreen, so paint an opaque stand-in behind the content.
    private func snapshot(_ view: NSView) -> CGImage? {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
                NSColor.windowBackgroundColor.setFill()
                shape.fill()
                NSColor.separatorColor.setStroke()
                shape.stroke()
            }
            rep.draw(in: rect)
            return true
        }
        var rect = CGRect(origin: .zero, size: bounds.size)
        return image.cgImage(forProposedRect: &rect, context: nil,
                             hints: [.ctm: AffineTransform(scale: view.window?.backingScaleFactor ?? 2)])
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let store = ClipStore()
    /// Built on first use so the SwiftUI picker costs nothing until it is opened.
    lazy var picker: PickerController = {
        let p = PickerController(store: store)
        p.onCopied = { [weak self] id, cmd in self?.confirmCopy(id, cmd) }
        return p
    }()
    var pickerLoaded = false
    let toast = ToastController()
    var watcher: StoreWatcher?
    var lastSeenID = 0
    var badgeCount = -1
    let badgeImages = (empty: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Agent Clipboard"),
                       full: NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "Agent Clipboard"))
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
        statusItem.button?.imagePosition = .imageLeading
        store.refresh()
        lastSeenID = store.rows.map(\.id).max() ?? 0
        refreshBadge()
        watcher = StoreWatcher { [weak self] in self?.storeChanged() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resolveActiveProjectAsync { self?.refreshBadge() }
        }
        registerHotKey(id: 1, keyCode: kVK_ANSI_C, modifiers: cmdKey | shiftKey) { [weak self] in self?.togglePicker() }
        registerHotKey(id: 2, keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in self?.copyNewest() }
    }

    var visibleRows: [ClipRow] {
        filter == allProjects ? store.rows : store.rows.filter { $0.project == filter }
    }

    /// Any refresh may have absorbed the change already, so work from `lastSeenID`, not the refresh result.
    func storeChanged() {
        store.refresh()
        let rows = store.rows
        let fresh = rows.filter { $0.id > lastSeenID }
        lastSeenID = max(lastSeenID, rows.last?.id ?? 0, fresh.map(\.id).max() ?? 0)
        refreshBadge()
        if pickerLoaded, picker.isVisible { picker.model.load(rows.reversed()) }
        // Archived clips drop out of `rows`, so a missing clip counts as handled too.
        if let id = toast.clipID, !rows.contains(where: { $0.id == id && !$0.copied }) {
            toast.hide()
        }
        if toastsEnabled, let row = fresh.last {
            let more = fresh.count > 1 ? "  (+\(fresh.count - 1) more)" : ""
            toast.show(.pending, title: "\(row.project) · #\(row.id)\(more)", cmd: row.cmd, note: row.note,
                       footer: "Click to copy  ·  ⌘⇧C picker  ·  ⌃⌥C copy newest", clipID: row.id) { [weak self] in
                if let cmd = copyClip(id: row.id) { self?.confirmCopy(row.id, cmd) }
            }
        }
    }

    func refreshBadge() {
        store.refresh()
        let pending = visibleRows.reduce(0) { $0 + ($1.copied ? 0 : 1) }
        guard pending != badgeCount, let button = statusItem.button else { return }
        badgeCount = pending
        button.image = pending > 0 ? badgeImages.full : badgeImages.empty
        button.title = pending > 0 ? " \(pending)" : ""
    }

    func confirmCopy(_ id: Int, _ cmd: String) {
        refreshBadge()
        let row = store.rows.first { $0.id == id }
        let project = row.map { " · \($0.project)" } ?? ""
        toast.show(.copied, title: "Copied #\(id)\(project)", cmd: cmd, note: row?.note ?? "",
                   footer: "Click to copy again") { [weak self] in
            if let cmd = copyClip(id: id) { self?.confirmCopy(id, cmd) }
        }
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
        if pickerLoaded, picker.isVisible { picker.hide(); return }
        // Clicking the icon while the picker is open closes it via resign-key first; don't reopen.
        if pickerLoaded, Date().timeIntervalSince(picker.lastHidden) < 0.3 { return }
        pickerLoaded = true
        // Draw immediately with the last known project; correct it if the front tab differs.
        picker.show(project: filter == allProjects ? nil : filter)
        DispatchQueue.main.async { [weak self] in
            self?.resolveActiveProjectAsync {
                guard let self, self.picker.isVisible else { return }
                let project = self.filter == allProjects ? nil : self.filter
                self.picker.model.home = project
                self.picker.model.scope = project
                self.refreshBadge()
            }
        }
    }

    /// Newest uncopied clip in the current filter, else the newest one.
    func copyNewest() {
        resolveActiveProject()
        store.refresh()
        let shown = visibleRows
        guard let row = shown.last(where: { !$0.copied }) ?? shown.last else {
            toast.show(.info, title: "Nothing queued", cmd: filter == allProjects ? "" : filter)
            return
        }
        if let cmd = copyClip(id: row.id) { confirmCopy(row.id, cmd) }
    }

    // Rebuild on every open so the menu always reflects the file.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        resolveActiveProject()
        refreshBadge()
        let shown = visibleRows
        let projectCounts = Dictionary(grouping: store.rows, by: \.project).mapValues(\.count)
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
        for row in shown.suffix(menuLimit).reversed() {
            let (cmd, note) = (row.cmd, row.note)
            let prefix = "#\(row.id)  " + (filter == allProjects ? "[\(row.project)]  " : "")

            let item = NSMenuItem(title: prefix + preview(cmd), action: #selector(copyMenuClip(_:)), keyEquivalent: "")
            item.target = self
            item.tag = row.id
            item.state = row.copied ? .on : .off
            if !note.isEmpty, #available(macOS 14.4, *) { item.subtitle = note }
            item.toolTip = (note.isEmpty ? "" : note + "\n\n") + cmd
            menu.addItem(item)

            let alt = NSMenuItem(title: "Archive: " + preview(cmd), action: #selector(archiveClip(_:)), keyEquivalent: "")
            alt.target = self
            alt.tag = row.id
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

    func archive(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        archiveClips(ids)
        refreshBadge()
    }

    @objc func archiveClip(_ sender: NSMenuItem) { archive([sender.tag]) }
    @objc func archiveCopied() { archive(Set(visibleRows.filter(\.copied).map(\.id))) }
    @objc func archiveAllShown() { archive(Set(visibleRows.map(\.id))) }
    @objc func openLog() { NSWorkspace.shared.open(storeURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
