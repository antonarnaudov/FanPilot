import Charts
import FanPilotCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case profile(UUID)
    case sensors
    case helper
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?

    init(initialSelection: SidebarItem = .overview) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "gauge.with.dots.needle.67percent")
                    .tag(SidebarItem.overview)
                Section("Profiles") {
                    ForEach(model.config.profiles) { profile in
                        Label {
                            Text(profile.name)
                        } icon: {
                            Image(systemName: profile.symbol)
                                .foregroundStyle(profile.tint)
                        }
                        .badge(profile.id == model.config.activeProfileID ? Text("On") : nil)
                        .tag(SidebarItem.profile(profile.id))
                        .contextMenu {
                            Button("Use This Profile") { model.activate(profile) }
                            Button("Duplicate") { selection = .profile(model.addProfile(copying: profile).id) }
                            if !model.isBuiltIn(profile) {
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(profile) }
                            }
                        }
                    }
                }
                Section("This Mac") {
                    Label("Sensors", systemImage: "thermometer.medium")
                        .tag(SidebarItem.sensors)
                    Label {
                        Text("Helper")
                    } icon: {
                        Image(systemName: helperSymbol)
                            .foregroundStyle(helperNeedsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    .tag(SidebarItem.helper)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    selection = .profile(model.addProfile().id)
                } label: {
                    Label("New Profile", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(selection: $selection)
                case .profile(let id): ProfileEditor(profileID: id)
                case .sensors: SensorsView()
                case .helper: HelperView()
                }
            }
            .onAppear { followRequest() }
            .onChange(of: model.requestedPage) { followRequest() }
            .toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    ProfileMenu()
                }
            }
        }
    }

    private func followRequest() {
        guard let page = model.requestedPage else { return }
        selection = page
        model.requestedPage = nil
    }

    private var helperNeedsAttention: Bool { !model.helperStatus.isRunning || model.helperOutdated }

    private var helperSymbol: String {
        helperNeedsAttention ? "exclamationmark.shield" : "checkmark.shield"
    }
}

/// The active profile as a glass toolbar menu, reachable from every page.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Profile", selection: activeProfile) {
            ForEach(model.config.profiles) { profile in
                Label(profile.name, systemImage: profile.symbol).tag(profile.id)
            }
        }
        .pickerStyle(.menu)
        // Toolbars default to icon-only labels; show the profile's name too.
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Profile in use")
    }

    private var activeProfile: Binding<UUID> {
        Binding(get: { model.config.activeProfileID },
                set: { id in if let profile = model.config.profile(id: id) { model.activate(profile) } })
    }
}

// MARK: - Overview

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        GlassPage {
            PageHeader("Overview", subtitle: subtitle)

            if !model.helperStatus.isRunning || model.helperOutdated {
                HelperCallout(selection: $selection)
            }

            HeroCard()

            HStack(alignment: .top, spacing: 16) {
                ForEach(model.fans) { fan in
                    FanCard(fan: fan, status: model.status(forFan: fan.index))
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeader(title: "Profile", symbol: "slider.horizontal.3") {
                        Button("Edit \(model.activeProfile.name)") { selection = .profile(model.activeProfile.id) }
                            .buttonStyle(.glass)
                    }
                    ProfileButtons(onNew: { selection = .profile(model.addProfile().id) },
                                   onEdit: { selection = .profile($0.id) })
                }
            }

            HistoryCard()
        }
        .navigationTitle("Overview")
    }

    private var subtitle: String {
        guard model.helperStatus.isRunning else { return "Showing temperatures only: FanPilot can't change the fans until its helper is installed." }
        if model.helperState?.safetyActive == true { return "Too hot: every fan at full speed." }
        let profile = model.effectiveProfile
        let battery = model.helperState?.onBattery == true && model.config.batteryProfileID != nil ? " on battery" : ""
        return model.controlling ? "\(profile.name)\(battery): FanPilot is running the fans."
                                 : "\(profile.name)\(battery): macOS has the fans for now."
    }
}

