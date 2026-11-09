import Foundation
import SMCKit

/// Fan mode values the SMC reports in `F<n>Md` on Apple Silicon.
public enum FanModeValue: Int, Codable, Sendable {
    /// Firmware automatic.
    case auto = 0
    /// Forced: the SMC follows `F<n>Tg`.
    case manual = 1
    /// Owned by macOS's thermal manager (thermalmonitord).
    case system = 3
}

public struct FanInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let actualRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double?
    public let modeRaw: Int?

    public var name: String { "Fan \(index + 1)" }
    /// Limits read correctly; a fan without them is never controlled.
    public var isValid: Bool { minRPM.isFinite && maxRPM.isFinite && maxRPM > minRPM && minRPM >= 0 }
    public var isManual: Bool { modeRaw == FanModeValue.manual.rawValue }
    public var range: Double { max(maxRPM - minRPM, 1) }

    /// Speed as a share of the fan's range: 0 at minimum, 1 at maximum.
    public var fraction: Double {
        guard actualRPM > 0 else { return 0 }
        return min(max((actualRPM - minRPM) / range, 0), 1)
    }

    public func rpm(forPercent percent: Double) -> Double {
        minRPM + range * min(max(percent, 0), 100) / 100
    }

    public init(index: Int, actualRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double?, modeRaw: Int?) {
        self.index = index
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.modeRaw = modeRaw
    }
}

enum FanKeys {
    static func actual(_ i: Int) -> FourCC { FourCC("F\(i)Ac") }
    static func minimum(_ i: Int) -> FourCC { FourCC("F\(i)Mn") }
    static func maximum(_ i: Int) -> FourCC { FourCC("F\(i)Mx") }
    static func target(_ i: Int) -> FourCC { FourCC("F\(i)Tg") }
    static func modeUpper(_ i: Int) -> FourCC { FourCC("F\(i)Md") }
    /// M5 and later spell the mode key in lowercase.
    static func modeLower(_ i: Int) -> FourCC { FourCC("F\(i)md") }
    static let count: FourCC = "FNum"
    /// Diagnostic flag that makes thermalmonitord let go of the fans (M3/M4).
    static let test: FourCC = "Ftst"
    /// Intel: bitmask of forced fans.
    static let intelForce: FourCC = "FS! "
}

/// Reads fan state. Needs no privileges.
public final class FanReader: @unchecked Sendable {
    private let smc: SMC
    public let count: Int
    private let modeKeys: [FourCC?]
    private let lock = NSLock()
    private var lastLimits: [Int: (min: Double, max: Double)] = [:]

    public init(smc: SMC) {
        self.smc = smc
        let count = Int((try? smc.number(FanKeys.count)) ?? 0)
        self.count = count
        self.modeKeys = (0..<count).map { i in
            if smc.has(FanKeys.modeUpper(i)) { return FanKeys.modeUpper(i) }
            if smc.has(FanKeys.modeLower(i)) { return FanKeys.modeLower(i) }
            return nil
        }
    }

    public func modeKey(_ fan: Int) -> FourCC? { fan < modeKeys.count ? modeKeys[fan] : nil }

    public func fans() -> [FanInfo] {
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        lock.lock(); defer { lock.unlock() }
        return (0..<count).map { i in
            // A failed or garbage read of the limits falls back to the last good one.
            var minRPM = finite(try? smc.number(FanKeys.minimum(i)))
            var maxRPM = finite(try? smc.number(FanKeys.maximum(i)))
            if let lo = minRPM, let hi = maxRPM, hi > lo, lo >= 0 {
                lastLimits[i] = (lo, hi)
            } else if let last = lastLimits[i] {
                minRPM = last.min
                maxRPM = last.max
            }
            return FanInfo(
                index: i,
                actualRPM: max(finite(try? smc.number(FanKeys.actual(i))) ?? 0, 0),
                minRPM: minRPM ?? 0,
                maxRPM: maxRPM ?? 0,
                targetRPM: finite(try? smc.number(FanKeys.target(i))),
                modeRaw: modeKey(i).flatMap { finite(try? smc.number($0)) }.map { Int($0) })
        }
    }

    /// The value of the global `Ftst` unlock flag, if this Mac has one.
    public func testFlag() -> Int? {
        (try? smc.number(FanKeys.test)).map { Int($0) }
    }
}
