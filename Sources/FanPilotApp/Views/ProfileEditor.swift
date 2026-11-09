import FanPilotCore
import SwiftUI

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    let profileID: UUID
    /// nil edits the rule all fans share; a number edits that fan's override.
    @State private var editingFan: Int?
    @State private var selectedPoint: UUID?
    @State private var showingAppearance = false
    @State private var renaming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let profile = model.config.profile(id: profileID) {
            editor(profile)
                .navigationTitle(profile.name)
        } else {
            ContentUnavailableView("Profile Not Found", systemImage: "questionmark.folder")
        }
    }

    // MARK: Bindings

    private var profile: Binding<Profile> {
        Binding(
            get: { model.config.profile(id: profileID) ?? Presets.system },
            set: { model.update($0) })
    }

    private var rule: Binding<FanRule> {
        Binding(
            get: {
                let p = profile.wrappedValue
                return editingFan.map { p.rule(forFan: $0) } ?? p.rule
            },
            set: { newValue in
                var p = profile.wrappedValue
                if let fan = editingFan, p.fanOverrides[fan] != nil {
                    p.fanOverrides[fan] = newValue
                } else {
                    p.rule = newValue
                }
                profile.wrappedValue = p
            })
    }

    private var hasOverride: Binding<Bool> {
        Binding(
            get: { editingFan.map { profile.wrappedValue.fanOverrides[$0] != nil } ?? false },
            set: { on in
                guard let fan = editingFan else { return }
                var p = profile.wrappedValue
                p.fanOverrides[fan] = on ? p.rule : nil
                profile.wrappedValue = p
            })
    }

    private var ruleEditable: Bool { editingFan == nil || hasOverride.wrappedValue }

    // MARK: Layout

    private func editor(_ current: Profile) -> some View {
        GlassPage {
            header(current)

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeader("Control", symbol: "dial.medium")
                    Picker("Control", selection: rule.kind) {
                        ForEach(FanRuleKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .disabled(!ruleEditable)
                    Text(modeHelp(rule.wrappedValue.kind))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.fans.count > 1 {
                        Divider().padding(.vertical, 2)
                        HStack {
                            Text("Settings for")
                            Spacer()
                            Picker("Settings for", selection: $editingFan) {
                                Text("All Fans").tag(Int?.none)
                                ForEach(model.fans) { fan in
                                    Text(fan.name).tag(Int?.some(fan.index))
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        if let fan = editingFan {
                            Toggle("Separate settings for \(model.fans.first { $0.index == fan }?.name ?? "this fan")",
                                   isOn: hasOverride)
                                .toggleStyle(.switch)
                        }
                    }
                }
            }

            Group {
                switch rule.wrappedValue.kind {
                case .system:
                    EmptyView()
                case .fixed:
                    fixedCard
                case .curve:
                    curveCards
                }
            }
            .disabled(!ruleEditable)
        }
        .onChange(of: profileID) {
            editingFan = nil
            selectedPoint = nil
            renaming = false
        }
    }

    private func header(_ current: Profile) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Button {
                showingAppearance = true
            } label: {
                ProfileIcon(profile: current, size: 68)
            }
            .buttonStyle(.plain)
            .help("Change icon and colour")
            .popover(isPresented: $showingAppearance, arrowEdge: .bottom) {
                ProfileAppearancePicker(profile: profile)
            }
            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("Name", text: profile.name)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.system(size: 32, weight: .bold))
                        .focused($nameFocused)
                        .onSubmit { renaming = false }
                        .onChange(of: nameFocused) { _, focused in if !focused { renaming = false } }
                        .onAppear { nameFocused = true }
                } else {
                    Text(current.name)
                        .font(.system(size: 32, weight: .bold))
                        .onTapGesture(count: 2) { renaming = true }
                        .help("Double-click to rename")
                }
                Text(current.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if current.id == model.config.activeProfileID {
                StatusCapsule(text: "In Use", symbol: "checkmark.circle.fill", tint: current.tint)
            } else {
                Button("Use Profile") { withAnimation(.smooth) { model.activate(current) } }
                    .buttonStyle(.glassProminent)
                    .tint(current.tint)
                    .controlSize(.large)
            }
            Menu {
                Button("Rename") { renaming = true }
                Button("Duplicate") { _ = model.addProfile(copying: current) }
                if model.isBuiltIn(current) {
                    Button("Reset to Default") { model.resetBuiltIn(current) }
                } else {
                    Divider()
                    Button("Delete Profile", role: .destructive) { model.delete(current) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .fixedSize()
        }
        .padding(.horizontal, 4)
    }

    private func modeHelp(_ kind: FanRuleKind) -> String {
        switch kind {
        case .system: return "macOS controls the fans. FanPilot only watches."
        case .fixed: return "The fans run at one speed whatever the temperature. The safety limit still applies."
        case .curve: return "Fan speed follows a temperature. You choose when the fans come on, how fast they react, and when macOS gets them back."
        }
    }

    // MARK: Fixed

    private var fixedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader("Speed", symbol: "wind")
                SliderRow(title: "Fan speed", value: rule.fixedPercent, range: 0...100, step: 1,
                          format: { "\(Int($0))%" }, minimumSymbol: "tortoise", maximumSymbol: "hare")
                HStack(spacing: 24) {
                    ForEach(model.fans) { fan in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fan.name).font(.caption).foregroundStyle(.secondary)
                            Text(rpmText(fan.rpm(forPercent: rule.wrappedValue.fixedPercent)))
                                .font(.system(.title2, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: Curve

    @ViewBuilder
    private var curveCards: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Curve", symbol: "point.topleft.down.to.point.bottomright.curvepath") {
                    Picker("Follows", selection: rule.sensor) {
                        ForEach(SensorSelector.summaries, id: \.self) { selector in
                            Text(selectorLabel(selector)).tag(selector)
                        }
                        if let key = rule.wrappedValue.sensor.smcKey {
                            Text("Sensor \(key)").tag(SensorSelector.key(key))
                        }
                        Divider()
                        ForEach(model.readings.filter { $0.key != rule.wrappedValue.sensor.smcKey }
                            .sorted { $0.value > $1.value }.prefix(30)) { reading in
                            Text(String(format: "%@  %.0f°", reading.name, reading.value)).tag(SensorSelector.key(reading.key))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                CurveChart(
                    rule: rule,
                    selectedPoint: $selectedPoint,
                    liveTemperature: liveTemperature,
                    livePercent: livePercent,
                    criticalTemperature: model.config.safety.criticalTemperature)
                    .frame(height: 280)
                Text("Drag a point to move it, double-click the chart to add one. 0% is the fan's minimum speed, 100% its maximum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                CurvePointsList(rule: rule, selectedPoint: $selectedPoint, fans: model.fans)
            }
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], spacing: 16) {
            GlassCard {
                VStack(alignment: .leading, spacing: 18) {
                    CardHeader("When the Fans Come On", symbol: "thermometer.medium")
                    SliderRow(title: "Take over at", value: rule.startTemperature, range: 30...100, step: 1,
                              format: { "\(Int($0))°C" },
                              help: "FanPilot takes the fans from macOS once the temperature reaches this.",
                              minimumSymbol: "thermometer.low", maximumSymbol: "thermometer.high")
                    SliderRow(title: "Give back below", value: rule.stopTemperature, range: 25...99, step: 1,
                              format: { "\(Int($0))°C" },
                              help: "Keep a gap to the take-over point so the fans don't switch on and off.",
                              minimumSymbol: "thermometer.low", maximumSymbol: "thermometer.high")
                    SliderRow(title: "Give back after", value: handBack, range: 0...300, step: 5,
                              format: { $0 < 60 ? "\(Int($0)) s" : String(format: "%.1f min", $0 / 60) },
                              help: "How long it must stay below the give-back point before macOS gets the fans, so brief dips don't flip control back and forth.")
                    HStack {
                        Text("While cooler").font(.body.weight(.medium))
                        Spacer()
                        Picker("While cooler", selection: rule.whenCool) {
                            ForEach(CoolBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 18) {
                    CardHeader("Response", symbol: "waveform.path.ecg")
                    SliderRow(title: "Hysteresis", value: rule.hysteresis, range: 0...15, step: 0.5,
                              format: { String(format: "%.1f°C", $0) },
                              help: "Speed rises at once but drops only after the temperature falls this much.")
                    SliderRow(title: "Smoothing", value: rule.smoothing, range: 0...30, step: 1,
                              format: { "\(Int($0)) s" },
                              help: "Averages out short spikes so the fans don't chase every burst.")
                    SliderRow(title: "Spin-up rate", value: rule.rampUp, range: 100...5000, step: 50,
                              format: { "\(Int($0))/s" }, help: "Fastest increase, in rpm per second.",
                              minimumSymbol: "tortoise", maximumSymbol: "hare")
                    SliderRow(title: "Spin-down rate", value: rule.rampDown, range: 20...2000, step: 10,
                              format: { "\(Int($0))/s" }, help: "Fastest decrease, in rpm per second. Slower is quieter.",
                              minimumSymbol: "tortoise", maximumSymbol: "hare")
                    SliderRow(title: "Hold before slowing", value: rule.spinDownDelay, range: 0...120, step: 1,
                              format: { "\(Int($0)) s" }, help: "After speeding up, keep that speed at least this long.")
                }
            }
        }
    }

    private var handBack: Binding<Double> {
        Binding(get: { rule.wrappedValue.handBackDelay },
                set: { value in var r = rule.wrappedValue; r.handBackSeconds = value; rule.wrappedValue = r })
    }

    private func selectorLabel(_ selector: SensorSelector) -> String {
        guard let value = model.value(selector) else { return selector.title }
        return "\(selector.title)  \(Int(value.rounded()))°"
    }

    /// The temperature the helper is following for this fan, or the live sensor.
    private var liveTemperature: Double? {
        let fan = editingFan ?? 0
        if profileID == model.effectiveProfile.id, let temperature = model.status(forFan: fan)?.temperature {
            return temperature
        }
        return model.value(rule.wrappedValue.sensor)
    }

    private var livePercent: Double? {
        guard profileID == model.effectiveProfile.id else { return nil }
        let index = editingFan ?? 0
        guard let status = model.status(forFan: index), status.controlled, let rpm = status.commandedRPM,
              let fan = model.fans.first(where: { $0.index == index })
        else { return nil }
        return min(max((rpm - fan.minRPM) / fan.range * 100, 0), 100)
    }
}

/// Icon and colour for a profile.
struct ProfileAppearancePicker: View {
    @Binding var profile: Profile

    private static let symbols = [
        "snowflake", "wind", "fan.fill", "dial.low", "dial.medium", "dial.high", "moon.fill", "leaf.fill",
        "tortoise.fill", "hare.fill", "bolt.fill", "flame.fill", "hammer.fill", "gamecontroller.fill",
        "film.fill", "music.note", "cpu", "laptopcomputer", "headphones", "apple.logo",
    ]

    var body: some View {
        VStack(spacing: 16) {
            ProfileIcon(profile: profile, size: 64)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Palette.names, id: \.self) { name in
                        Button {
                            withAnimation(.smooth) { profile.color = name }
                        } label: {
                            Circle()
                                .fill(Palette.color(name).gradient)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if (profile.color ?? "blue") == name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 7), spacing: 8) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        withAnimation(.smooth) { profile.symbol = symbol }
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(profile.symbol == symbol ? Color.white : Color.primary)
                            .frame(width: 36, height: 36)
                            .glassEffect(profile.symbol == symbol ? Glass.regular.tint(profile.tint).interactive()
                                                                  : .regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                }
            }
        }
        .padding(18)
    }
}

/// Exact values for every point. Select a row, then − removes it; + adds one.
struct CurvePointsList: View {
    @Binding var rule: FanRule
    @Binding var selectedPoint: UUID?
    let fans: [FanInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rule.points.enumerated()), id: \.element.id) { index, value in
                let point = pointBinding(value)
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(value.id == selectedPoint ? .white : .secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(value.id == selectedPoint ? AnyShapeStyle(Color.accentColor)
                                                                            : AnyShapeStyle(.primary.opacity(0.08))))
                    TextField("Temperature", value: point.temperature, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("°C").foregroundStyle(.secondary)
                    Stepper("Temperature", value: point.temperature, in: 20...110, step: 1)
                        .labelsHidden()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                    TextField("Speed", value: point.percent, format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                    Text("%").foregroundStyle(.secondary)
                    Stepper("Speed", value: point.percent, in: 0...100, step: 5)
                        .labelsHidden()
                    Spacer()
                    if let fan = fans.first {
                        Text(rpmText(fan.rpm(forPercent: value.percent)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(value.id == selectedPoint ? 0.14 : 0))
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedPoint = value.id }
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { addPoint() } label: {
                        Image(systemName: "plus").frame(width: 16, height: 16)
                    }
                    .help("Add a point")
                    Button {
                        if let id = selectedPoint { rule.points.removeAll { $0.id == id } }
                        selectedPoint = nil
                    } label: {
                        Image(systemName: "minus").frame(width: 16, height: 16)
                    }
                    .disabled(selectedPoint == nil || rule.points.count <= 2)
                    .help("Remove the selected point")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            .padding(.top, 4)
        }
    }

    /// A binding to one point found by id, so removing a point can't leave a
    /// row writing through a stale index.
    private func pointBinding(_ point: CurvePoint) -> Binding<CurvePoint> {
        Binding(
            get: { rule.points.first { $0.id == point.id } ?? point },
            set: { newValue in
                if let index = rule.points.firstIndex(where: { $0.id == point.id }) { rule.points[index] = newValue }
            })
    }

    private func addPoint() {
        let sorted = rule.points.sorted { $0.temperature < $1.temperature }
        // Put the new point in the widest gap.
        var best = (temperature: (sorted.last?.temperature ?? 80) + 5, percent: 100.0)
        var widest = 0.0
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.temperature - a.temperature > widest {
            widest = b.temperature - a.temperature
            best = ((a.temperature + b.temperature) / 2, (a.percent + b.percent) / 2)
        }
        let point = CurvePoint(min(best.temperature, 110).rounded(), best.percent.rounded())
        rule.points.append(point)
        selectedPoint = point.id
    }
}