/// The hottest temperature, big, like the Weather app.
struct HeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hottest = model.value(.cpuMax)
        GlassCard(padding: 24) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Hottest CPU core", systemImage: "cpu")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Heat.text(hottest))
                        .font(.system(size: 84, weight: .semibold, design: .rounded))
                        .foregroundStyle(Heat.color(hottest))
                    status
                }
                Spacer(minLength: 12)
                Grid(alignment: .trailing, horizontalSpacing: 28, verticalSpacing: 14) {
                    GridRow {
                        stat("CPU average", model.value(.cpuAverage))
                        stat("GPU", model.value(.gpuMax))
                    }
                    GridRow {
                        stat("SSD", model.value(.storage))
                        stat("Battery", model.value(.battery))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.helperState?.safetyActive == true {
            StatusCapsule(text: "Safety limit: full speed", symbol: "exclamationmark.triangle.fill", tint: .red)
        } else if model.effectiveProfile.rule.kind == .curve {
            let start = model.effectiveProfile.rule.startTemperature
            StatusCapsule(text: "Fans come on at \(Int(start))°", symbol: "fan", tint: model.effectiveProfile.tint)
        } else {
            StatusCapsule(text: model.effectiveProfile.summary, symbol: model.effectiveProfile.symbol,
                          tint: model.effectiveProfile.tint)
        }
    }

    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Heat.text(value))
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(Heat.color(value))
        }
    }
}

struct FanCard: View {
    let fan: FanInfo
    let status: FanStatus?

    private var controlled: Bool { status?.controlled == true }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "fan.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(controlled ? Color.white : Color.primary)
                        .frame(width: 34, height: 34)
                        .glassEffect(controlled ? Glass.regular.tint(.accentColor) : .regular, in: .circle)
                    Text(fan.name)
                        .font(.headline)
                    Spacer()
                    Text(controlled ? "FanPilot" : "macOS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(fan.actualRPM < 1 ? "Off" : rpmNumber(fan.actualRPM))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if fan.actualRPM >= 1 {
                        Text("rpm")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                CapsuleMeter(fraction: fan.fraction, target: targetFraction,
                             tint: controlled ? .accentColor : .gray)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(status?.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .lineLimit(2)
            }
        }
    }

    private var targetFraction: Double? {
        guard controlled, let rpm = status?.commandedRPM else { return nil }
        return (rpm - fan.minRPM) / fan.range
    }

    private var detail: String {
        if let error = status?.error { return error }
        guard let status else { return "\(rpmNumber(fan.minRPM))–\(rpmNumber(fan.maxRPM)) rpm" }
        if controlled, let rpm = status.commandedRPM { return "Target \(rpmText(rpm)) · \(status.reason)" }
        return status.reason
    }
}

