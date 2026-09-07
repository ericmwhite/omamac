// Clipwatch: a small, private clipboard history for the Mac menu bar.
//
//   Clipwatch          run the menu-bar app
//   Clipwatch stream   print each new clipboard text as one base64 line (for syncing over SSH)
//   Clipwatch set      read stdin and put it on the clipboard
//   Clipwatch get      print the current clipboard text
//
// There is no network code in this file. History lives in
// ~/Library/Application Support/Clipwatch/history.json (mode 0600) and can be
// turned off from the menu. Items that a password manager marks as concealed
// or transient are never recorded or streamed.

import AppKit
import Carbon
import ServiceManagement

let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

/// The clipboard's text, unless it is empty or marked private.
func clipboardText(_ pb: NSPasteboard = .general) -> String? {
    if let types = pb.types, types.contains(concealedType) || types.contains(transientType) { return nil }
    guard let s = pb.string(forType: .string), !s.isEmpty else { return nil }
    return s
}

func setClipboard(_ s: String, _ pb: NSPasteboard = .general) {
    pb.clearContents()
    pb.setString(s, forType: .string)
}

// MARK: - Command-line modes

func runStream() -> Never {
    signal(SIGPIPE, SIG_IGN)
    // Exit when the SSH session goes away (stdin hits EOF).
    Thread {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        exit(0)
    }.start()
    let pb = NSPasteboard.general
    var last = pb.changeCount
    while true {
        Thread.sleep(forTimeInterval: 0.3)
        let c = pb.changeCount
        if c == last { continue }
        last = c
        guard let s = clipboardText(pb) else { continue }
        let line = Data(s.utf8).base64EncodedString() + "\n"
        let ok = line.withCString { p in write(STDOUT_FILENO, p, strlen(p)) > 0 }
        if !ok { exit(0) }
    }
}

func runSet() -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let s = String(data: data, encoding: .utf8) else { exit(1) }
    setClipboard(s)
    exit(0)
}

func runGet() -> Never {
    if let s = clipboardText() { FileHandle.standardOutput.write(Data(s.utf8)) }
    exit(0)
}

// MARK: - Menu-bar app

struct Item: Codable {
    var text: String
    var date: Date
}

