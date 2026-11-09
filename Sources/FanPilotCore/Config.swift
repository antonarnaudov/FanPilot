import Foundation

public struct CurvePoint: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Temperature in °C.
    public var temperature: Double
    /// Fan speed as a share of the fan's range: 0 = minimum RPM, 100 = maximum RPM.
    public var percent: Double

    public init(id: UUID = UUID(), _ temperature: Double, _ percent: Double) {
        self.id = id
        self.temperature = temperature
        self.percent = percent
    }

    /// A point with an id derived from its values, for built-in presets: the
    /// app and the helper then create identical defaults.
    static func preset(_ temperature: Double, _ percent: Double) -> CurvePoint {
        let t = Int((temperature * 10).rounded()), p = Int((percent * 10).rounded())
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%06X%06X", t, p))!
        return CurvePoint(id: id, temperature, percent)
    }
}

public enum FanRuleKind: String, Codable, CaseIterable, Sendable {
    /// macOS decides (Apple's default behaviour).
    case system
    /// A constant speed.
    case fixed
    /// Speed follows a temperature curve.
    case curve

    public var title: String {
        switch self {
        case .system: return "macOS"
        case .fixed: return "Fixed"
        case .curve: return "Curve"
        }
    }
}

/// What a curve rule does while the temperature is below its start point.
public enum CoolBehavior: String, Codable, CaseIterable, Sendable {
    /// Give the fans back to macOS (they usually idle at 0 RPM).
    case system
    /// Keep the fans at their minimum speed.
    case minimum

    public var title: String {
        switch self {
        case .system: return "Hand back to macOS"
        case .minimum: return "Keep at minimum speed"
        }
    }
}

public struct FanRule: Codable, Hashable, Sendable {
    public var kind: FanRuleKind
    /// For `fixed`: share of the fan's range, 0–100.
    public var fixedPercent: Double
    /// For `curve`: the temperature the curve follows.
    public var sensor: SensorSelector
    /// For `curve`: points sorted by temperature.
    public var points: [CurvePoint]
    /// Take the fans over when the temperature reaches this (°C).
    public var startTemperature: Double
    /// Hand them back when it falls to this (°C). Below `startTemperature`.
    public var stopTemperature: Double
    public var whenCool: CoolBehavior
    /// Speed only drops once the temperature has fallen this far (°C).
    public var hysteresis: Double
    /// Temperature smoothing time constant in seconds (0 = none).
    public var smoothing: Double
    /// Fastest speed increase, RPM per second.
    public var rampUp: Double
    /// Fastest speed decrease, RPM per second.
    public var rampDown: Double
    /// Seconds to hold a speed before letting it drop.
    public var spinDownDelay: Double
    /// Seconds the temperature must stay below `stopTemperature` before the fans
    /// go back to macOS, so brief dips don't hand them over and back (each
    /// takeover can take macOS several seconds). Optional so older configs decode.
    public var handBackSeconds: Double?

    public var handBackDelay: Double { handBackSeconds ?? 60 }

    public init(
        kind: FanRuleKind,
        fixedPercent: Double = 50,
        sensor: SensorSelector = .cpuMax,
        points: [CurvePoint] = [],
        startTemperature: Double = 60,
        stopTemperature: Double = 55,
        whenCool: CoolBehavior = .system,
        hysteresis: Double = 3,
        smoothing: Double = 3,
        rampUp: Double = 800,
        rampDown: Double = 150,
        spinDownDelay: Double = 8
    ) {
        self.kind = kind
        self.fixedPercent = fixedPercent
        self.sensor = sensor
        self.points = points
        self.startTemperature = startTemperature
        self.stopTemperature = stopTemperature
        self.whenCool = whenCool
        self.hysteresis = hysteresis
        self.smoothing = smoothing
        self.rampUp = rampUp
        self.rampDown = rampDown
        self.spinDownDelay = spinDownDelay
    }

    public static let system = FanRule(kind: .system)

