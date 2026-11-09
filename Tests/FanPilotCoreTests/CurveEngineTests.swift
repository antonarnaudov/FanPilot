import Foundation
import Testing
@testable import FanPilotCore

private let fan = FanInfo(index: 0, actualRPM: 0, minRPM: 1350, maxRPM: 5777, targetRPM: nil, modeRaw: 3)
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func curveRule(
    start: Double = 60, stop: Double = 55, hysteresis: Double = 0, smoothing: Double = 0,
    rampUp: Double = 100_000, rampDown: Double = 100_000, delay: Double = 0, whenCool: CoolBehavior = .system,
    handBack: Double = 0
) -> FanRule {
    var rule = FanRule(kind: .curve, sensor: .cpuMax, points: [CurvePoint(60, 0), CurvePoint(80, 50), CurvePoint(90, 100)],
                       startTemperature: start, stopTemperature: stop, whenCool: whenCool, hysteresis: hysteresis,
                       smoothing: smoothing, rampUp: rampUp, rampDown: rampDown, spinDownDelay: delay)
    rule.handBackSeconds = handBack
    return rule
}

/// Runs the engine over a temperature sequence, one second apart.
private func run(_ rule: FanRule, _ temperatures: [Double], hottest: Double? = nil,
                 safety: SafetySettings = SafetySettings()) -> [FanDecision] {
    var state = FanControlState()
    return temperatures.enumerated().map { i, t in
        CurveEngine.step(rule: rule, temperature: t, hottest: hottest ?? t, fan: fan, safety: safety,
                         state: &state, now: t0.addingTimeInterval(Double(i)), dt: 1)
    }
}

private func rpm(_ decision: FanDecision) -> Double? {
    if case .manual(let rpm) = decision.command { return rpm }
    return nil
}

@Suite struct CurveInterpolation {
    let points = [CurvePoint(60, 0), CurvePoint(80, 50), CurvePoint(90, 100)]

    @Test func flatOutsideTheCurve() {
        #expect(CurveEngine.percent(points: points, at: 20) == 0)
        #expect(CurveEngine.percent(points: points, at: 105) == 100)
    }

    @Test func linearBetweenPoints() {
        #expect(CurveEngine.percent(points: points, at: 70) == 25)
        #expect(CurveEngine.percent(points: points, at: 85) == 75)
    }

    @Test func unsortedPointsWork() {
        #expect(CurveEngine.percent(points: points.reversed(), at: 70) == 25)
    }
}

@Suite struct Thresholds {
    @Test func belowStartLeavesFansToMacOS() {
        let decisions = run(curveRule(), [40, 59])
        #expect(decisions.allSatisfy { $0.command == .system })
    }

    @Test func takesOverAtStartAndHoldsUntilStop() {
        // 60 starts, 57 is still above stop (55), 55 hands back.
        let decisions = run(curveRule(), [60, 57, 55, 58])
        #expect(rpm(decisions[0]) == 1350)
        #expect(rpm(decisions[1]) == 1350)
        #expect(decisions[2].command == .system)
        // 58 is below start again: stays with macOS.
        #expect(decisions[3].command == .system)
    }

    @Test func coolBehaviorMinimumKeepsFansSpinning() {
        let decisions = run(curveRule(whenCool: .minimum), [40])
        #expect(rpm(decisions[0]) == 1350)
    }

    @Test func followsCurveWhenActive() {
        let decisions = run(curveRule(), [70, 80, 90])
        #expect(rpm(decisions[0])! == fan.rpm(forPercent: 25))
        #expect(rpm(decisions[1])! == fan.rpm(forPercent: 50))
        #expect(rpm(decisions[2])! == 5777)
    }
}

@Suite struct Response {
    @Test func hysteresisDelaysDrops() {
        let rule = curveRule(hysteresis: 4)
        let decisions = run(rule, [80, 78, 77, 75])
        let at80 = fan.rpm(forPercent: 50)
        #expect(rpm(decisions[1]) == at80)  // 2° drop: hold
        #expect(rpm(decisions[2]) == at80)  // 3° drop: hold
        #expect(rpm(decisions[3])! < at80)  // 5° drop: follow
    }

    @Test func rampUpIsRateLimited() {
        let rule = curveRule(rampUp: 800)
        let decisions = run(rule, [90, 90, 90])
        // Starts from the fan's real speed (0, clamped to min 1350).
        #expect(rpm(decisions[0]) == 2150.0)
        #expect(rpm(decisions[1]) == 2950.0)
    }

    @Test func spinDownWaitsForDelay() {
        let rule = curveRule(rampDown: 100_000, delay: 3)
        let decisions = run(rule, [90, 70, 70, 70, 70])
        #expect(rpm(decisions[0]) == 5777)
        #expect(rpm(decisions[1]) == 5777)  // held
        #expect(rpm(decisions[2]) == 5777)  // held
        #expect(rpm(decisions[3])! == fan.rpm(forPercent: 25))
    }