/// Profiles as Liquid Glass capsules; the one in use is tinted with its colour.
struct ProfileButtons: View {
    @Environment(AppModel.self) private var model
    var onNew: () -> Void = {}
    var onEdit: (Profile) -> Void = { _ in }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            FlowLayout(spacing: 10) {
                ForEach(model.config.profiles) { profile in
                    let selected = profile.id == model.config.activeProfileID
                    if selected {
                        button(profile)
                            .buttonStyle(.glassProminent)
                            .tint(profile.tint)
                    } else {
                        button(profile)
                            .buttonStyle(.glass)
                    }
                }
                Button(action: onNew) {
                    Label("New Profile", systemImage: "plus")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    private func button(_ profile: Profile) -> some View {
        Button {
            withAnimation(.smooth) { model.activate(profile) }
        } label: {
            Label(profile.name, systemImage: profile.symbol)
                .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .help(profile.summary)
        .contextMenu {
            Button("Edit…") { onEdit(profile) }
            Button("Duplicate") { onEdit(model.addProfile(copying: profile)) }
        }
    }
}

/// "Install the helper" as a tinted glass callout.
struct HelperCallout: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        GlassCard(tint: .blue) {
            HStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .glassEffect(Glass.regular.tint(.blue), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if model.busy { ProgressView().controlSize(.small) }
                Button("Details") { selection = .helper }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button(buttonTitle) { Task { await buttonAction() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(model.busy)
            }
        }
    }

    private var title: String {
        switch model.helperStatus {
        case .needsApproval: return "Allow FanPilot to control the fans"
        case .notResponding: return "The fan helper isn't responding"
        case .running: return "The fan helper needs a restart"
        default: return "FanPilot can't change fan speed yet"
        }
    }

    private var explanation: String {
        switch model.helperStatus {
        case .needsApproval:
            return "FanPilot's fan helper is part of the app. macOS needs you to allow it: turn FanPilot on under Allow in the Background in Login Items. If you allowed it before, FanPilot was updated: builds without a developer certificate need allowing again after an update."
        case .notResponding, .running:
            return "Restarting it lets macOS run the helper that comes with this version of FanPilot."
        default:
            return "macOS only lets a background helper running as root change fan speed. FanPilot's is built into the app; turning it on asks macOS for permission once."
        }
    }

    private var buttonTitle: String {
        switch model.helperStatus {
        case .needsApproval: return "Open Login Items…"
        case .notResponding, .running: return "Restart Helper"
        default: return "Turn On Fan Control"
        }
    }

    private func buttonAction() async {
        switch model.helperStatus {
        case .notResponding, .running: await model.restartHelper()
        default: await model.enableHelper()
        }
    }
}

// MARK: - History

struct HistoryCard: View {
    enum Series: String, CaseIterable { case temperature = "Temperature", fans = "Fan Speed" }
    @State private var series = Series.temperature

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Last 10 Minutes", symbol: "chart.xyaxis.line") {
                    Picker("Show", selection: $series) {
                        ForEach(Series.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                switch series {
                case .temperature: TemperatureHistoryChart()
                case .fans: FanHistoryChart()
                }
            }
        }
    }
}

struct TemperatureHistoryChart: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Chart {
            ForEach(model.history) { sample in
                if let cpu = sample.cpu {
                    AreaMark(x: .value("Time", sample.date), yStart: .value("Base", 20), yEnd: .value("CPU", cpu))
                        .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.35), .orange.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Time", sample.date), y: .value("°C", cpu), series: .value("Sensor", "CPU"))
                        .foregroundStyle(by: .value("Sensor", "CPU hottest"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if let gpu = sample.gpu {
                    LineMark(x: .value("Time", sample.date), y: .value("°C", gpu), series: .value("Sensor", "GPU"))
                        .foregroundStyle(by: .value("Sensor", "GPU"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            let rule = model.effectiveProfile.rule
            if rule.kind == .curve {
                RuleMark(y: .value("Fans on", rule.startTemperature))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("fans on at \(Int(rule.startTemperature))°")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(["CPU hottest": Color.orange, "GPU": Color.purple])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYScale(domain: 20...110)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [20, 50, 80, 110]) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))°") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 2)) {
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: 170)
        .overlay {
            if model.history.count < 2 {
                Text("Collecting…").foregroundStyle(.secondary)
            }
        }
    }
}

struct FanHistoryChart: View {
    @Environment(AppModel.self) private var model

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let fan: String
        let rpm: Double
    }

    /// Flattened up front: nested ForEach over tuples inside a Chart is more
    /// than older Swift compilers can type-check in time.
    private var points: [Point] {
        var points: [Point] = []
        for (sampleIndex, sample) in model.history.enumerated() {
            for (fanIndex, rpm) in sample.fanRPM.enumerated() {
                points.append(Point(id: sampleIndex * 8 + fanIndex, date: sample.date, fan: "Fan \(fanIndex + 1)", rpm: rpm))
            }
        }
        return points
    }

    private var topRPM: Double { max(model.fans.map(\.maxRPM).max() ?? 6000, 1000) }

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Time", point.date), y: .value("rpm", point.rpm), series: .value("Fan", point.fan))
                .foregroundStyle(by: .value("Fan", point.fan))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .chartForegroundStyleScale(["Fan 1": Color.blue, "Fan 2": Color.teal])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYScale(domain: 0...topRPM)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 2)) {
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: 170)
    }
}