    /// Clamps values into safe ranges and sorts the curve.
    public func normalized() -> FanRule {
        var rule = self
        rule.fixedPercent = rule.fixedPercent.clamped(0, 100)
        rule.points = rule.points
            .map { CurvePoint(id: $0.id, $0.temperature.clamped(20, 110), $0.percent.clamped(0, 100)) }
            .sorted { $0.temperature < $1.temperature }
        if rule.kind == .curve, rule.points.isEmpty {
            rule.points = [CurvePoint(rule.startTemperature, 0), CurvePoint(95, 100)]
        }
        rule.startTemperature = rule.startTemperature.clamped(20, 105)
        rule.stopTemperature = min(rule.stopTemperature, rule.startTemperature - 1).clamped(15, 104)
        rule.hysteresis = rule.hysteresis.clamped(0, 20)
        rule.smoothing = rule.smoothing.clamped(0, 60)
        rule.rampUp = rule.rampUp.clamped(50, 10_000)
        rule.rampDown = rule.rampDown.clamped(10, 10_000)
        rule.spinDownDelay = rule.spinDownDelay.clamped(0, 300)
        rule.handBackSeconds = rule.handBackSeconds.map { $0.clamped(0, 600) }
        return rule
    }
}

public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol shown in the menu.
    public var symbol: String
    /// Name of a system colour for the profile's icon ("blue", "green", …). Display only.
    public var color: String?
    /// The rule every fan follows unless it has an override.
    public var rule: FanRule
    /// Per-fan overrides, keyed by fan index.
    public var fanOverrides: [Int: FanRule]

    public init(id: UUID = UUID(), name: String, symbol: String, color: String? = nil, rule: FanRule,
                fanOverrides: [Int: FanRule] = [:]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.rule = rule
        self.fanOverrides = fanOverrides
    }

    /// One line describing what the profile does.
    public var summary: String {
        let rule = self.rule
        let base: String
        switch rule.kind {
        case .system: base = "Apple's fan control"
        case .fixed: base = String(format: "Fixed at %.0f%%", rule.fixedPercent)
        case .curve: base = String(format: "Fans on from %.0f°", rule.startTemperature)
        }
        return fanOverrides.isEmpty ? base : base + " · per-fan settings"
    }

    public func rule(forFan fan: Int) -> FanRule { fanOverrides[fan] ?? rule }

    /// True when no fan is ever taken over.
    public var isSystem: Bool {
        rule.kind == .system && fanOverrides.values.allSatisfy { $0.kind == .system }
    }
}

public struct SafetySettings: Codable, Hashable, Sendable {
    /// Above this (°C, hottest CPU/GPU sensor) every controlled fan goes to full speed.
    public var criticalTemperature: Double
    /// Full speed lasts until the temperature is this far below critical.
    public var releaseMargin: Double
    /// Seconds the temperature must stay at or above critical before full speed,
    /// so a single-core spike doesn't blast the fans. Optional so configs saved
    /// before it existed still decode.
    public var sustainSeconds: Double?

    public var sustain: Double { sustainSeconds ?? 5 }

    public init(criticalTemperature: Double = 95, releaseMargin: Double = 8, sustainSeconds: Double? = nil) {
        self.criticalTemperature = criticalTemperature
        self.releaseMargin = releaseMargin
        self.sustainSeconds = sustainSeconds
    }

    public func normalized() -> SafetySettings {
        SafetySettings(
            criticalTemperature: criticalTemperature.clamped(70, 105),
            releaseMargin: releaseMargin.clamped(2, 20),
            sustainSeconds: sustainSeconds.map { $0.clamped(0, 30) })
    }
}

public struct FanPilotConfig: Codable, Hashable, Sendable {
    public var profiles: [Profile]
    public var activeProfileID: UUID
    /// Optional profile to use while running on battery.
    public var batteryProfileID: UUID?
    public var safety: SafetySettings
    /// Seconds between control steps.
    public var interval: Double

