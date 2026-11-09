import FanPilotCore
import Foundation
import SMCKit
import SystemConfiguration
import os

/// The root helper: runs the control loop and serves the app over XPC.
///
/// All SMC access happens on `queue`. XPC calls only touch the config and the
/// published snapshot, under `lock`, so the app never waits on the SMC.
final class Helper: NSObject, FanPilotHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let smc: SMC
    private let fans: FanReader
    private let sensors: SensorReader
    private var controller: FanController!
    private let dryRun: Bool
    private let queue = DispatchQueue(label: "com.antonarnaudov.fanpilot.control")
    private let logger = Logger(subsystem: FanPilot.logSubsystem, category: "helper")

    // Guarded by `lock`.
    private let lock = NSLock()
    private var config: FanPilotConfig
    private var snapshot: HelperState
    private var events: [HelperEvent] = []

    // Control queue only.
    private var fanStates: [Int: FanControlState] = [:]
    private var controlled: Set<Int> = []
    private var lastWritten: [Int: (rpm: Double, at: Date)] = [:]
    private var retryAt: [Int: Date] = [:]
    /// When each fan was last taken over: its mode can read back late, so the
    /// "did macOS take it back?" check waits a moment.
    private var engagedAt: [Int: Date] = [:]
    private var fanErrors: [Int: String] = [:]
    private var lastStep: Date?
    private var sleeping = false
    private var timer: DispatchSourceTimer?
    private var timerInterval: Double = 0

    init(dryRun: Bool) throws {
        smc = try SMC()
        fans = FanReader(smc: smc)
        sensors = SensorReader(smc: smc)
        self.dryRun = dryRun
        config = Helper.loadConfig()
        snapshot = HelperState(
            version: FanPilot.version, isRoot: getuid() == 0, dryRun: dryRun, effectiveProfileID: nil,
            onBattery: false, sleeping: false, safetyActive: false, unlockFlag: nil, fans: [], events: [],
            updated: Date())
        super.init()
        controller = FanController(smc: smc, reader: fans, dryRun: dryRun) { [weak self] message in
            self?.record(message)
        }
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            record("helper \(FanPilot.version) started (\(getuid() == 0 ? "root" : "user")\(dryRun ? ", dry run" : ""), \(fans.count) fans, Ftst \(controller.supportsUnlockFlag ? "present" : "absent"))")
            if controller.needsRecovery() {
                record("fans were left in manual mode by an earlier run; returning them to macOS first")
                controller.releaseAll()
            }
            reschedule()
            tick()
        }
    }

    /// Returns every fan to macOS. Called on SIGTERM (launchctl bootout, uninstall).
    func shutdown() {
        // Stop a takeover that's waiting on macOS first, so the release below
        // runs within launchd's exit timeout.
        controller.cancelUnlock()
        queue.sync {
            timer?.cancel()
            controller.releaseAll()
            controlled.removeAll()
            record("helper stopped; fans returned to macOS")
        }
    }

    func prepareForSleep() {
        controller.cancelUnlock()
        queue.sync {
            sleeping = true
            let held = !controlled.isEmpty || controller.needsRecovery()
            // Always release: it also clears fans the controller still thinks it holds.
            controller.releaseAll()
            if held { record("going to sleep: fans returned to macOS") }
            controlled.removeAll()
            lastWritten.removeAll()
            fanStates.removeAll()
            publish(profile: nil, onBattery: snapshot.onBattery, statuses: [], safety: false)
        }
    }

    func didWake() {
        controller.allowUnlock()
        queue.async { [self] in
            sleeping = false
            lastStep = nil
            retryAt.removeAll()
            record("woke up: resuming control")
            tick()
        }
    }

    private func reschedule() {
        let interval = currentConfig().interval
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Control loop

    private func tick() {
        let now = Date()
        let config = currentConfig()
        let dt = lastStep.map { min(now.timeIntervalSince($0), 10) } ?? config.interval
        lastStep = now
        guard !sleeping else { return }

        let onBattery = PowerSource.isOnBattery()
        let profile = config.effectiveProfile(onBattery: onBattery)
        let fanInfos = fans.fans()

        var groups: Set<SensorGroup> = [.cpu, .gpu]
        var extraKeys: Set<String> = []
        for fan in fanInfos {
            let rule = profile.rule(forFan: fan.index)
            groups.formUnion(rule.sensor.groups)
            if let key = rule.sensor.smcKey { extraKeys.insert(key) }
        }
        let readings = sensors.read(groups: groups, extraKeys: extraKeys)
        let hottest = SensorSelector.hottest.value(in: readings)

        var statuses: [FanStatus] = []
        var safety = false
        for fan in fanInfos {
            let rule = profile.rule(forFan: fan.index)
            var state = fanStates[fan.index] ?? FanControlState()
            guard fan.isValid else {
                // No trustworthy limits from the SMC: leave this fan to macOS.
                apply(FanDecision(command: .system, reason: "Fan readings unavailable, macOS controls the fan",
                                  temperature: nil), to: fan, now: now)
                statuses.append(FanStatus(index: fan.index, controlled: false, commandedRPM: nil, temperature: nil,
                                          reason: "Fan readings unavailable", error: nil))
                continue
            }
            let decision = CurveEngine.step(
                rule: rule, temperature: rule.sensor.value(in: readings), hottest: hottest, fan: fan,
                safety: config.safety, state: &state, now: now, dt: dt,
                unlockHeld: controller.holdsUnlockFlag)
            if state.safety && !safety && !snapshot.safetyActive {
                record(decision.reason)
            }
            fanStates[fan.index] = state
            safety = safety || state.safety
            apply(decision, to: fan, now: now)
            statuses.append(FanStatus(
                index: fan.index,
                controlled: controlled.contains(fan.index),
                commandedRPM: controlled.contains(fan.index) ? lastWritten[fan.index]?.rpm : nil,
                temperature: decision.temperature,
                reason: decision.reason,
                error: fanErrors[fan.index]))
        }
        if snapshot.safetyActive && !safety {
            record(String(format: "safety released (%.0f°C)", hottest ?? 0))
        }
        publish(profile: profile, onBattery: onBattery, statuses: statuses, safety: safety)
    }

    private func apply(_ decision: FanDecision, to fan: FanInfo, now: Date) {
        let i = fan.index
        switch decision.command {
        case .system:
            // Also release a fan the controller still holds after a failed re-engage.
            if controlled.contains(i) || controller.holds(i) {
                controller.release(i)
                controlled.remove(i)
                record("fan \(i + 1): \(decision.reason)")
            }
            lastWritten[i] = nil
            fanErrors[i] = nil
            retryAt[i] = nil

        case .manual(let rpm):
            if let retry = retryAt[i], now < retry { return }
            let settling = engagedAt[i].map { now.timeIntervalSince($0) < 3 } ?? false
            if !controlled.contains(i) || (!settling && !controller.isManual(i)) {
                if controlled.contains(i) { record("fan \(i + 1): macOS took the fan back; engaging again") }
                do {
                    try controller.engage(i)
                    controlled.insert(i)
                    engagedAt[i] = Date()
                    lastWritten[i] = nil
                    fanErrors[i] = nil
                    retryAt[i] = nil
                    record("fan \(i + 1): FanPilot in control (\(decision.reason))")
                } catch {
                    controlled.remove(i)
                    fanErrors[i] = "\(error)"
                    retryAt[i] = now.addingTimeInterval(5)
                    record("fan \(i + 1): \(error); retrying in 5 s")
                    return
                }
            }
            let rounded = rpm.rounded()
            let stale = lastWritten[i].map { abs($0.rpm - rounded) >= 10 || now.timeIntervalSince($0.at) >= 15 } ?? true
            guard stale else { return }
            do {
                try controller.setTarget(i, rpm: rounded)
                lastWritten[i] = (rounded, now)
                fanErrors[i] = nil
            } catch {
                fanErrors[i] = "\(error)"
                record("fan \(i + 1): could not set \(Int(rounded)) RPM: \(error)")
            }
        }
    }

    private func publish(profile: Profile?, onBattery: Bool, statuses: [FanStatus], safety: Bool) {
        let flag = fans.testFlag()
        lock.lock()
        snapshot = HelperState(
            version: FanPilot.version, isRoot: getuid() == 0, dryRun: dryRun, effectiveProfileID: profile?.id,
            onBattery: onBattery, sleeping: sleeping, safetyActive: safety, unlockFlag: flag, fans: statuses,
            events: events, updated: Date())
        lock.unlock()
    }

    // MARK: - Events and config

    private func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
        lock.lock()
        events.append(HelperEvent(message: message))
        if events.count > 200 { events.removeFirst(events.count - 200) }
        lock.unlock()
    }

    private func currentConfig() -> FanPilotConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    private static func loadConfig() -> FanPilotConfig {
        guard let data = try? Data(contentsOf: FanPilot.helperConfigURL),
              let config = try? FanPilotJSON.decoder.decode(FanPilotConfig.self, from: data)
        else { return .default }
        return config.normalized()
    }

    private func saveConfig(_ config: FanPilotConfig) throws {
        let url = FanPilot.helperConfigURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FanPilotJSON.encoder.encode(config).write(to: url, options: .atomic)
    }

    // MARK: - XPC

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard uid == 0 || uid == getuid() || uid == Helper.consoleUserID() else {
            record("refused a connection from uid \(uid) (not the logged-in user)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: FanPilotHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    private static func consoleUserID() -> uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return nil }
        return uid
    }

    func version(reply: @escaping (String) -> Void) {
        reply(FanPilot.version)
    }

    func state(reply: @escaping (Data) -> Void) {
        lock.lock()
        let state = snapshot
        lock.unlock()
        reply((try? FanPilotJSON.encoder.encode(state)) ?? Data())
    }

    func config(reply: @escaping (Data) -> Void) {
        reply((try? FanPilotJSON.encoder.encode(currentConfig())) ?? Data())
    }

    func setConfig(_ json: Data, reply: @escaping (String?) -> Void) {
        let decoded: FanPilotConfig
        do {
            decoded = try FanPilotJSON.decoder.decode(FanPilotConfig.self, from: json).normalized()
        } catch {
            reply("invalid config: \(error)")
            return
        }
        lock.lock()
        let previous = config
        config = decoded
        // Saved under the lock, so concurrent updates reach the disk in order.
        let saveError: Error?
        do {
            try saveConfig(decoded)
            saveError = nil
        } catch {
            saveError = error
        }
        lock.unlock()
        if let saveError { record("could not save config: \(saveError)") }
        if previous.activeProfileID != decoded.activeProfileID || previous.batteryProfileID != decoded.batteryProfileID {
            record("profile: \(decoded.activeProfile.name)")
        }
        queue.async { [self] in
            reschedule()
            tick()
        }
        reply(nil)
    }
}