    @Test func smoothingDampsSpikes() {
        let rule = curveRule(smoothing: 5)
        let decisions = run(rule, [70, 90])
        #expect(decisions[1].temperature! < 80)
    }
}

@Suite struct Safety {
    @Test func criticalTemperatureForcesFullSpeed() {
        let rule = FanRule(kind: .fixed, fixedPercent: 10, spinDownDelay: 0)
        let safety = SafetySettings(criticalTemperature: 95, releaseMargin: 8, sustainSeconds: 0)
        var state = FanControlState()
        func step(_ hottest: Double, _ i: Int) -> FanDecision {
            CurveEngine.step(rule: rule, temperature: nil, hottest: hottest, fan: fan, safety: safety,
                             state: &state, now: t0.addingTimeInterval(Double(i)), dt: 1)
        }
        #expect(rpm(step(96, 0)) == 5777)
        #expect(rpm(step(90, 1)) == 5777)   // within the margin: still full
        #expect(rpm(step(86, 2))! < 5777)   // released
    }

    @Test func systemProfileIsNeverTakenOver() {
        let decisions = run(.system, [100], hottest: 100)
        #expect(decisions[0].command == .system)
    }

    @Test func missingSensorHandsBackToMacOS() {
        var state = FanControlState()
        let decision = CurveEngine.step(rule: curveRule(), temperature: nil, hottest: nil, fan: fan,
                                        safety: SafetySettings(), state: &state, now: t0, dt: 1)
        #expect(decision.command == .system)
    }
}

@Suite struct ConfigTests {
    @Test func normalizationKeepsStopBelowStart() {
        let rule = FanRule(kind: .curve, startTemperature: 60, stopTemperature: 70).normalized()
        #expect(rule.stopTemperature < rule.startTemperature)
    }

