import Foundation
import SMCKit

public enum FanControlError: Error, CustomStringConvertible {
    case noModeKey(Int)
    case thermalManagerRefused(Int, SMCError)
    case smc(SMCError)
    case cancelled
    case invalidTarget(Int)

    public var description: String {
        switch self {
        case .noModeKey(let fan): return "fan \(fan + 1) has no mode key"
        case .thermalManagerRefused(let fan, let error):
            return "macOS did not hand over fan \(fan + 1) (\(error))"
        case .smc(let error): return error.description
        case .cancelled: return "takeover cancelled (stopping or going to sleep)"
        case .invalidTarget(let fan): return "fan \(fan + 1): no valid target speed"
        }
    }
}

/// Takes fans into manual mode and gives them back. Needs root.
///
/// Apple Silicon M3/M4: thermalmonitord owns the fans (mode 3) and the firmware
/// refuses a mode write with 0x82 until the diagnostic flag `Ftst` is set to 1.
/// After that the mode write starts to succeed within roughly 1–6 seconds.
/// `Ftst` must stay 1 while any fan is manual and is cleared as soon as none is,
/// because a stuck `Ftst` keeps macOS's thermal manager from managing the fans.
/// Sleep resets `Ftst` in firmware, so after wake fans are engaged again.
///
/// M5 and later: lowercase `F<n>md`, no `Ftst`, the mode write goes straight through.
/// Intel: the `FS! ` bitmask forces fans and targets use `fpe2`.
public final class FanController: @unchecked Sendable {
    public typealias Logger = (String) -> Void

    private let smc: SMC
    private let reader: FanReader
    private let log: Logger
    private let dryRun: Bool
    private let hasTestFlag: Bool
    private let isIntel: Bool
    private var testFlagHeld = false
    private var manual: Set<Int> = []
    private var dryRunTargets: [Int: Double] = [:]
    private let cancelLock = NSLock()
    private var unlockCancelled = false

    /// How long to keep retrying the mode write after setting `Ftst`.
    public var unlockTimeout: TimeInterval = 10

    /// Stops any takeover in progress and refuses new ones (shutdown, sleep).
    /// Safe to call from any thread; the waiting loop notices within 0.1 s.
    public func cancelUnlock() {
        cancelLock.lock(); unlockCancelled = true; cancelLock.unlock()
    }

    /// Allows takeovers again (after wake).
    public func allowUnlock() {
        cancelLock.lock(); unlockCancelled = false; cancelLock.unlock()
    }

