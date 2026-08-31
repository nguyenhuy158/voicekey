import Cocoa
import AVFoundation

// Driving adapter: the CGEvent tap, the status item and the menus. It turns key
// events into calls on Dictation and owns no dictation state of its own.

let debugKeys = CommandLine.arguments.contains("--debug")

final class App: NSObject, NSApplicationDelegate {
    var cfg: Config { Settings.shared.cfg }
    var item: NSStatusItem!
    var tap: CFMachPort?
    lazy var d = Dictation(
        audio: Recorder(), stt: Whisper(), text: SystemText(), ai: OpenRouter(),
        ui: AppKitFeedback { [weak self] in self?.setIcon($0) }, store: DiskStore())

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic")
        buildMenu()
        Settings.shared.onChange = { [weak self] in
            self?.buildMenu()
            self?.buildMainMenu()
            if !(self?.d.isTalking ?? false) { HUD.shared.hide() }   // apply floating-bar toggle
        }
        buildMainMenu()
        HUD.shared.hide()          // draws the floating bar if it's turned on

        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Never block launch on a permission alert — ask via the system prompt and
        // keep retrying, so granting it takes effect without relaunching.
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        startTap()
        MainWindow.show(.history)
    }

    func setIcon(_ name: String) {
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceKey")
    }

    /// A .regular app gets no menu bar for free — without this ⌘Q and ⌘W do nothing.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: T("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T("Hide VoiceKey"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: T("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T("Quit VoiceKey"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (t, sel, k) in [("Cut", #selector(NSText.cut(_:)), "x"),
                            ("Copy", #selector(NSText.copy(_:)), "c"),
                            ("Paste", #selector(NSText.paste(_:)), "v"),
                            ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: T(t), action: sel, keyEquivalent: k)
        }
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "\(T("Hold")) \(cfg.keyName) → \(cfg.language)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: "\(T("Hold")) \(cfg.keyName2) → \(cfg.language2)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())
        m.addItem(withTitle: T("Open VoiceKey"), action: #selector(showHistory), keyEquivalent: "o").target = self
        m.addItem(withTitle: T("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: T("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    @objc func showHistory() { MainWindow.show(.history) }

    @objc func showSettings() { MainWindow.show(.settings) }

    /// Dock icon click with no window open — bring the main window back.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool {
        if !f { MainWindow.show() }
        return true
    }

    // MARK: event tap

    func startTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, ctx in
                let app = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
                return app.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // macOS caches the Accessibility verdict per process, so a process that
            // started untrusted stays untrusted — retrying in-process never recovers.
            // Poll until trust appears, then relaunch ourselves to get a fresh verdict.
            setIcon("exclamationmark.triangle")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                if AXIsProcessTrusted() { self.relaunch() } else { self.startTap() }
            }
            return
        }
        setIcon("mic")
        tap = t
        if debugKeys { FileHandle.standardError.write("tap created OK\n".data(using: .utf8)!) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: cfg) { _, _ in exit(0) }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if debugKeys {
            FileHandle.standardError.write("tap type=\(type.rawValue) code=\(code) flags=\(event.flags.rawValue) want=\(cfg.keyCode)\n".data(using: .utf8)!)
        }

        let flags = event.flags
        let slot = Settings.shared.capturingSlot
        if slot != 0 {
            guard type == .keyDown || type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            if type == .flagsChanged && modifierFlags[code] == nil { return Unmanaged.passUnretained(event) }
            // A combo needs a real key plus modifiers, so bare modifier taps don't count.
            if slot == 4 && type != .keyDown { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { Settings.shared.capture(slot, code: code, flags: flags) }
            return nil
        }

        // Escape aborts the clip in progress — nothing transcribed, nothing pasted.
        if cfg.cancelWithEscape && code == 53 && type == .keyDown && d.isTalking {
            DispatchQueue.main.async { self.d.cancelTalk() }
            return nil
        }

        // Paste the last transcript again.
        if type == .keyDown && code == cfg.pasteLastKey && !d.lastTranscript.isEmpty
            && flags.intersection(comboMask).rawValue == cfg.pasteLastFlags {
            DispatchQueue.main.async { self.d.pasteLast() }
            return nil
        }

        // Hands free: one tap starts, the next stops.
        if code == cfg.handsFreeKey, d.heldCode == nil {
            let fire = modifierFlags[code].map { type == .flagsChanged && flags.contains($0) }
                       ?? (type == .keyDown)
            if fire {
                DispatchQueue.main.async { self.d.toggleHandsFree() }
                return modifierFlags[code] == nil ? nil : Unmanaged.passUnretained(event)
            }
            if modifierFlags[code] == nil { return nil }   // swallow the key-up too
        }

        guard let lang = cfg.lang(for: code), d.handsFreeLang == nil else {
            return Unmanaged.passUnretained(event)
        }
        // Ignore the other key while one is already held or latched, so the language
        // can't switch mid-clip.
        guard d.heldCode == nil || d.heldCode == code else { return Unmanaged.passUnretained(event) }
        guard d.latchedCode == nil || d.latchedCode == code else { return Unmanaged.passUnretained(event) }

        if let flag = modifierFlags[code] {
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            let pressed = event.flags.contains(flag)
            if pressed != (d.heldCode == code) {
                d.heldCode = pressed ? code : nil
                DispatchQueue.main.async {
                    pressed ? self.d.keyPressed(code, lang) : self.d.keyReleased(code, lang)
                }
            }
            return Unmanaged.passUnretained(event)   // don't break the modifier for other apps
        }

        // plain key: swallow it so holding it doesn't spam characters
        if type == .keyDown && d.heldCode == nil {
            d.heldCode = code
            DispatchQueue.main.async { self.d.keyPressed(code, lang) }
        } else if type == .keyUp {
            d.heldCode = nil
            DispatchQueue.main.async { self.d.keyReleased(code, lang) }
        }
        return nil
    }
}

if CommandLine.arguments.contains("--selftest") { runSelfTest() }
if CommandLine.arguments.contains("--checkperms") { runPermCheck() }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
