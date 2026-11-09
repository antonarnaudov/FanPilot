import AppKit
import FanPilotCore
import SwiftUI

@main
struct FanPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("FanPilot", id: WindowID.main) {
            MainWindow(initialSelection: DesignPreview.page ?? .overview)
                .environment(model)
                .frame(minWidth: 780, minHeight: 540)
                .preferredColorScheme(DesignPreview.colorScheme)
                .showsInDock()
        }
        .defaultSize(width: 980, height: 720)
        .defaultLaunchBehavior(DesignPreview.page != nil ? .presented : .suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(model)
                .showsInDock()
        }

        // Design review only (FANPILOT_PAGE=menu): the menu bar window's content in a normal window.
        Window("Menu Preview", id: "menu-preview") {
            MenuPreview()
                .environment(model)
                .preferredColorScheme(DesignPreview.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(DesignPreview.showsMenu ? .presented : .suppressed)
    }
}

/// Launch settings for reviewing the design:
/// `FANPILOT_PAGE=overview|sensors|helper|menu|profile:<name>` and `FANPILOT_APPEARANCE=light|dark`.
enum DesignPreview {
    private static let environment = ProcessInfo.processInfo.environment

    static var page: SidebarItem? {
        guard let value = environment["FANPILOT_PAGE"] else { return nil }
        switch value {
        case "overview", "menu": return .overview
        case "sensors": return .sensors
        case "helper": return .helper
        default:
            guard value.hasPrefix("profile:") else { return nil }
            let name = value.dropFirst("profile:".count).lowercased()
            return Presets.all.first { $0.name.lowercased() == name }.map { .profile($0.id) }
        }
    }

    static var showsMenu: Bool { environment["FANPILOT_PAGE"] == "menu" }
    static var scrollsToBottom: Bool { environment["FANPILOT_SCROLL"] == "bottom" }

    static var colorScheme: ColorScheme? {
        switch environment["FANPILOT_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// The menu's content on glass over the heat backdrop, as it looks over a desktop.
struct MenuPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MenuContent()
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(28)
            .background {
                HeatBackdrop(temperature: model.value(.hottest), tint: model.effectiveProfile.tint)
            }
    }
}

enum WindowID {
    static let main = "main"
}

/// Opens the main window and brings the app to the front.
struct OpenMainWindowAction {
    let openWindow: OpenWindowAction

    func callAsFunction() {
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

extension EnvironmentValues {
    var openMainWindow: OpenMainWindowAction { OpenMainWindowAction(openWindow: openWindow) }
}

/// FanPilot lives in the menu bar. While one of its windows is open it also
/// gets a Dock icon and a menu bar, like other native menu bar apps.
@MainActor
enum DockPresence {
    private static var openWindows = 0

    static func windowAppeared() {
        guard Snapshotter.directory == nil else { return }
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowDisappeared() {
        guard Snapshotter.directory == nil else { return }
        openWindows = max(openWindows - 1, 0)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

extension View {
    func showsInDock() -> some View {
        onAppear { DockPresence.windowAppeared() }
            .onDisappear { DockPresence.windowDisappeared() }
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            switch model.menuBarDisplay {
            case .temperatureAndSpeed:
                Text("\(temperature) \(speed)")
            case .temperature:
                Text(temperature)
            case .speed:
                Text(speed)
            case .icon:
                EmptyView()
            }
        }
        .monospacedDigit()
        .task {
            // First launch: show the window so the helper can be installed.
            if !didOnboard, Snapshotter.directory == nil {
                didOnboard = true
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
        }
    }

    private var symbol: String {
        if model.helperState?.safetyActive == true { return "exclamationmark.triangle.fill" }
        return model.controlling ? "fan.fill" : "fan"
    }

    private var temperature: String {
        model.menuTemperature.map { "\(Int($0.rounded()))°" } ?? "–°"
    }

    private var speed: String {
        guard let rpm = model.fastestFanRPM else { return "" }
        return rpm < 1 ? "off" : "\(Int(rpm.rounded()))"
    }
}
