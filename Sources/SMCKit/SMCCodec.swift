import Foundation

/// Encodes and decodes SMC values by their data type.
///
/// Apple Silicon uses little-endian `flt ` (IEEE-754 float) for fan speeds and
/// temperatures. Intel Macs use big-endian fixed-point types (`fpe2`, `sp78`).
public enum SMCCodec {
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be16() -> UInt16? { bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil }
        func be32() -> UInt32? {
            bytes.count >= 4 ? bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } : nil
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag":
            return bytes.first.map(Double.init)
        case "hex_":
            return bytes.count == 1 ? Double(bytes[0]) : nil
        case "ui16":
            return be16().map(Double.init)
        case "ui32":
            return be32().map(Double.init)
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16":
            return be16().map { Double(Int16(bitPattern: $0)) }
        case "si32":
            return be32().map { Double(Int32(bitPattern: $0)) }
        case "fpe2":
            return be16().map { Double($0) / 4 }
        case "sp78":
            return be16().map { Double(Int16(bitPattern: $0)) / 256 }
        case "sp87":
            return be16().map { Double(Int16(bitPattern: $0)) / 128 }
        case "fp88":
            return be16().map { Double($0) / 256 }
        case "ioft":
            // 48.16 fixed point, little-endian, 8 bytes.
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for (i, b) in bytes.prefix(8).enumerated() { raw |= UInt64(b) << (8 * UInt64(i)) }
            return Double(raw) / 65536
        default:
            return nil
        }
    }

    public static func encode(_ value: Double, type: String, size: Int) throws -> [UInt8] {
        guard value.isFinite else { throw SMCError.invalidValue }
        let bytes: [UInt8]
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
        case "ui8 ", "flag", "hex_":
            bytes = [UInt8(clamping: Int(value.rounded()))]
        case "ui16":
            let v = UInt16(clamping: Int(value.rounded()))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        case "ui32":
            let v = UInt32(clamping: Int(value.rounded()))
            bytes = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
        case "fpe2":
            let v = UInt16(clamping: Int((value * 4).rounded()))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            throw SMCError.unsupportedType(type)
        }
        guard bytes.count == size else { throw SMCError.sizeMismatch(expected: size, got: bytes.count) }
        return bytes
    }
}