    public init(profiles: [Profile], activeProfileID: UUID, batteryProfileID: UUID? = nil,
                safety: SafetySettings = SafetySettings(), interval: Double = 1) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.batteryProfileID = batteryProfileID
        self.safety = safety
        self.interval = interval
    }

    public func profile(id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    public var activeProfile: Profile { profile(id: activeProfileID) ?? profiles.first ?? Presets.system }

    /// The profile in force right now, given the power source.
    public func effectiveProfile(onBattery: Bool) -> Profile {
        if onBattery, let battery = profile(id: batteryProfileID) { return battery }
        return activeProfile
    }

    public func normalized() -> FanPilotConfig {
        var config = self
        config.profiles = config.profiles.map { profile in
            var p = profile
            p.rule = p.rule.normalized()
            p.fanOverrides = p.fanOverrides.mapValues { $0.normalized() }
            return p
        }
        if config.profiles.isEmpty { config.profiles = Presets.all }
        // Built-ins added in a newer version appear in saved configs too, at their place.
        // (Built-in profiles can be edited and reset, never deleted.)
        for (index, preset) in Presets.all.enumerated() where config.profile(id: preset.id) == nil {
            config.profiles.insert(preset, at: Swift.min(index, config.profiles.count))
        }
        if config.profile(id: config.activeProfileID) == nil { config.activeProfileID = config.profiles[0].id }
        if config.profile(id: config.batteryProfileID) == nil { config.batteryProfileID = nil }
        config.safety = config.safety.normalized()
        config.interval = config.interval.clamped(0.5, 5)
        return config
    }

    public static var `default`: FanPilotConfig {
        FanPilotConfig(profiles: Presets.all, activeProfileID: Presets.systemID)
    }
}

public enum Presets {
    // Stable ids so the app and helper agree on built-ins.
    public static let systemID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let coolID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public static let balancedID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let quietID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    public static let maxID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    public static let silentCoolID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    public static let system = Profile(id: systemID, name: "macOS", symbol: "apple.logo", color: "blue", rule: .system)

    /// Fans on early but held at speeds you can't hear (up to about 28% of the
    /// fans' range until 82 °C); louder only near the safety limit. Slow ramps
    /// and long smoothing so the sound never changes abruptly; the fans idle at their
    /// minimum instead of stopping and starting.
    public static let silentCool = Profile(
        id: silentCoolID, name: "Silent Cool", symbol: "leaf.fill", color: "mint",
        rule: FanRule(
            kind: .curve, sensor: .cpuMax,
            points: [CurvePoint.preset(45, 0), CurvePoint.preset(60, 12), CurvePoint.preset(72, 20), CurvePoint.preset(82, 28),
                     CurvePoint.preset(90, 35), CurvePoint.preset(95, 60)],
            startTemperature: 45, stopTemperature: 40, whenCool: .minimum,
            hysteresis: 4, smoothing: 10, rampUp: 120, rampDown: 40, spinDownDelay: 45))

    /// Fans come on early and run hard: for long builds and renders.
    public static let cool = Profile(
        id: coolID, name: "Cool", symbol: "snowflake", color: "cyan",
        rule: FanRule(
            kind: .curve, sensor: .cpuMax,
            points: [CurvePoint.preset(50, 0), CurvePoint.preset(65, 35), CurvePoint.preset(78, 70), CurvePoint.preset(88, 100)],
            startTemperature: 50, stopTemperature: 45, smoothing: 6))

    public static let balanced = Profile(
        id: balancedID, name: "Balanced", symbol: "dial.medium", color: "green",
        rule: FanRule(
            kind: .curve, sensor: .cpuMax,
            points: [CurvePoint.preset(60, 0), CurvePoint.preset(72, 30), CurvePoint.preset(84, 65), CurvePoint.preset(92, 100)],
            startTemperature: 60, stopTemperature: 54, smoothing: 6))

    public static let quiet = Profile(
        id: quietID, name: "Quiet", symbol: "moon.fill", color: "indigo",
        rule: FanRule(
            kind: .curve, sensor: .cpuMax,
            points: [CurvePoint.preset(70, 0), CurvePoint.preset(84, 35), CurvePoint.preset(95, 100)],
            startTemperature: 70, stopTemperature: 63, smoothing: 6))

    public static let max = Profile(
        id: maxID, name: "Full speed", symbol: "wind", color: "orange",
        rule: FanRule(kind: .fixed, fixedPercent: 100))

    public static let all = [system, silentCool, cool, balanced, quiet, max]
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
