import AppKit
import FanPilotCore
import Foundation
import Observation
import SMCKit

enum HelperStatus: Equatable {
    case checking
    /// Not registered with macOS yet.
    case notInstalled
    /// Registered; waiting for the user to allow it in System Settings › Login Items.
    case needsApproval
    case notResponding(String)
    case running(version: String)

    var isRunning: Bool { if case .running = self { return true } else { return false } }
}

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case temperatureAndSpeed, temperature, speed, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperatureAndSpeed: return "Temperature and fan speed"
        case .temperature: return "Temperature"
        case .speed: return "Fan speed"
        case .icon: return "Icon only"
        }
    }
}

/// Everything the UI shows. Live readings come straight from the SMC (no
/// privileges needed); control state and config come from the helper.
@Observable @MainActor
final class AppModel {
    // Live readings
    private(set) var fans: [FanInfo] = []
    private(set) var readings: [SensorReading] = []

    // Helper
    private(set) var helperStatus: HelperStatus = .checking
    private(set) var helperState: HelperState?
    private(set) var config: FanPilotConfig
    var lastError: String?
    var busy = false
    /// A page the main window should switch to (set from the menu bar window).
    var requestedPage: SidebarItem?

    // Preferences (this Mac, this user)
    var menuBarDisplay: MenuBarDisplay {
        didSet { UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: "menuBarDisplay") }
    }
    var menuBarSensor: SensorSelector {
        didSet { UserDefaults.standard.set(menuBarSensor.rawValue, forKey: "menuBarSensor") }
    }

    /// Talk to a development LaunchAgent instead of the root daemon
    /// (`defaults write com.antonarnaudov.fanpilot devHelper -bool true`).
    let useDevHelper = UserDefaults.standard.bool(forKey: "devHelper")

    private let smc: SMC?
    private let fanReader: FanReader?
    private let sensorReader: SensorReader?
    private let helper: HelperConnection
    private var timer: Timer?
    private var tickCount = 0
    private var pushTask: Task<Void, Never>?
    /// Bumped on every local edit, so a pull that raced an edit is ignored.
    private var editGeneration = 0
    /// Local edits the helper hasn't received yet (survives restarts: edits made
    /// while the helper was off are sent when it comes back).
    private var localChangesUnsent: Bool {
        get { UserDefaults.standard.bool(forKey: "configUnsent") }
        set { UserDefaults.standard.set(newValue, forKey: "configUnsent") }
    }

    init() {
        let smc = try? SMC()
        self.smc = smc
        fanReader = smc.map { FanReader(smc: $0) }
        sensorReader = smc.map { SensorReader(smc: $0) }
        helper = HelperConnection(privileged: !UserDefaults.standard.bool(forKey: "devHelper"))
        config = AppModel.loadLocalConfig()
        menuBarDisplay = UserDefaults.standard.string(forKey: "menuBarDisplay").flatMap(MenuBarDisplay.init) ?? .temperatureAndSpeed
        menuBarSensor = UserDefaults.standard.string(forKey: "menuBarSensor").map(SensorSelector.init) ?? .cpuMax
        refreshLocal()
        Task {
            if !useDevHelper, Snapshotter.directory == nil {
                if BundleLocation.canRegisterHelper {
                    BundleLocation.clearQuarantineAfterApproval()
                    do {
                        try await HelperService.prepare()
                    } catch {
                        lastError = HelperService.describe(error)
                    }
                } else {
                    lastError = BundleLocation.moveToApplicationsMessage
                }
            }
            await refreshHelper()
        }
        startTimer()
        // Speed up while a FanPilot window or the menu is on screen, slow down after.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        AppDelegate.onTerminate = { [weak self] in self?.flush() }
    }

    /// A FanPilot window or the menu bar window is on screen. While none is,
    /// FanPilot only keeps the menu bar label current: one light update every
    /// 5 s instead of a full one every 2 s.
    private(set) var surfacesVisible = false

    private func startTimer() {
        timer?.invalidate()
        let interval: TimeInterval = surfacesVisible ? 2 : 5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Let macOS batch this wake-up with others.
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateVisibility() {
        let visible = NSApp.windows.contains {
            // Status-item windows are always "visible"; real windows are taller.
            $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.height > 60
        }
        guard visible != surfacesVisible else { return }
        surfacesVisible = visible
        startTimer()
        if visible { tick() }
    }

    private var refreshing = false
    private var failedRefreshes = 0
    private var autoRestarted = false

    private func tick() {
        tickCount += 1
        refreshLocal()
        guard !refreshing else { return }
        Task { await refreshHelper() }  // skipped while one is still running
    }

    // MARK: - Readings

    var smcAvailable: Bool { smc != nil }

    struct Sample: Identifiable {
        let id = UUID()
        let date: Date
        let cpu: Double?
        let gpu: Double?
        let fanRPM: [Double]
    }

    /// The last ten minutes, one sample per refresh.
    private(set) var history: [Sample] = []

    /// Reading every sensor takes ~60 ms on an M4 Pro, so it never runs on the
    /// main thread: the UI keeps the last values until fresh ones arrive.
    private let readQueue = DispatchQueue(label: "com.antonarnaudov.fanpilot.readings", qos: .userInitiated)
    private var readingInFlight = false

    /// True while a page that lists every sensor is visible; otherwise only the
    /// groups the summaries and profiles use are read (about half the work).
    var needsAllSensors = false {
        didSet { if needsAllSensors && !oldValue { refreshLocal() } }
    }

    func refreshLocal() {
        guard !readingInFlight, let fanReader, let sensorReader else { return }
        // Nothing on screen and an icon-only menu bar item: there's nothing to read for.
        if !surfacesVisible && menuBarDisplay == .icon && Snapshotter.directory == nil { return }
        readingInFlight = true
        let groups: Set<SensorGroup>?
        var extraKeys: Set<String> = Set([menuBarSensor.smcKey].compactMap { $0 })
        if needsAllSensors {
            groups = nil
        } else if surfacesVisible || Snapshotter.directory != nil {
            groups = [.cpu, .gpu, .storage, .battery]
            extraKeys.formUnion(config.profiles.flatMap { profile in
                ([profile.rule] + Array(profile.fanOverrides.values)).compactMap(\.sensor.smcKey)
            })
        } else {
            // Just the menu bar label and the history chart.
            groups = Set<SensorGroup>([.cpu, .gpu]).union(menuBarSensor.groups)
        }
        readQueue.async { [weak self] in
            let fans = fanReader.fans()
            let readings = sensorReader.read(groups: groups, extraKeys: extraKeys)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(fans: fans, readings: readings) }
            }
        }
    }

    private func apply(fans newFans: [FanInfo], readings newReadings: [SensorReading]) {
        readingInFlight = false
        if newFans != fans { fans = newFans }
        if newReadings != readings { readings = newReadings }
        history.append(Sample(date: Date(), cpu: value(.cpuMax), gpu: value(.gpuMax), fanRPM: fans.map(\.actualRPM)))
        if history.count > 300 { history.removeFirst(history.count - 300) }
    }

    func value(_ selector: SensorSelector) -> Double? { selector.value(in: readings) }

    var menuTemperature: Double? { value(menuBarSensor) }

    var fastestFanRPM: Double? { fans.map(\.actualRPM).max() }

    func status(forFan index: Int) -> FanStatus? { helperState?.fans.first { $0.index == index } }

    var controlling: Bool { helperState?.fans.contains { $0.controlled } ?? false }

    // MARK: - Helper

    /// True once the helper is registered with macOS (approved or not).
    var helperRegistered: Bool {
        if useDevHelper { return helperStatus.isRunning }
        let status = HelperService.status
        return status == .enabled || status == .requiresApproval
    }

    var helperOutdated: Bool {
        if case .running(let version) = helperStatus { return version != FanPilot.version }
        return false
    }

    private var refreshAgain = false

    func refreshHelper() async {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refreshHelper() }
            }
        }
        if !useDevHelper {
            switch HelperService.status {
            case .notRegistered, .notFound:
                helperStatus = .notInstalled
                helperState = nil
                return
            case .requiresApproval:
                helperStatus = .needsApproval
                helperState = nil
                return
            default:
                break
            }
        }
        do {
            let state = try await helper.state()
            helperState = state
            helperStatus = .running(version: state.version)
        } catch {
            helperState = nil
            helperStatus = .notResponding("\(error)")
            helper.invalidate()
            failedRefreshes += 1
            // Approved but silent: usually macOS still pins an older build. Re-register once.
            if !useDevHelper, failedRefreshes >= 5, !autoRestarted, !busy, HelperService.status == .enabled {
                autoRestarted = true
                Task { await restartHelper() }
            }
            return
        }
        failedRefreshes = 0
        do {
            try await syncConfig()
        } catch {
            lastError = "Couldn't sync settings with the helper: \(error)"
        }
    }

    // MARK: - Config

    var activeProfile: Profile { config.activeProfile }

    /// Worked out locally (same rule as the helper), so a click shows at once
    /// instead of after the next helper round trip.
    var effectiveProfile: Profile {
        config.effectiveProfile(onBattery: helperState?.onBattery ?? false)
    }

    /// Switches profile. A profile that takes the fans over needs the helper,
    /// so picking one before it's allowed takes the user to the approval.
    func activate(_ profile: Profile) {
        updateConfig { $0.activeProfileID = profile.id }
        pushNow()
        guard !profile.isSystem, !busy else { return }
        switch helperStatus {
        case .notInstalled, .needsApproval: Task { await enableHelper() }
        default: break
        }
    }

    /// Applies a change at once in the UI; saving and sending it to the helper
    /// is debounced so slider drags don't flood either.
    func updateConfig(_ change: (inout FanPilotConfig) -> Void) {
        var next = config
        change(&next)
        config = next.normalized()
        editGeneration += 1
        localChangesUnsent = true
        schedulePush()
    }

    func update(_ profile: Profile) {
        updateConfig { config in
            if let index = config.profiles.firstIndex(where: { $0.id == profile.id }) {
                config.profiles[index] = profile
            }
        }
    }

    func addProfile(copying source: Profile? = nil) -> Profile {
        let base = source ?? Presets.balanced
        let profile = Profile(name: source.map { "\($0.name) Copy" } ?? "New Profile", symbol: base.symbol,
                              color: source?.color ?? "blue",
                              rule: base.rule.kind == .system ? Presets.balanced.rule : base.rule,
                              fanOverrides: base.fanOverrides)
        updateConfig { $0.profiles.append(profile) }
        return profile
    }

    func delete(_ profile: Profile) {
        guard config.profiles.count > 1 else { return }
        updateConfig { config in
            config.profiles.removeAll { $0.id == profile.id }
            if config.activeProfileID == profile.id { config.activeProfileID = config.profiles[0].id }
            if config.batteryProfileID == profile.id { config.batteryProfileID = nil }
        }
    }

    func resetBuiltIn(_ profile: Profile) {
        guard let preset = Presets.all.first(where: { $0.id == profile.id }) else { return }
        update(preset)
    }

    func isBuiltIn(_ profile: Profile) -> Bool { Presets.all.contains { $0.id == profile.id } }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    /// Sends the current config without waiting for the debounce.
    private func pushNow() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in await self?.push() }
    }

    private func push() async {
        saveLocalConfig()
        // Without a helper the edit stays marked unsent and goes out on connect.
        guard helperStatus.isRunning else {
            pushTask = nil
            return
        }
        do {
            try await send()
            lastError = nil
        } catch {
            lastError = "Could not update the helper: \(error)"
        }
        pushTask = nil
        // Show the helper's reaction now rather than at the next 2 s tick.
        await refreshHelper()
    }

    /// Sends the local config; clears the unsent mark only if nothing changed meanwhile.
    private func send() async throws {
        let generation = editGeneration
        try await helper.setConfig(config)
        if generation == editGeneration { localChangesUnsent = false }
    }

    /// Keeps app and helper in agreement. Local edits not yet sent win; otherwise
    /// the helper's config is the truth (it may have been changed elsewhere, e.g.
    /// by fanpilotctl). A fresh helper with the built-in config gets the app's.
    private func syncConfig() async throws {
        if localChangesUnsent {
            if pushTask == nil { try await send() }
            return
        }
        let generation = editGeneration
        let remote = try await helper.config()
        guard generation == editGeneration, !localChangesUnsent, pushTask == nil else { return }
        if remote == .default, config != .default {
            try await send()
        } else if remote != config {
            config = remote
            saveLocalConfig()
        }
    }

    /// Writes pending edits to disk; called when the app quits.
    func flush() {
        if pushTask != nil { saveLocalConfig() }
    }

    private static var localConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FanPilot/config.json")
    }

    private static func loadLocalConfig() -> FanPilotConfig {
        guard let data = try? Data(contentsOf: localConfigURL),
              let config = try? FanPilotJSON.decoder.decode(FanPilotConfig.self, from: data)
        else { return .default }
        return config.normalized()
    }

    private func saveLocalConfig() {
        let url = Self.localConfigURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FanPilotJSON.encoder.encode(config).write(to: url, options: .atomic)
    }

    // MARK: - Helper registration

    /// Registers the bundled helper if needed and, while macOS still waits for
    /// approval, opens System Settings › Login Items where the user allows it.
    func enableHelper() async {
        guard !useDevHelper else { return }
        guard BundleLocation.canRegisterHelper else {
            lastError = BundleLocation.moveToApplicationsMessage
            return
        }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            switch HelperService.status {
            case .notRegistered, .notFound: try await HelperService.register()
            default: break
            }
            if HelperService.status == .requiresApproval {
                HelperService.openApprovalSettings()
            }
            await reconnect()
        } catch {
            lastError = HelperService.describe(error)
            await refreshHelper()
        }
    }

    /// Re-registers the helper so macOS runs the build inside this app.
    func restartHelper() async {
        guard !useDevHelper else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            try await HelperService.reregister()
            await reconnect()
        } catch {
            lastError = HelperService.describe(error)
            await refreshHelper()
        }
    }

    /// Turns the helper off: macOS stops it (it gives the fans back first) and forgets it.
    func disableHelper() async {
        guard !useDevHelper else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            try await HelperService.unregister()
        } catch {
            lastError = HelperService.describe(error)
        }
        helper.invalidate()
        await refreshHelper()
    }

    private func reconnect() async {
        helper.invalidate()
        try? await Task.sleep(for: .seconds(1.5))
        await refreshHelper()
        if helperStatus.isRunning { try? await helper.setConfig(config) }
    }
}
