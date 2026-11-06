#if DEBUG
import AppKit
import CKeycadence
import SwiftUI

/// `Keycadence --snapshot` renders every screen to PNGs for visual review.
/// Debug builds only. Images go to stdout as base64: see tools/snapshots.sh.
@MainActor
enum DebugSnapshots {
    static func run(prefs: Preferences, stats: KeyStats, engine: OpaquePointer, quiet: QuietMonitor, permission: InputPermission) {
        let screens: [(String, NSSize, AnyView)] = [
            ("panel", NSSize(width: 300, height: 440),
             AnyView(PanelView(prefs: prefs, permission: permission, engine: engine, openSettings: {}))),
            ("sound", NSSize(width: 480, height: 820), AnyView(SoundTab(prefs: prefs, engine: engine))),
            ("quiet", NSSize(width: 480, height: 620), AnyView(QuietTab(prefs: prefs, quiet: quiet))),
            ("general", NSSize(width: 480, height: 620), AnyView(GeneralTab(prefs: prefs))),
            ("activity", NSSize(width: 480, height: 620), AnyView(ActivityTab(prefs: prefs, stats: stats, engine: engine))),
            ("about", NSSize(width: 480, height: 620), AnyView(AboutTab())),
        ]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for (name, size, view) in screens {
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.backgroundColor = appearance == .aqua ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.16, alpha: 1)
                window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                guard let content = window.contentView,
                      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                content.cacheDisplay(in: content.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    print("SNAPSHOT \(name)-\(appearanceName) \(png.base64EncodedString())")
                }
                window.orderOut(nil)
            }
        }
        exit(0)
    }
}
#endif
