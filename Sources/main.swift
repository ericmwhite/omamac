// Clipspan: a small, private clipboard history for the Mac menu bar.
//
//   Clipspan          run the menu-bar app
//   Clipspan stream   print each clipboard change as one line: "t:<base64 utf8>" or "i:<base64 png>"
//   Clipspan set      read stdin (PNG bytes or UTF-8 text) and put it on the clipboard
//   Clipspan get      print the current clipboard (PNG bytes or text)
//
// There is no network code in this file. History lives in
// ~/Library/Application Support/Clipspan/ (mode 0600/0700) and can be turned
// off from the menu. Items that a password manager marks as concealed or
// transient are never recorded or streamed.

import AppKit
import Carbon
import CryptoKit
import ServiceManagement

let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
let maxImageBytes = 20 * 1024 * 1024
let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

enum Content {
    case text(String)
    case image(Data)   // always PNG
}

/// The clipboard's content, unless it is empty or marked private.
/// Text wins over an image unless the text is just a URL (browsers put the
/// image's address alongside a copied picture).
func clipboardContent(_ pb: NSPasteboard = .general) -> Content? {
    let types = pb.types ?? []
    if types.contains(concealedType) || types.contains(transientType) { return nil }
    let text = pb.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    let hasImage = types.contains(.png) || types.contains(.tiff)
    if hasImage, text == nil || looksLikeURL(text!), let png = pngData(pb), png.count <= maxImageBytes {
        return .image(png)
    }
    if let t = text { return .text(t) }
    return nil
}

func looksLikeURL(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return !t.contains(where: \.isNewline) && !t.contains(" ")
        && (t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("file://"))
}

func pngData(_ pb: NSPasteboard) -> Data? {
    if let d = pb.data(forType: .png) { return d }
    guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

func setClipboard(_ c: Content, _ pb: NSPasteboard = .general) {
    pb.clearContents()
    switch c {
    case .text(let s):
        pb.setString(s, forType: .string)
    case .image(let png):
        // Keep the exact PNG bytes (so a synced image round-trips unchanged)
        // and add a TIFF for apps that only take that.
        pb.setData(png, forType: .png)
        if let rep = NSBitmapImageRep(data: png), let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }
}

func contentFromBytes(_ data: Data) -> Content? {
    if data.starts(with: pngMagic) { return data.count <= maxImageBytes ? .image(data) : nil }
    return String(data: data, encoding: .utf8).map { .text($0) }
}

func sha256(_ d: Data) -> String {
    SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
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
        guard let content = clipboardContent(pb) else { continue }
        let line: String
        switch content {
        case .text(let s): line = "t:" + Data(s.utf8).base64EncodedString() + "\n"
        case .image(let d): line = "i:" + d.base64EncodedString() + "\n"
        }
        let ok = line.withCString { p in write(STDOUT_FILENO, p, strlen(p)) > 0 }
        if !ok { exit(0) }
    }
}

func runSet() -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let c = contentFromBytes(data) else { exit(1) }
    setClipboard(c)
    exit(0)
}

func runGet() -> Never {
    switch clipboardContent() {
    case .text(let s)?: FileHandle.standardOutput.write(Data(s.utf8))
    case .image(let d)?: FileHandle.standardOutput.write(d)
    case nil: break
    }
    exit(0)
}

// MARK: - Menu-bar app

struct Item: Codable {
    var text: String?
    var image: String?      // file name under images/, PNG
    var hash: String?       // sha256 of the PNG, for de-duplication
    var width: Int?
    var height: Int?
    var date: Date

    var isImage: Bool { image != nil }
}

/// The overlay shown while cycling with Shift-Cmd-V. It is a non-activating
/// panel: it takes keyboard input without stealing focus from the app you are
/// pasting into.
final class Bezel: NSPanel {
    let body = NSTextField(wrappingLabelWithString: "")
    let picture = NSImageView()
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

        let inner = NSRect(x: 28, y: 56, width: rect.width - 56, height: rect.height - 84)
        body.frame = inner
        body.font = .systemFont(ofSize: 16)
        body.textColor = .labelColor
        body.maximumNumberOfLines = 11
        body.lineBreakMode = .byTruncatingTail
        body.cell?.truncatesLastVisibleLine = true
        effect.addSubview(body)

        picture.frame = inner
        picture.imageScaling = .scaleProportionallyDown
        picture.imageAlignment = .alignCenter
        effect.addSubview(picture)

