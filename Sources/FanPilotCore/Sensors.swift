import Foundation
import SMCKit

public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, storage, battery, wireless, other

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .storage: return "SSD"
        case .battery: return "Battery"
        case .wireless: return "Wireless"
        case .other: return "Other"
        }
    }
}

public struct SensorReading: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let group: SensorGroup
    public let value: Double

    public var name: String {
        if let known = knownName { return known }
        return "\(group.title) · \(key)"
    }

    /// A human name, only where the key's meaning is well established.
    public var knownName: String? { SensorCatalog.knownNames[key] }
}

/// What a fan rule follows: a summary of a group of sensors, or one SMC key.
public struct SensorSelector: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let cpuMax = SensorSelector(rawValue: "cpu.max")
    public static let cpuAverage = SensorSelector(rawValue: "cpu.avg")
    public static let gpuMax = SensorSelector(rawValue: "gpu.max")
    public static let hottest = SensorSelector(rawValue: "soc.max")
    public static let storage = SensorSelector(rawValue: "ssd.max")
    public static let battery = SensorSelector(rawValue: "battery.max")
    public static func key(_ key: String) -> SensorSelector { SensorSelector(rawValue: "smc:\(key)") }

    public static let summaries: [SensorSelector] = [.cpuMax, .cpuAverage, .gpuMax, .hottest, .storage, .battery]

    public var smcKey: String? { rawValue.hasPrefix("smc:") ? String(rawValue.dropFirst(4)) : nil }

    public var title: String {
        switch self {
        case .cpuMax: return "CPU (hottest core)"
        case .cpuAverage: return "CPU (average)"
        case .gpuMax: return "GPU (hottest)"
        case .hottest: return "Hottest of CPU and GPU"
        case .storage: return "SSD"
        case .battery: return "Battery"
        default:
            if let key = smcKey {
                return SensorCatalog.knownNames[key] ?? "Sensor \(key)"
            }
            return rawValue
        }
    }

    /// The groups whose sensors this selector needs.
    public var groups: Set<SensorGroup> {
        switch self {
        case .cpuMax, .cpuAverage: return [.cpu]
        case .gpuMax: return [.gpu]
        case .hottest: return [.cpu, .gpu]
        case .storage: return [.storage]
        case .battery: return [.battery]
        default: return []
        }
    }

    public func value(in readings: [SensorReading]) -> Double? {
        func values(_ groups: Set<SensorGroup>) -> [Double] {
            readings.filter { groups.contains($0.group) }.map(\.value)
        }
        switch self {
        case .cpuMax: return values([.cpu]).max()
        case .cpuAverage:
            let v = values([.cpu])
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        case .gpuMax: return values([.gpu]).max()
        case .hottest: return values([.cpu, .gpu]).max()
        case .storage: return values([.storage]).max()
        case .battery: return values([.battery]).max()
        default:
            guard let key = smcKey else { return nil }
            return readings.first { $0.key == key }?.value
        }
    }
}

public enum SensorCatalog {
    #if arch(arm64)
    static let isAppleSilicon = true
    #else
    static let isAppleSilicon = false
    #endif

    /// Names only where the meaning of the key is well established.
    public static let knownNames: [String: String] = [
        "TB0T": "Battery 1", "TB1T": "Battery 2", "TB2T": "Battery 3",
        "TH0x": "SSD", "TH0a": "SSD A", "TH0b": "SSD B",
        "TW0P": "Wi-Fi / Bluetooth",
        // Intel
        "TC0P": "CPU proximity", "TC0D": "CPU die", "TC0E": "CPU PECI", "TC0F": "CPU PECI 2",
        "TG0P": "GPU proximity", "TG0D": "GPU die",
    ]

    public static func group(for key: String) -> SensorGroup {
        let chars = Array(key)
        guard chars.count == 4, chars[0] == "T" else { return .other }
        let prefix = String(chars[0...1])
        if isAppleSilicon {
            switch prefix {
            case "Tp", "Te": return .cpu
            case "Tg": return .gpu
            case "TH": return .storage
            case "TW": return .wireless
            case "TB" where chars[3] == "T": return .battery
            default: return .other
            }
        } else {
            switch prefix {
            case "TC": return .cpu
            case "TG": return .gpu
            case "TH": return .storage
            case "TW": return .wireless
            case "TB" where chars[3] == "T": return .battery
            default: return .other
            }
        }
    }
}

/// Finds the SMC temperature keys once and reads them.
///
/// Many SMC keys are placeholders that sit at a round number and never move
/// (on an M4 Pro dozens of `Tp0*` keys read exactly 40.00). A sensor counts as
/// live once it shows a fractional value or changes, so placeholders stay out
/// of summaries like "CPU (hottest core)".
public final class SensorReader: @unchecked Sendable {
    private let smc: SMC
    private let lock = NSLock()
    private var keys: [(key: FourCC, group: SensorGroup)] = []
    private var firstSeen: [String: Double] = [:]
    private var moved: Set<String> = []

    public init(smc: SMC) {
        self.smc = smc
    }

    private static let validRange = 1.0..<130.0

    private func discoverLocked() {
        guard keys.isEmpty else { return }
        for key in smc.allKeys() {
            let name = key.string
            guard name.hasPrefix("T"), let info = try? smc.info(key) else { continue }
            let type = info.type.string
            guard type == "flt " || type == "sp78" || type == "fpe2" else { continue }
            keys.append((key, SensorCatalog.group(for: name)))
        }
    }

    /// Reads live sensors, optionally only some groups (plus extra keys).
    public func read(groups: Set<SensorGroup>? = nil, extraKeys: Set<String> = []) -> [SensorReading] {
        lock.lock(); defer { lock.unlock() }
        discoverLocked()
        var readings: [SensorReading] = []
        for (key, group) in keys {
            let name = key.string
            if let groups, !groups.contains(group), !extraKeys.contains(name) { continue }
            guard let value = try? smc.number(key), value.isFinite, Self.validRange.contains(value) else { continue }
            if let first = firstSeen[name] {
                if first != value { moved.insert(name) }
            } else {
                firstSeen[name] = value
            }
            let live = value != value.rounded() || moved.contains(name)
            guard live else { continue }
            readings.append(SensorReading(key: name, group: group, value: value))
        }
        return readings
    }
}
