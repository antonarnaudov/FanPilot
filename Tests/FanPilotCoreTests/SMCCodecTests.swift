import Testing
@testable import FanPilotCore
@testable import SMCKit

@Suite struct SMCCodecTests {
    @Test func floatIsLittleEndian() throws {
        // 1350.0 as read from F0Mn on an M4 Pro.
        let bytes: [UInt8] = [0x00, 0xC0, 0xA8, 0x44]
        #expect(SMCCodec.decode(type: "flt ", bytes: bytes) == 1350)
        #expect(try SMCCodec.encode(1350, type: "flt ", size: 4) == bytes)
    }

    @Test func intelFixedPoint() throws {
        #expect(SMCCodec.decode(type: "fpe2", bytes: [0x15, 0x18]) == 1350)
        #expect(try SMCCodec.encode(1350, type: "fpe2", size: 2) == [0x15, 0x18])
        #expect(SMCCodec.decode(type: "sp78", bytes: [0x2D, 0x80]) == 45.5)
    }

    @Test func singleByte() throws {
        #expect(try SMCCodec.encode(1, type: "ui8 ", size: 1) == [1])
        #expect(SMCCodec.decode(type: "ui8 ", bytes: [3]) == 3)
    }

    @Test func sizeIsChecked() {
        #expect(throws: SMCError.self) { try SMCCodec.encode(1, type: "ui8 ", size: 4) }
    }

    @Test func fourCCRoundTrip() {
        #expect(FourCC("F0Ac").string == "F0Ac")
        #expect(FourCC("flt").string == "flt ")
    }

    @Test func sensorGroups() {
        #if arch(arm64)
        #expect(SensorCatalog.group(for: "Tp1o") == .cpu)
        #expect(SensorCatalog.group(for: "Te05") == .cpu)
        #expect(SensorCatalog.group(for: "Tg0K") == .gpu)
        #expect(SensorCatalog.group(for: "TB0T") == .battery)
        #expect(SensorCatalog.group(for: "TH0x") == .storage)
        #expect(SensorCatalog.group(for: "TaLP") == .other)
        #endif
    }
}

@Suite struct CodecGuards {
    @Test func nonFiniteValuesAreNeverEncoded() {
        #expect(throws: SMCError.invalidValue) { try SMCCodec.encode(.nan, type: "flt ", size: 4) }
        #expect(throws: SMCError.invalidValue) { try SMCCodec.encode(.infinity, type: "fpe2", size: 2) }
    }
}
