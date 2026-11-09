import Foundation

/// A four-character SMC code such as `F0Ac` or `flt `.
public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public init(_ string: String) {
        var value: UInt32 = 0
        let bytes = Array(string.utf8.prefix(4))
        for byte in bytes { value = (value << 8) | UInt32(byte) }
        // Pad short codes with spaces, the way the SMC does ("flt ", "ui8 ").
        for _ in bytes.count..<4 { value = (value << 8) | 0x20 }
        self.raw = value
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var string: String {
        let bytes = [UInt8(raw >> 24 & 0xff), UInt8(raw >> 16 & 0xff), UInt8(raw >> 8 & 0xff), UInt8(raw & 0xff)]
        return String(decoding: bytes.map { (32...126).contains($0) ? $0 : 63 }, as: UTF8.self)
    }

    public var description: String { string }
}