    private var isUnlockCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return unlockCancelled
    }

    /// FanPilot believes it holds this fan (it may have lost it to macOS since).
    public func holds(_ fan: Int) -> Bool { manual.contains(fan) }

    /// FanPilot holds the global `Ftst` flag, so macOS isn't managing any fan.
    public var holdsUnlockFlag: Bool { testFlagHeld }

    public init(smc: SMC, reader: FanReader, dryRun: Bool = false, log: @escaping Logger) {
        self.smc = smc
        self.reader = reader
        self.dryRun = dryRun
        self.log = log
        self.hasTestFlag = smc.has(FanKeys.test)
        self.isIntel = smc.has(FanKeys.intelForce)
    }

    public var fanCount: Int { reader.count }
    public var supportsUnlockFlag: Bool { hasTestFlag }

    private func write(_ key: FourCC, _ value: Double) throws {
        if dryRun {
            // Target writes happen every step; log only the mode and unlock writes.
            if !key.string.hasSuffix("Tg") { log("dry run: would write \(key) = \(value)") }
            return
        }
        try smc.write(key, number: value)
    }

    private func readMode(_ fan: Int) -> Int? {
        if dryRun { return manual.contains(fan) ? 1 : 3 }
        guard let key = reader.modeKey(fan) else { return nil }
        return (try? smc.number(key)).map { Int($0) }
    }

    /// True when the SMC reports the fan as manual (forced).
    public func isManual(_ fan: Int) -> Bool {
        if isIntel {
            guard !dryRun, let mask = try? smc.number(FanKeys.intelForce) else { return manual.contains(fan) }
            return (Int(mask) >> fan) & 1 == 1
        }
        return readMode(fan) == FanModeValue.manual.rawValue
    }

    /// Puts a fan into manual mode. Blocks for up to `unlockTimeout` seconds
    /// on M3/M4 while macOS lets go.
    public func engage(_ fan: Int) throws {
        if isIntel {
            let mask = (try? smc.number(FanKeys.intelForce)).map { Int($0) } ?? 0
            try write(FanKeys.intelForce, Double(mask | (1 << fan)))
            manual.insert(fan)
            return
        }
        guard let modeKey = reader.modeKey(fan) else { throw FanControlError.noModeKey(fan) }
        if isUnlockCancelled { throw FanControlError.cancelled }
        // Hold Ftst for as long as FanPilot owns any fan: without it macOS's
        // thermal manager takes manual fans back after a while (M3/M4).
        let flagIsOff = dryRun ? !testFlagHeld : (reader.testFlag() ?? 0) == 0
        if hasTestFlag, flagIsOff {
            try setTestFlag(true)
            log("Ftst set: macOS's thermal manager leaves the fans to FanPilot")
        }
        if readMode(fan) == FanModeValue.manual.rawValue {
            manual.insert(fan)
            return
        }
        do {
            try write(modeKey, 1)
            manual.insert(fan)
            log("fan \(fan + 1): manual")
            return
        } catch let error as SMCError where hasTestFlag && error != .notPrivileged {
            log("fan \(fan + 1): mode write refused (\(error)); waiting for macOS to let go")
        }

        try setTestFlag(true)
        let started = Date()
        var lastError = SMCError.firmware(0x82)
        while Date().timeIntervalSince(started) < unlockTimeout, !isUnlockCancelled {
            do {
                try write(modeKey, 1)
                manual.insert(fan)
                log(String(format: "fan %d: manual after %.1fs", fan + 1, Date().timeIntervalSince(started)))
                return
            } catch let error as SMCError {
                lastError = error
                if error == .notPrivileged { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        // The fan isn't ours: forget it, and stop holding Ftst if no fan is.
        manual.remove(fan)
        if manual.isEmpty { releaseTestFlag() }
        if isUnlockCancelled { throw FanControlError.cancelled }
        throw FanControlError.thermalManagerRefused(fan, lastError)
    }

    private func setTestFlag(_ on: Bool) throws {
        guard hasTestFlag else { return }
        var attempt = 0
        while true {
            do {
                try write(FanKeys.test, on ? 1 : 0)
                testFlagHeld = on
                return
            } catch let error as SMCError {
                attempt += 1
                if attempt >= 20 || error == .notPrivileged { throw FanControlError.smc(error) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func releaseTestFlag() {
        guard hasTestFlag else { return }
        let current = dryRun ? (testFlagHeld ? 1 : 0) : reader.testFlag() ?? 0
        guard testFlagHeld || current != 0 else { return }
        do {
            try setTestFlag(false)
            log("Ftst cleared: macOS manages the fans")
        } catch {
            log("could not clear Ftst: \(error)")
        }
    }

    /// Sets the target speed of a fan that is in manual mode.
    public func setTarget(_ fan: Int, rpm: Double) throws {
        guard rpm.isFinite, rpm >= 0 else { throw FanControlError.invalidTarget(fan) }
        var attempt = 0
        while true {
            do {
                try write(FanKeys.target(fan), rpm)
                if dryRun { dryRunTargets[fan] = rpm }
                return
            } catch let error as SMCError {
                // 0x87 (size mismatch) has been seen even when the value was applied.
                if error == .firmware(0x87) { return }
                attempt += 1
                if attempt >= 10 || error == .notPrivileged { throw FanControlError.smc(error) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Gives one fan back to macOS. Clears `Ftst` when no fan is manual any more.
    public func release(_ fan: Int) {
        defer {
            manual.remove(fan)
            if manual.isEmpty { releaseTestFlag() }
        }
        if isIntel {
            if let mask = try? smc.number(FanKeys.intelForce) {
                try? write(FanKeys.intelForce, Double(Int(mask) & ~(1 << fan)))
            }
            return
        }
        guard let modeKey = reader.modeKey(fan) else { return }
        let mode = readMode(fan)
        guard mode != FanModeValue.system.rawValue, mode != FanModeValue.auto.rawValue else { return }
        do {
            try write(modeKey, Double(FanModeValue.auto.rawValue))
            log("fan \(fan + 1): back to automatic")
        } catch {
            log("fan \(fan + 1): could not set automatic (\(error)); clearing Ftst still returns it to macOS")
        }
    }

    /// Gives every fan back to macOS and clears `Ftst`. Safe to call any time.
    public func releaseAll() {
        for fan in 0..<reader.count { release(fan) }
        releaseTestFlag()
    }

    /// True when a previous run left fans forced or `Ftst` set.
    public func needsRecovery() -> Bool {
        if dryRun { return false }
        if hasTestFlag, (reader.testFlag() ?? 0) != 0 { return true }
        return (0..<reader.count).contains { isManual($0) }
    }

    public func dryRunTarget(_ fan: Int) -> Double? { dryRunTargets[fan] }
}
