import AppKit
import FanPilotCore
import SwiftUI

/// Renders the app's screens to PNG files without showing them, for docs and
/// visual checks: `FANPILOT_SNAPSHOT=/some/dir open -W build/FanPilot.app`
/// (or run the binary directly with the variable set).
@MainActor
enum Snapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FANPILOT_SNAPSHOT"].map { URL(fileURLWithPath: $0) }
    }

    static func run(into directory: URL) {
        let model = AppModel()
        // Let a few refreshes and the helper round trip happen.
        RunLoop.main.run(until: Date().addingTimeInterval(7))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func file(_ name: String) -> URL { directory.appendingPathComponent("\(name).png") }
        let dark = NSAppearance(named: .darkAqua)
        let light = NSAppearance(named: .aqua)

        // The real menu bar window supplies the material behind the popover; stand in with the window colour.
        let menu = MenuContent().environment(model).background(Color(nsColor: .windowBackgroundColor))
        render(menu, width: 320, height: nil, appearance: light, to: file("menu"))
        render(menu, width: 320, height: nil, appearance: dark, to: file("menu-dark"))
        let screens: [(String, SidebarItem)] = [
            ("overview", .overview),
            ("profile-balanced", .profile(Presets.balancedID)),
            ("sensors", .sensors),
            ("helper", .helper),
        ]
        for (name, item) in screens {
            render(MainWindow(initialSelection: item).environment(model), width: 980, height: 720,
                   appearance: light, to: file(name))
        }
        render(MainWindow(initialSelection: .overview).environment(model), width: 980, height: 720,
               appearance: dark, to: file("overview-dark"))
        render(MainWindow(initialSelection: .profile(Presets.coolID)).environment(model), width: 980, height: 720,
               appearance: dark, to: file("profile-dark"))
        render(GeneralSettings().environment(model).frame(width: 520), width: 520, height: nil, appearance: light,
               to: file("settings-general"))
        render(ControlSettings().environment(model).frame(width: 520), width: 520, height: nil, appearance: light,
               to: file("settings-control"))
        render(SafetySettingsPane().environment(model).frame(width: 520), width: 520, height: nil, appearance: light,
               to: file("settings-safety"))
        print("snapshots written to \(directory.path)")
        exit(0)
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?, appearance: NSAppearance?,
                                        to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        let size = CGSize(width: width, height: height ?? hosting.fittingSize.height)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        if height == nil {
            hosting.frame.size.height = hosting.fittingSize.height
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app so pending edits are saved when it quits.
    @MainActor static var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.onTerminate?() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = Snapshotter.directory {
            MainActor.assumeIsolated { Snapshotter.run(into: directory) }
        }
    }
}
