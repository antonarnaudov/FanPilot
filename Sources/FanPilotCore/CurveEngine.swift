import Foundation

/// What the controller should do with one fan this step.
public enum FanCommand: Equatable, Sendable {
    /// Leave the fan to macOS.
    case system
    /// Hold the fan in manual mode at this speed.
    case manual(rpm: Double)
}

public struct FanDecision: Equatable, Sendable {
    public var command: FanCommand
    /// Human-readable reason, shown in the app.
    public var reason: String
    /// The (smoothed) temperature the rule followed, if any.
    public var temperature: Double?

    public init(command: FanCommand, reason: String, temperature: Double?) {
        self.command = command
        self.reason = reason
        self.temperature = temperature
    }
}

/// Per-fan memory the engine carries from one step to the next.
public struct FanControlState: Sendable {
    public var smoothed: Double?
    /// Temperature the current speed was chosen for (hysteresis).
    public var anchor: Double?
    /// The curve is in its active zone (between start and stop thresholds).
    public var active = false
    /// The speed last commanded (after ramp limiting).
    public var commanded: Double?
    /// No speed decrease before this time.
    public var holdUntil: Date = .distantPast
    public var safety = false
    /// When the temperature first reached critical (for the sustain window).
    public var criticalSince: Date?
    /// When the temperature fell below the stop point (for the hand-back delay).
    public var belowStopSince: Date?
    /// Rule the state was built for; a change resets the state.
    public var rule: FanRule?

    public init() {}
}

public enum CurveEngine {
    /// Fan speed in percent for a temperature, by linear interpolation.
    /// Flat below the first point and above the last.
    public static func percent(points: [CurvePoint], at temperature: Double) -> Double {
        let sorted = points.sorted { $0.temperature < $1.temperature }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if temperature <= first.temperature { return first.percent }
        if temperature >= last.temperature { return last.percent }
        for (a, b) in zip(sorted, sorted.dropFirst()) where temperature <= b.temperature {
            let span = b.temperature - a.temperature
            guard span > 0 else { return b.percent }
            return a.percent + (b.percent - a.percent) * (temperature - a.temperature) / span
        }
        return last.percent
    }