        counter.frame = NSRect(x: 28, y: 20, width: rect.width - 56, height: 20)
        counter.font = .systemFont(ofSize: 12)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .center
        effect.addSubview(counter)
    }

    override var canBecomeKey: Bool { true }

    func show(text: String?, image: NSImage?, index: Int, count: Int) {
        body.stringValue = text ?? ""
        body.isHidden = image != nil
        picture.image = image
        picture.isHidden = image == nil
        counter.stringValue = "\(index + 1) of \(count)   ·   V or → older, ← newer, release ⌘ to paste, esc to cancel"
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
        case kVK_DownArrow, kVK_RightArrow: onMove?(1)
        case kVK_UpArrow, kVK_LeftArrow: onMove?(-1)
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
    var imageCache: [String: Data] = [:]
    var changeCount = 0
    var pollTimer: Timer?
    var saveTimer: Timer?
    var hotKeyRef: EventHotKeyRef?
    let bezel = Bezel()
    var bezelIndex = 0
    var modifierWatch: Timer?

    var maxItems: Int { max(1, defaults.object(forKey: "maxItems") as? Int ?? 100) }
    var maxImages: Int { max(0, defaults.object(forKey: "maxImages") as? Int ?? 20) }
    var menuItemCount: Int { max(1, defaults.object(forKey: "menuItems") as? Int ?? 30) }
    var persist: Bool { defaults.object(forKey: "persist") as? Bool ?? true }
    var paused: Bool { defaults.bool(forKey: "paused") }

    var storeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipspan", isDirectory: true)
    }
    var storeURL: URL { storeDir.appendingPathComponent("history.json") }
    var imagesDir: URL { storeDir.appendingPathComponent("images", isDirectory: true) }
    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    func applicationDidFinishLaunching(_ note: Notification) {
        load()
        changeCount = pb.changeCount
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipspan")
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
        guard let content = clipboardContent(pb) else { return }
        add(content)
    }

    func add(_ content: Content) {
        switch content {
        case .text(let s):
            items.removeAll { $0.text == s }
            items.insert(Item(text: s, date: Date()), at: 0)
        case .image(let png):
            let h = sha256(png)
            if let i = items.firstIndex(where: { $0.hash == h }) {
                var existing = items.remove(at: i)
                existing.date = Date()
                items.insert(existing, at: 0)
            } else {
                let name = UUID().uuidString + ".png"
                let rep = NSBitmapImageRep(data: png)
                imageCache[name] = png
                items.insert(Item(image: name, hash: h, width: rep?.pixelsWide, height: rep?.pixelsHigh, date: Date()), at: 0)
            }
        }
        trim()
        scheduleSave()
    }

    func trim() {
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        var seen = 0
        items.removeAll { item in
            guard item.isImage else { return false }
            seen += 1
            return seen > maxImages
        }
        let live = Set(items.compactMap(\.image))
        imageCache = imageCache.filter { live.contains($0.key) }
    }

    func imageData(_ item: Item) -> Data? {
        guard let name = item.image else { return nil }
        if let d = imageCache[name] { return d }
        let d = try? Data(contentsOf: imageURL(name))
        if let d = d { imageCache[name] = d }
        return d
    }

    func content(of item: Item) -> Content? {
        if let t = item.text { return .text(t) }
        return imageData(item).map { .image($0) }
    }

    // MARK: Persistence

    func load() {
        guard persist, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = saved.filter { $0.text != nil || $0.image != nil }
        trim()
    }

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.save() }
    }

    func save() {
        let fm = FileManager.default
        guard persist else {
            try? fm.removeItem(at: storeDir)
            return
        }
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path)
        let live = Set(items.compactMap(\.image))
        for name in live where !fm.fileExists(atPath: imageURL(name).path) {
            guard let d = imageCache[name] else { continue }
            try? d.write(to: imageURL(name), options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL(name).path)
        }
        for name in (try? fm.contentsOfDirectory(atPath: imagesDir.path)) ?? [] where !live.contains(name) {
            try? fm.removeItem(at: imageURL(name))
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    // MARK: Menu

    func label(_ item: Item) -> String {
        if item.isImage {
            if let w = item.width, let h = item.height { return "Image \(w)×\(h)" }
            return "Image"
        }
        let text = item.text ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 60 ? String(collapsed.prefix(60)) + "…" : collapsed
    }

    func thumbnail(_ item: Item) -> NSImage? {
        guard let d = imageData(item), let img = NSImage(data: d) else { return nil }
        let h: CGFloat = 18
        let w = max(1, min(48, img.size.width * h / max(1, img.size.height)))
        let thumb = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            img.draw(in: rect)
            return true
        }
        return thumb
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
            let mi = NSMenuItem(title: label(item), action: #selector(pick(_:)),
                                keyEquivalent: i < 9 ? String(i + 1) : "")
            mi.keyEquivalentModifierMask = []
            mi.tag = i
            mi.target = self
            if item.isImage {
                mi.image = thumbnail(item)
            } else {
                mi.toolTip = String((item.text ?? "").prefix(1000))
            }
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
        let hint = NSMenuItem(title: "Shift-Cmd-V: hold ⌘, tap V or arrows to cycle, release to paste", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem(title: "Quit Clipspan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func addToggle(_ title: String, _ action: Selector, on: Bool) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        menu.addItem(mi)
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        pasteOut(items[sender.tag])
    }

    /// Put an item on the clipboard and, if allowed, paste it into the front app.
    func pasteOut(_ item: Item) {
        guard let c = content(of: item) else { return }
        setClipboard(c)
        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.sendCommandV() }
        }
    }

    @objc func togglePause() { defaults.set(!paused, forKey: "paused") }
    @objc func togglePersist() { defaults.set(!persist, forKey: "persist"); save() }
    @objc func clearHistory() { items.removeAll(); imageCache.removeAll(); save() }

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
        let id = EventHotKeyID(signature: 0x434C5350, id: 1) // "CLSP"
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
        let item = items[bezelIndex]
        let image = item.isImage ? imageData(item).flatMap { NSImage(data: $0) } : nil
        bezel.show(text: item.text, image: image, index: bezelIndex, count: items.count)
    }

    func commitBezel() {
        guard bezel.isVisible else { return }
        let item = items.indices.contains(bezelIndex) ? items[bezelIndex] : nil
        hideBezel()
        if let item = item { pasteOut(item) }
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
    print("usage: Clipspan [stream|set|get]   (no argument runs the menu-bar app)")
    exit(0)
default: break
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