    @Test func roundTripsThroughJSON() throws {
        var config = FanPilotConfig.default
        config.profiles[1].fanOverrides[1] = FanRule(kind: .fixed, fixedPercent: 80)
        config.batteryProfileID = Presets.systemID
        let data = try FanPilotJSON.encoder.encode(config)
        let decoded = try FanPilotJSON.decoder.decode(FanPilotConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func batteryProfileApplies() {
        var config = FanPilotConfig.default
        config.activeProfileID = Presets.coolID
        config.batteryProfileID = Presets.quietID
        #expect(config.effectiveProfile(onBattery: false).id == Presets.coolID)
        #expect(config.effectiveProfile(onBattery: true).id == Presets.quietID)
    }

    @Test func presetsAreValid() {
        for profile in Presets.all {
            #expect(profile.rule.normalized() == profile.rule, "\(profile.name) changes when normalized")
        }
    }
}

@Suite struct PresetTests {
    @Test func newBuiltInsAppearInOlderConfigs() {
        var old = FanPilotConfig.default
        old.profiles.removeAll { $0.id == Presets.silentCoolID }
        let custom = Profile(name: "Mine", symbol: "fan", rule: .system)
        old.profiles.append(custom)
        let migrated = old.normalized()
        #expect(migrated.profiles.map(\.id) == Presets.all.map(\.id) + [custom.id])
    }

    @Test func silentCoolStaysInTheQuietRangeUntilHot() {
        let points = Presets.silentCool.rule.points
        func rpm(_ celsius: Double) -> Double { fan.rpm(forPercent: CurveEngine.percent(points: points, at: celsius)) }
        #expect(rpm(40) == fan.minRPM)
        #expect(rpm(60) < 2_000)
        #expect(rpm(82) < 2_700)
        #expect(rpm(90) < 3_000)
        #expect(rpm(95) > 3_500)
    }

    @Test func silentCoolKeepsFansSpinningWhenCool() {
        let decisions = run(Presets.silentCool.rule, [35, 38])
        #expect(decisions.allSatisfy { rpm($0) == fan.minRPM })
    }
}

@Suite struct ReviewRegressions {
    @Test func safetySurvivesAProfileChange() {
        let safety = SafetySettings(criticalTemperature: 95, releaseMargin: 8, sustainSeconds: 0)
        var state = FanControlState()
        _ = CurveEngine.step(rule: curveRule(), temperature: 96, hottest: 96, fan: fan, safety: safety,
                             state: &state, now: t0, dt: 1)
        #expect(state.safety)
        // Switch to a quieter rule at 90 °C, still above the 87 °C release point.
        let quiet = FanRule(kind: .fixed, fixedPercent: 10)
        let decision = CurveEngine.step(rule: quiet, temperature: 90, hottest: 90, fan: fan, safety: safety,
                                        state: &state, now: t0.addingTimeInterval(1), dt: 1)
        #expect(rpm(decision) == fan.maxRPM)
    }

    @Test func editingACurveKeepsItRunningAboveTheStopPoint() {
        var state = FanControlState()
        let rule = curveRule()  // start 60, stop 55
        _ = CurveEngine.step(rule: rule, temperature: 65, hottest: 65, fan: fan, safety: SafetySettings(),
                             state: &state, now: t0, dt: 1)
        var edited = rule
        edited.rampDown = 300
        // 58 °C: between stop and start. The edited rule must keep the fans.
        let decision = CurveEngine.step(rule: edited, temperature: 58, hottest: 58, fan: fan, safety: SafetySettings(),
                                        state: &state, now: t0.addingTimeInterval(1), dt: 1)
        #expect(decision.command != .system)
    }

    @Test func systemFansGetTheSafetyOverrideWhileFtstIsHeld() {
        var state = FanControlState()
        let decision = CurveEngine.step(rule: .system, temperature: nil, hottest: 97, fan: fan,
                                        safety: SafetySettings(sustainSeconds: 0), state: &state, now: t0, dt: 1,
                                        unlockHeld: true)
        #expect(rpm(decision) == fan.maxRPM)
    }

    @Test func builtInPointIdsAreTheSameInEveryProcess() {
        #expect(CurvePoint.preset(60, 0).id == CurvePoint.preset(60, 0).id)
        #expect(CurvePoint.preset(60, 0).id != CurvePoint.preset(60, 5).id)
        #expect(Presets.balanced.rule.points.first?.id == CurvePoint.preset(60, 0).id)
    }

    @Test func invalidFanLimitsAreDetected() {
        #expect(fan.isValid)
        #expect(!FanInfo(index: 0, actualRPM: 0, minRPM: 1350, maxRPM: 0, targetRPM: nil, modeRaw: 3).isValid)
        #expect(!FanInfo(index: 0, actualRPM: 0, minRPM: .nan, maxRPM: 5777, targetRPM: nil, modeRaw: 3).isValid)
    }
}

@Suite struct SafetySustain {
    @Test func aShortSpikeDoesNotTriggerFullSpeed() {
        let rule = FanRule(kind: .fixed, fixedPercent: 20, spinDownDelay: 0)
        let safety = SafetySettings(criticalTemperature: 95, releaseMargin: 8, sustainSeconds: 5)
        var state = FanControlState()
        var decisions: [FanDecision] = []
        // 3 s at 98 °C, then back to 80 °C: never full speed.
        for (i, t) in [98.0, 98, 98, 80, 80].enumerated() {
            decisions.append(CurveEngine.step(rule: rule, temperature: nil, hottest: t, fan: fan, safety: safety,
                                              state: &state, now: t0.addingTimeInterval(Double(i)), dt: 1))
        }
        #expect(decisions.allSatisfy { rpm($0)! < fan.maxRPM })
    }

    @Test func sustainedHeatTriggersFullSpeed() {
        let rule = FanRule(kind: .fixed, fixedPercent: 20, spinDownDelay: 0)
        let safety = SafetySettings(criticalTemperature: 95, releaseMargin: 8, sustainSeconds: 5)
        var state = FanControlState()
        var last: FanDecision?
        for i in 0...6 {
            last = CurveEngine.step(rule: rule, temperature: nil, hottest: 97, fan: fan, safety: safety,
                                    state: &state, now: t0.addingTimeInterval(Double(i)), dt: 1)
        }
        #expect(rpm(last!) == fan.maxRPM)
    }

    @Test func configsWithoutSustainStillDecode() throws {
        let json = #"{"criticalTemperature":95,"releaseMargin":8}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SafetySettings.self, from: json)
        #expect(decoded.sustain == 5)
    }
}

@Suite struct HandBack {
    @Test func briefDipsDoNotHandTheFansBack() {
        // 30 s below stop, then hot again: FanPilot keeps the fans throughout.
        let temps = [70.0] + Array(repeating: 50.0, count: 30) + [70.0]
        let decisions = run(curveRule(handBack: 60), temps)
        #expect(decisions.allSatisfy { $0.command != .system })
    }

    @Test func sustainedCoolHandsTheFansBack() {
        let temps = [70.0] + Array(repeating: 50.0, count: 62)
        let decisions = run(curveRule(handBack: 60), temps)
        #expect(decisions.last?.command == .system)
    }

    @Test func olderRulesDecodeWithTheDefaultDelay() throws {
        var rule = FanRule(kind: .curve)
        rule.handBackSeconds = nil
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(FanRule.self, from: data)
        #expect(decoded.handBackDelay == 60)
    }
}