    /// One control step for one fan.
    ///
    /// - Parameters:
    ///   - temperature: the rule's sensor reading, nil when it can't be read.
    ///   - hottest: hottest CPU/GPU reading, for the safety override.
    ///   - fan: the fan's limits and current speed.
    ///   - dt: seconds since the previous step.
    ///   - unlockHeld: FanPilot holds the global `Ftst` flag for another fan, so
    ///     macOS isn't managing this one either: the safety override applies to
    ///     a `.system` rule too.
    public static func step(
        rule: FanRule,
        temperature: Double?,
        hottest: Double?,
        fan: FanInfo,
        safety: SafetySettings,
        state: inout FanControlState,
        now: Date,
        dt: Double,
        unlockHeld: Bool = false
    ) -> FanDecision {
        if state.rule != rule {
            // A new or edited rule starts fresh, but an active safety override,
            // the current speed and the smoothed temperature carry over, and a
            // curve that was running stays on while still above the new stop point.
            var next = FanControlState()
            next.rule = rule
            next.safety = state.safety
            next.criticalSince = state.criticalSince
            next.commanded = state.commanded
            next.smoothed = state.smoothed
            next.active = state.active && (state.smoothed ?? -Double.infinity) > rule.stopTemperature
            state = next
        }

        // Safety override, for every rule that takes fans over.
        if rule.kind != .system || unlockHeld, let hottest {
            if hottest >= safety.criticalTemperature {
                let since = state.criticalSince ?? now
                state.criticalSince = since
                if now.timeIntervalSince(since) >= safety.sustain { state.safety = true }
            } else {
                state.criticalSince = nil
            }
            if state.safety, hottest < safety.criticalTemperature - safety.releaseMargin { state.safety = false }
        } else {
            state.safety = false
            state.criticalSince = nil
        }
        if state.safety {
            let full = max(fan.maxRPM, fan.minRPM)
            state.commanded = full
            state.holdUntil = now.addingTimeInterval(rule.spinDownDelay)
            return FanDecision(
                command: .manual(rpm: full),
                reason: (hottest ?? 0) >= safety.criticalTemperature
                    ? String(format: "Safety: %.0f°C ≥ %.0f°C, full speed", hottest ?? 0, safety.criticalTemperature)
                    : String(format: "Safety: %.0f°C, full speed until below %.0f°C", hottest ?? 0,
                             safety.criticalTemperature - safety.releaseMargin),
                temperature: hottest)
        }

        switch rule.kind {
        case .system:
            state.commanded = nil
            return FanDecision(command: .system, reason: "macOS controls this fan", temperature: nil)

        case .fixed:
            let target = fan.rpm(forPercent: rule.fixedPercent)
            let rpm = ramp(toward: target, rule: rule, fan: fan, state: &state, now: now, dt: dt)
            return FanDecision(
                command: .manual(rpm: rpm),
                reason: String(format: "Fixed at %.0f%%", rule.fixedPercent),
                temperature: nil)

        case .curve:
            guard let temperature else {
                state = FanControlState()
                state.rule = rule
                return FanDecision(command: .system, reason: "Sensor unavailable, macOS controls the fan", temperature: nil)
            }
            // Exponential smoothing with time constant `rule.smoothing`.
            let smoothed: Double
            if let previous = state.smoothed, rule.smoothing > 0 {
                let alpha = 1 - exp(-max(dt, 0) / rule.smoothing)
                smoothed = previous + (temperature - previous) * alpha
            } else {
                smoothed = temperature
            }
            state.smoothed = smoothed

            // Start / stop thresholds decide when FanPilot takes the fans.
            if !state.active, smoothed >= rule.startTemperature { state.active = true }
            if state.active, smoothed <= rule.stopTemperature {
                let since = state.belowStopSince ?? now
                state.belowStopSince = since
                if now.timeIntervalSince(since) >= rule.handBackDelay {
                    state.active = false
                    state.anchor = nil
                    state.holdUntil = .distantPast
                    state.belowStopSince = nil
                }
            } else {
                state.belowStopSince = nil
            }
            guard state.active else {
                switch rule.whenCool {
                case .system:
                    state.commanded = nil
                    return FanDecision(
                        command: .system,
                        reason: String(format: "%.1f°C, below start %.0f°C: macOS controls the fan",
                                       smoothed, rule.startTemperature),
                        temperature: smoothed)
                case .minimum:
                    let rpm = ramp(toward: fan.minRPM, rule: rule, fan: fan, state: &state, now: now, dt: dt)
                    return FanDecision(
                        command: .manual(rpm: rpm),
                        reason: String(format: "%.1f°C, below start %.0f°C: minimum speed", smoothed, rule.startTemperature),
                        temperature: smoothed)
                }
            }

            // Hysteresis: follow rises at once, follow falls only once they exceed the band.
            if let anchor = state.anchor {
                if smoothed > anchor || smoothed <= anchor - rule.hysteresis { state.anchor = smoothed }
            } else {
                state.anchor = smoothed
            }
            let percent = Self.percent(points: rule.points, at: state.anchor ?? smoothed)
            let target = fan.rpm(forPercent: percent)
            let rpm = ramp(toward: target, rule: rule, fan: fan, state: &state, now: now, dt: dt)
            return FanDecision(
                command: .manual(rpm: rpm),
                reason: String(format: "%.1f°C → %.0f%% of range", smoothed, percent),
                temperature: smoothed)
        }
    }

    /// Moves the commanded speed toward `target`, no faster than the rule's
    /// ramp rates, and holds it for `spinDownDelay` before any decrease.
    static func ramp(toward target: Double, rule: FanRule, fan: FanInfo, state: inout FanControlState,
                     now: Date, dt: Double) -> Double {
        let low = fan.minRPM
        let high = max(fan.maxRPM, fan.minRPM)
        let target = min(max(target, low), high)
        // Start from the fan's real speed when taking it over (it may be idle at 0).
        let current = state.commanded ?? min(max(fan.actualRPM, low), high)
        var next = current
        if target > current {
            next = min(target, current + rule.rampUp * max(dt, 0))
            state.holdUntil = now.addingTimeInterval(rule.spinDownDelay)
        } else if target < current {
            if now >= state.holdUntil {
                next = max(target, current - rule.rampDown * max(dt, 0))
            }
        } else {
            state.holdUntil = max(state.holdUntil, now)
        }
        state.commanded = next
        return next
    }
}
