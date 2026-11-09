import CSMC
import Foundation
import IOKit

public struct SMCKeyInfo: Sendable, Hashable {
    public let size: Int
    public let type: FourCC
    public let attributes: UInt8
}

public struct SMCValue: Sendable {
    public let key: FourCC
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    public var number: Double? { SMCCodec.decode(type: info.type.string, bytes: bytes) }
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

public enum SMCError: Error, CustomStringConvertible, Equatable {
    case serviceNotFound
    case openFailed(kern_return_t)
    case ioKit(kern_return_t)
    case notPrivileged
    /// The SMC firmware answered with a non-zero result byte.
    case firmware(UInt8)
    case keyNotFound(String)
    case unsupportedType(String)
    case sizeMismatch(expected: Int, got: Int)
    case invalidValue

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return String(format: "could not open AppleSMC (0x%08x)", kr)
        case .ioKit(let kr): return String(format: "IOKit error 0x%08x", kr)
        case .notPrivileged: return "not privileged (writing to the SMC needs root)"
        case .firmware(let code): return String(format: "SMC refused (0x%02x %@)", code, SMCError.name(of: code))
        case .keyNotFound(let key): return "SMC key \(key) not found"
        case .unsupportedType(let type): return "unsupported SMC type '\(type)'"
        case .sizeMismatch(let expected, let got): return "size mismatch: key takes \(expected) bytes, got \(got)"
        case .invalidValue: return "refusing to write a value that isn't a finite number"
        }
    }

    public static func name(of code: UInt8) -> String {
        switch code {
        case 0x80: return "comm collision"
        case 0x81: return "spurious data"
        case 0x82: return "bad command"
        case 0x83: return "bad parameter"
        case 0x84: return "key not found"
        case 0x85: return "not readable"
        case 0x86: return "not writable"
        case 0x87: return "size mismatch"
        case 0x88: return "framing error"
        case 0x89: return "bad argument"
        default: return "unknown"
        }
    }

    /// The firmware said "bad command": on M3/M4 that means the thermal manager
    /// still owns the fans.
    public var isBadCommand: Bool { self == .firmware(0x82) }
}

/// A connection to the AppleSMC user client.
///
/// Reading works for any user. Writing needs root. All calls are serialized.
public final class SMC: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]
    private let lock = NSLock()

    // IOKit return codes Swift does not import (macros built from iokit_common_err).
    static let kIOReturnNotPrivileged: kern_return_t = kern_return_t(bitPattern: 0xE000_02C1)
    static let kIOReturnNotPermitted: kern_return_t = kern_return_t(bitPattern: 0xE000_02E2)

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit { IOServiceClose(connection) }

    private func call(_ input: inout FPSMCParam) throws -> FPSMCParam {
        var output = FPSMCParam()
        var outputSize = MemoryLayout<FPSMCParam>.stride
        let kr = IOConnectCallStructMethod(
            connection, UInt32(FPSMCSelectorHandleYPCEvent),
            &input, MemoryLayout<FPSMCParam>.stride,
            &output, &outputSize)
        switch kr {
        case kIOReturnSuccess: break
        case SMC.kIOReturnNotPrivileged, SMC.kIOReturnNotPermitted: throw SMCError.notPrivileged
        default: throw SMCError.ioKit(kr)
        }
        if output.result == 0x84 { throw SMCError.keyNotFound(FourCC(raw: input.key).string) }
        if output.result != 0 { throw SMCError.firmware(output.result) }
        return output
    }

    private func infoLocked(_ key: FourCC) throws -> SMCKeyInfo {
        if let cached = infoCache[key.raw] { return cached }
        var input = FPSMCParam()
        input.key = key.raw
        input.data8 = UInt8(FPSMCCmdReadKeyInfo)
        let output = try call(&input)
        let info = SMCKeyInfo(
            size: Int(output.keyInfo.dataSize),
            type: FourCC(raw: output.keyInfo.dataType),
            attributes: output.keyInfo.dataAttributes)
        infoCache[key.raw] = info
        return info
    }

    public func info(_ key: FourCC) throws -> SMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        return try infoLocked(key)
    }

    public func has(_ key: FourCC) -> Bool { (try? info(key)) != nil }

    public func read(_ key: FourCC) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        let info = try infoLocked(key)
        var input = FPSMCParam()
        input.key = key.raw
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = UInt8(FPSMCCmdReadBytes)
        let output = try call(&input)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(min(info.size, 32))) }
        return SMCValue(key: key, info: info, bytes: bytes)
    }

    /// Reads a key and decodes it as a number.
    public func number(_ key: FourCC) throws -> Double {
        let value = try read(key)
        guard let number = value.number else { throw SMCError.unsupportedType(value.info.type.string) }
        return number
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let info = try infoLocked(key)
        guard bytes.count == info.size, bytes.count <= 32 else {
            throw SMCError.sizeMismatch(expected: info.size, got: bytes.count)
        }
        var input = FPSMCParam()
        input.key = key.raw
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = UInt8(FPSMCCmdWriteBytes)
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        _ = try call(&input)
    }

    /// Encodes `value` with the key's own data type and writes it.
    public func write(_ key: FourCC, number value: Double) throws {
        let info = try info(key)
        try write(key, bytes: SMCCodec.encode(value, type: info.type.string, size: info.size))
    }

    public func keyCount() throws -> Int {
        Int(try number("#KEY"))
    }

    public func key(at index: Int) throws -> FourCC {
        lock.lock(); defer { lock.unlock() }
        var input = FPSMCParam()
        input.data8 = UInt8(FPSMCCmdReadIndex)
        input.data32 = UInt32(index)
        return FourCC(raw: try call(&input).key)
    }

    /// Every key the SMC knows about, in firmware order.
    public func allKeys() -> [FourCC] {
        guard let count = try? keyCount() else { return [] }
        return (0..<count).compactMap { try? key(at: $0) }
    }
}
