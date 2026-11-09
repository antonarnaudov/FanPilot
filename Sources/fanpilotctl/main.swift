import FanPilotCore
import Foundation
import SMCKit

// fanpilotctl — inspect fans and sensors, test fan control, recover.

let usage = """
    usage: fanpilotctl <command>

      status                 fans and the main temperatures (default)
      sensors [--all]        live temperature sensors (--all: every T* key, including placeholders)
      keys [prefix]          raw SMC keys, e.g. `keys F`
      helper [--dev]         state of the running FanPilot helper
      profile <name> [--dev] switch the helper to a profile (e.g. "Cool")

    needs root (sudo):
      test [rpm] [seconds]   take the fans, hold them at rpm (default: middle of the range),
                             print the speed every second, then give them back to macOS
      auto                   give every fan back to macOS and clear Ftst (recovery)

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fanpilotctl: \(message)\n".utf8))
    exit(1)
}

func requireRoot() {
    if getuid() != 0 { fail("this command writes to the SMC and needs root: sudo fanpilotctl \(CommandLine.arguments.dropFirst().joined(separator: " "))") }
}

func openSMC() -> SMC {
    do { return try SMC() } catch { fail("\(error)") }
}

func modeName(_ raw: Int?) -> String {
    switch raw {
    case 0: return "auto"
    case 1: return "manual"
    case 3: return "macOS"
    case let value?: return "mode \(value)"
    case nil: return "?"
    }
}

func printStatus(_ smc: SMC) {
    let reader = FanReader(smc: smc)
    let sensors = SensorReader(smc: smc)
    let readings = sensors.read()
    print("Fans (\(reader.count))" + (reader.testFlag().map { "   Ftst=\($0)" } ?? ""))
    for fan in reader.fans() {
        print(String(format: "  %@  %5.0f RPM   range %.0f–%.0f   target %@   %@",
                     fan.name, fan.actualRPM, fan.minRPM, fan.maxRPM,
                     fan.targetRPM.map { String(format: "%.0f", $0) } ?? "–", modeName(fan.modeRaw)))
    }
    print("Temperatures")
    for selector in SensorSelector.summaries {
        if let value = selector.value(in: readings) {
            print("  " + selector.title.padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: " %5.1f °C", value))
        }
    }
}

func printSensors(_ smc: SMC, all: Bool) {
    if all {
        for key in smc.allKeys() where key.string.hasPrefix("T") {
            guard let value = try? smc.read(key) else { continue }
            print(String(format: "  %@  %@  %@", key.string, value.info.type.string,
                         value.number.map { String(format: "%.2f", $0) } ?? value.hex))
        }
        return
    }
    let readings = SensorReader(smc: smc).read()
    for group in SensorGroup.allCases {
        let items = readings.filter { $0.group == group }
        guard !items.isEmpty else { continue }
        print("\(group.title) (\(items.count))")
        for item in items.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %@  %5.1f °C  %@", item.key, item.value, item.name))
        }
    }
}

func printKeys(_ smc: SMC, prefix: String) {
    for key in smc.allKeys() where key.string.hasPrefix(prefix) {
        guard let info = try? smc.info(key) else { continue }
        let value = try? smc.read(key)
        print(String(format: "%@  %@  %2d  attr=%02x  %@", key.string, info.type.string, info.size, info.attributes,
                     value.map { $0.number.map { String(format: "%.2f", $0) } ?? $0.hex } ?? "<unreadable>"))
    }
}

func runTest(_ smc: SMC, rpm: Double?, seconds: Int) {
    requireRoot()
    let reader = FanReader(smc: smc)
    let controller = FanController(smc: smc, reader: reader) { print("  · \($0)") }
    let fans = reader.fans()
    guard !fans.isEmpty else { fail("this Mac has no fans") }

    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            print("\ninterrupted: giving the fans back to macOS")
            controller.releaseAll()
            exit(130)
        }
        source.resume()
        signalSources.append(source)
    }

    print("Taking the fans over (on M3/M4 this can take a few seconds)…")
    let started = Date()
    for fan in fans {
        do {
            try controller.engage(fan.index)
            let target = rpm ?? (fan.minRPM + fan.maxRPM) / 2
            try controller.setTarget(fan.index, rpm: target)
            print(String(format: "  %@ → %.0f RPM", fan.name, target))
        } catch {
            print("  \(fan.name): \(error)")
            controller.releaseAll()
            fail("fan control is not working on this Mac yet")
        }
    }
    print(String(format: "Engaged in %.1fs. Holding for %d s:", Date().timeIntervalSince(started), seconds))
    for second in 1...max(seconds, 1) {
        Thread.sleep(forTimeInterval: 1)
        let line = reader.fans().map {
            String(format: "%@ %5.0f RPM (%@)", $0.name, $0.actualRPM, modeName($0.modeRaw))
        }.joined(separator: "   ")
        print(String(format: "  %2ds  %@", second, line))
    }
    print("Giving the fans back to macOS…")
    controller.releaseAll()
    Thread.sleep(forTimeInterval: 1)
    print(reader.fans().map { "  \($0.name): \(modeName($0.modeRaw))" }.joined(separator: "\n")
          + (reader.testFlag().map { "\n  Ftst=\($0)" } ?? ""))
    withExtendedLifetime(signalSources) {}
}

func runHelper(dev: Bool) async {
    let connection = HelperConnection(privileged: !dev)
    do {
        let state = try await connection.state()
        let config = try await connection.config()
        let profile = config.profile(id: state.effectiveProfileID)
        print("Helper \(state.version)\(state.isRoot ? "" : " (not root)")\(state.dryRun ? " (dry run)" : "")")
        print("  profile: \(profile?.name ?? "–")\(state.onBattery ? " (on battery)" : "")"
              + (state.safetyActive ? "   SAFETY ACTIVE" : "") + (state.sleeping ? "   sleeping" : "")
              + (state.unlockFlag.map { "   Ftst=\($0)" } ?? ""))
        for fan in state.fans {
            print("  Fan \(fan.index + 1): \(fan.controlled ? "FanPilot" : "macOS")"
                  + (fan.commandedRPM.map { String(format: " → %.0f RPM", $0) } ?? "")
                  + "  · \(fan.reason)" + (fan.error.map { "  ! \($0)" } ?? ""))
        }
        print("Recent events")
        for event in state.events.suffix(12) {
            print("  \(event.date.formatted(date: .omitted, time: .standard))  \(event.message)")
        }
    } catch {
        fail("\(error)")
    }
}

func runProfile(_ name: String, dev: Bool) async {
    let connection = HelperConnection(privileged: !dev)
    do {
        var config = try await connection.config()
        guard let profile = config.profiles.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            fail("no profile named \(name); profiles: \(config.profiles.map(\.name).joined(separator: ", "))")
        }
        config.activeProfileID = profile.id
        try await connection.setConfig(config)
        print("profile: \(profile.name)")
    } catch {
        fail("\(error)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let dev = args.contains("--dev")
let positional = args.filter { !$0.hasPrefix("--") }

switch positional.first ?? "status" {
case "status":
    printStatus(openSMC())
case "sensors":
    printSensors(openSMC(), all: args.contains("--all"))
case "keys":
    printKeys(openSMC(), prefix: positional.dropFirst().first ?? "")
case "test":
    let rpm = positional.dropFirst().first.flatMap(Double.init)
    let seconds = positional.dropFirst(2).first.flatMap(Int.init) ?? 12
    runTest(openSMC(), rpm: rpm, seconds: seconds)
case "auto":
    requireRoot()
    let smc = openSMC()
    let reader = FanReader(smc: smc)
    FanController(smc: smc, reader: reader) { print("  · \($0)") }.releaseAll()
    print(reader.fans().map { "\($0.name): \(modeName($0.modeRaw))" }.joined(separator: "\n")
          + (reader.testFlag().map { "\nFtst=\($0)" } ?? ""))
case "helper":
    await runHelper(dev: dev)
case "profile":
    guard let name = positional.dropFirst().first else { fail("usage: fanpilotctl profile <name>") }
    await runProfile(name, dev: dev)
case "help", "-h":
    print(usage)
default:
    print(usage)
    exit(2)
}