/// The overlay shown while cycling with Shift-Cmd-V. It is a non-activating
/// panel: it takes keyboard input without stealing focus from the app you are
/// pasting into.
final class Bezel: NSPanel {
    let body = NSTextField(wrappingLabelWithString: "")
    let counter = NSTextField(labelWithString: "")
    var onMove: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let rect = NSRect(x: 0, y: 0, width: 560, height: 320)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: rect)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        contentView = effect

        body.frame = NSRect(x: 28, y: 56, width: rect.width - 56, height: rect.height - 84)
        body.font = .systemFont(ofSize: 16)
        body.textColor = .labelColor
        body.maximumNumberOfLines = 11
        body.lineBreakMode = .byTruncatingTail
        body.cell?.truncatesLastVisibleLine = true
        effect.addSubview(body)

        counter.frame = NSRect(x: 28, y: 20, width: rect.width - 56, height: 20)
        counter.font = .systemFont(ofSize: 12)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .center
        effect.addSubview(counter)
    }

    override var canBecomeKey: Bool { true }

    func show(text: String, index: Int, count: Int) {
        body.stringValue = text
        counter.stringValue = "\(index + 1) of \(count)   ·   tap V for older, release ⌘ to paste, esc to cancel"
        if !isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2))
            makeKeyAndOrderFront(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape: onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter: onCommit?()
        case kVK_DownArrow: onMove?(1)
        case kVK_UpArrow: onMove?(-1)
        case kVK_ANSI_V where !cmd: onMove?(1)   // with ⌘ held the hot key handles it
        default: break
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) { onCommit?() }
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let pb = NSPasteboard.general
    let defaults = UserDefaults.standard
    let menu = NSMenu()
    var statusItem: NSStatusItem!
    var items: [Item] = []
    var changeCount = 0
    var pollTimer: Timer?
    var saveTimer: Timer?
    var hotKeyRef: EventHotKeyRef?
    let bezel = Bezel()
    var bezelIndex = 0
    var modifierWatch: Timer?

    var maxItems: Int { max(1, defaults.object(forKey: "maxItems") as? Int ?? 100) }
    var menuItemCount: Int { max(1, defaults.object(forKey: "menuItems") as? Int ?? 30) }
    var persist: Bool { defaults.object(forKey: "persist") as? Bool ?? true }
    var paused: Bool { defaults.bool(forKey: "paused") }

    var storeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipwatch", isDirectory: true)
    }
    var storeURL: URL { storeDir.appendingPathComponent("history.json") }

    func applicationDidFinishLaunching(_ note: Notification) {
        load()
        changeCount = pb.changeCount
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipwatch")
        menu.delegate = self
        statusItem.menu = menu
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        registerHotKey()
        bezel.onMove = { [weak self] d in self?.moveBezel(d) }
        bezel.onCommit = { [weak self] in self?.commitBezel() }
        bezel.onCancel = { [weak self] in self?.hideBezel() }
    }

    // MARK: Recording

    func poll() {
        let c = pb.changeCount
        if c == changeCount { return }
        changeCount = c
        if paused { return }
        guard let s = clipboardText(pb) else { return }
        add(s)
    }

    func add(_ text: String) {
        items.removeAll { $0.text == text }
        items.insert(Item(text: text, date: Date()), at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        scheduleSave()
    }

    // MARK: Persistence

    func load() {
        guard persist, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = Array(saved.prefix(maxItems))
    }

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.save() }
    }

    func save() {
        let fm = FileManager.default
        guard persist else {
            try? fm.removeItem(at: storeURL)
            return
        }
        try? fm.createDirectory(at: storeDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    // MARK: Menu

    func label(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 60 ? String(collapsed.prefix(60)) + "…" : collapsed
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func rebuildMenu() {
        menu.removeAllItems()
        if items.isEmpty {
            let empty = NSMenuItem(title: "No clipboard history", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (i, item) in items.prefix(menuItemCount).enumerated() {
            let mi = NSMenuItem(title: label(item.text), action: #selector(pick(_:)),
                                keyEquivalent: i < 9 ? String(i + 1) : "")
            mi.keyEquivalentModifierMask = []
            mi.tag = i
            mi.target = self
            mi.toolTip = String(item.text.prefix(1000))
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        addToggle("Pause Recording", #selector(togglePause), on: paused)
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        addToggle("Remember History Across Restarts", #selector(togglePersist), on: persist)
        addToggle("Paste Directly (needs Accessibility)", #selector(requestAccessibility), on: AXIsProcessTrusted())
        addToggle("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Shift-Cmd-V: hold ⌘, tap V to cycle, release to paste", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem(title: "Quit Clipwatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func addToggle(_ title: String, _ action: Selector, on: Bool) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        menu.addItem(mi)
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        pasteOut(items[sender.tag].text)
    }

    /// Put text on the clipboard and, if allowed, paste it into the front app.
    func pasteOut(_ text: String) {
        setClipboard(text)
        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.sendCommandV() }
        }
    }

    @objc func togglePause() { defaults.set(!paused, forKey: "paused") }
    @objc func togglePersist() { defaults.set(!persist, forKey: "persist"); save() }
    @objc func clearHistory() { items.removeAll(); save() }

    @objc func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("Login item change failed: \(error)")
        }
    }

    // MARK: Cycling with Shift-Cmd-V (Flycut style)

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<App>.fromOpaque(userData!).takeUnretainedValue().hotKeyPressed()
            return noErr
        }, 1, &spec, me, nil)
        let id = EventHotKeyID(signature: 0x434C5057, id: 1) // "CLPW"
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// First press shows the newest item; each further press while ⌘ is held
    /// moves one item older. Releasing ⌘ pastes whatever is showing.
    func hotKeyPressed() {
        guard !items.isEmpty else { return }
        if bezel.isVisible {
            moveBezel(1)
        } else {
            bezelIndex = 0
            updateBezel()
            // Backup for a ⌘ release that lands before the panel is key.
            modifierWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                if !NSEvent.modifierFlags.contains(.command) { self?.commitBezel() }
            }
        }
    }

    func moveBezel(_ delta: Int) {
        guard !items.isEmpty else { return hideBezel() }
        bezelIndex = ((bezelIndex + delta) % items.count + items.count) % items.count
        updateBezel()
    }

    func updateBezel() {
        guard items.indices.contains(bezelIndex) else { return hideBezel() }
        bezel.show(text: items[bezelIndex].text, index: bezelIndex, count: items.count)
    }

    func commitBezel() {
        guard bezel.isVisible else { return }
        let text = items.indices.contains(bezelIndex) ? items[bezelIndex].text : nil
        hideBezel()
        if let text = text { pasteOut(text) }
    }

    func hideBezel() {
        modifierWatch?.invalidate()
        modifierWatch = nil
        bezel.orderOut(nil)
    }

    func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Entry point

switch CommandLine.arguments.dropFirst().first {
case "stream": runStream()
case "set": runSet()
case "get": runGet()
case "-h", "--help", "help":
    print("usage: Clipwatch [stream|set|get]   (no argument runs the menu-bar app)")
    exit(0)
default: break
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
