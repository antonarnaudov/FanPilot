import FanPilotCore
import SwiftUI

/// The window under the menu bar icon, built from glass modules like Control Center.
struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openMainWindow) private var openMainWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                temperatureModule
                HStack(spacing: 10) {
                    ForEach(model.fans) { fan in
                        fanModule(fan)
                    }
                }
                profilesModule
                helperModule
                VStack(spacing: 0) {
                    Button { openMainWindow() } label: { Text("Open FanPilot") }
                    Button {
                        openSettings()
                        NSApp.activate()
                    } label: {
                        shortcutRow("Settings…", "⌘,")
                    }
                    Button { NSApp.terminate(nil) } label: { shortcutRow("Quit FanPilot", "⌘Q") }
                        .keyboardShortcut("q")
                        .help("The helper keeps running your profile after you quit.")
                }
                .buttonStyle(.menuRow)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 330)
    }

    // MARK: Modules

    private func module<Content: View>(tint: Color? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular, in: .rect(cornerRadius: 22))
    }

    private var temperatureModule: some View {
        let hottest = model.value(.cpuMax)
        return module {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CPU")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Heat.text(hottest))
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .foregroundStyle(Heat.color(hottest))
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(model.helperState?.safetyActive == true ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    smallStat("GPU", model.value(.gpuMax))
                    smallStat("SSD", model.value(.storage))
                }
            }
        }
    }

    private var statusLine: String {
        if model.helperState?.safetyActive == true { return "Too hot: full speed" }
        guard model.helperStatus.isRunning else { return "Not controlling the fans" }
        let profile = model.effectiveProfile
        if model.helperState?.onBattery == true, model.config.batteryProfileID != nil {
            return "\(profile.name) on battery"
        }
        return model.controlling ? "\(profile.name): fans on" : "\(profile.name): macOS has the fans"
    }

    private func smallStat(_ title: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Heat.text(value))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Heat.color(value))
                .monospacedDigit()
        }
    }

    private func fanModule(_ fan: FanInfo) -> some View {
        let status = model.status(forFan: fan.index)
        let controlled = status?.controlled == true
        return module {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "fan.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(controlled ? Color.white : Color.primary)
                        .frame(width: 28, height: 28)
                        .glassEffect(controlled ? Glass.regular.tint(.accentColor) : .regular, in: .circle)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(fan.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(fan.actualRPM < 1 ? "Off" : rpmNumber(fan.actualRPM))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
                CapsuleMeter(fraction: fan.fraction,
                             target: controlled ? status?.commandedRPM.map { ($0 - fan.minRPM) / fan.range } : nil,
                             tint: controlled ? .accentColor : .gray)
            }
        }
    }

    private var profilesModule: some View {
        module {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Profile")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { edit(model.activeProfile) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .help("Edit \(model.activeProfile.name)")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: 5),
                          spacing: 10) {
                    ForEach(model.config.profiles) { profile in
                        profileToggle(profile)
                    }
                    newProfileToggle
                }
            }
        }
    }

    private func edit(_ profile: Profile) {
        model.requestedPage = .profile(profile.id)
        openMainWindow()
    }

    private var newProfileToggle: some View {
        Button {
            edit(model.addProfile())
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .glassEffect(.regular.interactive(), in: .circle)
                Text("New")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Create a profile")
        .accessibilityLabel("New profile")
    }

    /// A round glass toggle with its name underneath, like Control Center.
    private func profileToggle(_ profile: Profile) -> some View {
        let active = profile.id == model.config.activeProfileID
        let inEffect = profile.id == model.effectiveProfile.id
        return Button {
            withAnimation(.smooth) { model.activate(profile) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(active || inEffect ? Color.white : Color.primary)
                    .frame(width: 42, height: 42)
                    .glassEffect(active || inEffect ? Glass.regular.tint(profile.tint).interactive()
                                                    : .regular.interactive(), in: .circle)
                Text(profile.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(active ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(profile.summary)
        .contextMenu {
            Button("Edit…") { edit(profile) }
            Button("Duplicate") { edit(model.addProfile(copying: profile)) }
        }
        .accessibilityLabel(profile.name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder
    private var helperModule: some View {
        switch model.helperStatus {
        case .running:
            if model.helperOutdated {
                notice("arrow.triangle.2.circlepath", .orange, "The fan helper needs a restart.", button: "Restart") {
                    Task { await model.restartHelper() }
                }
            } else if model.helperState?.dryRun == true {
                notice("hammer.fill", .gray, "Development helper: dry run, the fans don't change.", button: nil) {}
            }
        case .notInstalled:
            notice("lock.shield.fill", .blue, "Fan control is off. Turn it on to let FanPilot change fan speed.", button: "Turn On") {
                Task { await model.enableHelper() }
            }
        case .needsApproval:
            notice("lock.shield.fill", .blue, "Allow FanPilot under Login Items in System Settings to control the fans.", button: "Allow…") {
                Task { await model.enableHelper() }
            }
        case .notResponding:
            notice("exclamationmark.triangle.fill", .orange, "The fan helper isn't responding.", button: "Restart") {
                Task { await model.restartHelper() }
            }
        case .checking:
            EmptyView()
        }
        if let error = model.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notice(_ symbol: String, _ color: Color, _ text: String, button: String?,
                        action: @escaping () -> Void) -> some View {
        module(tint: color) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .glassEffect(Glass.regular.tint(color), in: .circle)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let button {
                    Button(button, action: action)
                        .buttonStyle(.glassProminent)
                        .tint(color)
                        .disabled(model.busy)
                }
            }
        }
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .foregroundStyle(.tertiary)
        }
    }
}
