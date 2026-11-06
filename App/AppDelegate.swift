import AppKit
import CKeycadence
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Owns the engine and the menu bar item. SwiftUI windows are built only when
/// first opened, so an app that just sits in the menu bar stays small.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: OpaquePointer!
    private var prefs: Preferences!
    private var stats: KeyStats!
    private var quiet: QuietMonitor!
    private var hotkey: Hotkey!
    private var permission: InputPermission!

    private var item: NSStatusItem!
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--probes") { runProbes() }
        #endif
        engine = kc_engine_create()
        if let pack = Bundle.main.url(forResource: "sounds", withExtension: "kcpack") {
            _ = kc_engine_load_pack(engine, pack.path)
        }
        prefs = Preferences(engine: engine)
        stats = KeyStats(engine: engine)
        quiet = QuietMonitor(prefs: prefs)
        hotkey = Hotkey()
        permission = InputPermission(engine: engine)
        #if DEBUG
        if CommandLine.arguments.contains("--snapshot") {
            DebugSnapshots.run(prefs: prefs, stats: stats, engine: engine, quiet: quiet, permission: permission)
        }
        #endif

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        prefs.onMenuBarChanged = { [weak self] in self?.refreshStatusItem() }
        prefs.onHotkeyChanged = { [weak self] in self?.registerHotkey() }
        stats.onChange = { [weak self] in self?.refreshStatusItem() }
        stats.setRunning(prefs.statsEnabled)
        registerHotkey()
        refreshStatusItem()

        permission.start()
        // First launch without permission: show why nothing is playing yet.
        if !permission.granted { openPanel() }
    }

    #if DEBUG
    /// Runs every quiet rule's check inside the real sandbox.
    private func runProbes() {
        print("output:", QuietProbes.outputKind())
        print("microphone:", QuietProbes.microphoneInUse())
        print("camera:", QuietProbes.cameraInUse())
        print("otherAudio:", QuietProbes.otherAppPlayingAudio())
        print("externalKeyboard:", QuietProbes.externalKeyboardConnected())
        print("devices:", AudioDevices.outputDevices().map(\.name))
        exit(0)
    }
    #endif

    private func registerHotkey() {
        hotkey.register(code: prefs.hotkeyCode, modifiers: prefs.hotkeyModifiers) { [weak self] in
            self?.prefs.enabled.toggle()
        }
    }

    private func refreshStatusItem() {
        guard let button = item?.button else { return }
        stats.setRunningIfNeeded(prefs.statsEnabled)
        button.image = StatusIcon.image(on: prefs.enabled && !prefs.isQuiet)
        button.appearsDisabled = !prefs.enabled && !prefs.solidIconWhenOff
        switch prefs.menuBarLabel {
        case .none:
            button.title = ""
        case .switchName:
            button.title = allSwitches[prefs.switchID].name
        case .keysToday:
            button.title = prefs.statsEnabled ? stats.liveToday.formatted() : ""
        }
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let alternate = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        if prefs.clickAction == .toggleSound && !alternate {
            prefs.enabled.toggle()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = item.button else { return }
        if popover == nil {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = false // appears instantly
            let root = PanelView(prefs: prefs, permission: permission, engine: engine,
                                 openSettings: { [weak self] in self?.openSettings() })
            p.contentViewController = NSHostingController(rootView: root)
            popover = p
        }
        NSApp.activate(ignoringOtherApps: true)
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func openSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let root = SettingsView(prefs: prefs, stats: stats, engine: engine, quiet: quiet)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Keycadence Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }
}

extension KeyStats {
    fileprivate func setRunningIfNeeded(_ running: Bool) {
        if running != isRunning { setRunning(running) }
    }
}

/// Watches for the Input Monitoring grant, and starts the key tap as soon as it arrives.
@MainActor
@Observable
final class InputPermission {
    private(set) var granted = false
    @ObservationIgnored private let engine: OpaquePointer
    @ObservationIgnored private var timer: Timer?

    init(engine: OpaquePointer) {
        self.engine = engine
        granted = kc_tap_has_permission()
    }

    func start() {
        if !granted { granted = kc_tap_has_permission() }
        if granted {
            granted = kc_tap_start(engine)
        }
        if granted {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func request() {
        if !kc_tap_request_permission() { openSystemSettings() }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// An original mark: a keycap seen from above, emitting a sound wave.
enum StatusIcon {
    private static let onImage = make(on: true)
    private static let offImage = make(on: false)

    static func image(on: Bool) -> NSImage { on ? onImage : offImage }

    private static func make(on: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            let cap = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 2.25, width: 11.5, height: 11.5), xRadius: 3, yRadius: 3)
            cap.lineWidth = 1.5
            cap.stroke()
            let inner = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 5.5, width: 5, height: 5), xRadius: 1.4, yRadius: 1.4)
            NSColor.black.setFill()
            if on { inner.fill() } else { inner.lineWidth = 1; inner.stroke() }
            if on {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: NSPoint(x: 11, y: 8), radius: 5.5, startAngle: -38, endAngle: 38)
                wave.lineWidth = 1.5
                wave.lineCapStyle = .round
                wave.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
