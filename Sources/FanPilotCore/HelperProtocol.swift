import Foundation

/// XPC interface of the root helper. Payloads are JSON (`HelperState`,
/// `FanPilotConfig`) so the protocol stays small and versionable.
@objc public protocol FanPilotHelperProtocol {
    /// The helper's version string.
    func version(reply: @escaping (String) -> Void)
    /// JSON-encoded `HelperState`.
    func state(reply: @escaping (Data) -> Void)
    /// JSON-encoded `FanPilotConfig`.
    func config(reply: @escaping (Data) -> Void)
    /// Replaces the config. Replies nil on success, or an error message.
    func setConfig(_ json: Data, reply: @escaping (String?) -> Void)
}

public struct FanStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// FanPilot currently holds this fan in manual mode.
    public var controlled: Bool
    public var commandedRPM: Double?
    public var temperature: Double?
    public var reason: String
    public var error: String?

    public init(index: Int, controlled: Bool, commandedRPM: Double?, temperature: Double?, reason: String, error: String?) {
        self.index = index
        self.controlled = controlled
        self.commandedRPM = commandedRPM
        self.temperature = temperature
        self.reason = reason
        self.error = error
    }
}

public struct HelperEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var message: String

    public init(date: Date = Date(), message: String) {
        self.id = UUID()
        self.date = date
        self.message = message
    }
}

public struct HelperState: Codable, Hashable, Sendable {
    public var version: String
    public var isRoot: Bool
    public var dryRun: Bool
    public var effectiveProfileID: UUID?
    public var onBattery: Bool
    public var sleeping: Bool
    public var safetyActive: Bool
    public var unlockFlag: Int?
    public var fans: [FanStatus]
    public var events: [HelperEvent]
    public var updated: Date

    public init(version: String, isRoot: Bool, dryRun: Bool, effectiveProfileID: UUID?, onBattery: Bool,
                sleeping: Bool, safetyActive: Bool, unlockFlag: Int?, fans: [FanStatus], events: [HelperEvent],
                updated: Date) {
        self.version = version
        self.isRoot = isRoot
        self.dryRun = dryRun
        self.effectiveProfileID = effectiveProfileID
        self.onBattery = onBattery
        self.sleeping = sleeping
        self.safetyActive = safetyActive
        self.unlockFlag = unlockFlag
        self.fans = fans
        self.events = events
        self.updated = updated
    }
}

public enum FanPilotJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
