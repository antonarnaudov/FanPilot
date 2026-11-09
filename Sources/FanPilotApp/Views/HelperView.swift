import FanPilotCore
import SwiftUI

struct HelperView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPage {
            PageHeader("Helper", subtitle: "What changes the fan speed, and what it has done")

            GlassCard(padding: 24) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .glassEffect(Glass.regular.tint(statusColor), in: .circle)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text("Fan Control Helper")
                                .font(.title2.weight(.semibold))
                            StatusCapsule(text: statusText, symbol: statusSymbol, tint: statusColor)
                        }
                        Text("Part of FanPilot.app. macOS only lets a background helper running as root change fan speed, so FanPilot registers this one with macOS, and macOS asks you once to allow it in Login Items. It runs your profile even when the app is closed, gives the fans back to macOS before sleep and whenever your profile says so, and goes away when you delete FanPilot.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            switch model.helperStatus {
                            case .notInstalled, .checking:
                                Button("Turn On Fan Control") { Task { await model.enableHelper() } }
                                    .buttonStyle(.glassProminent)
                            case .needsApproval:
                                Button("Open Login Items…") { Task { await model.enableHelper() } }
                                    .buttonStyle(.glassProminent)
                            case .notResponding:
                                Button("Restart Helper") { Task { await model.restartHelper() } }
                                    .buttonStyle(.glassProminent)
                            case .running:
                                if model.helperOutdated {
                                    Button("Restart Helper") { Task { await model.restartHelper() } }
                                        .buttonStyle(.glassProminent)
                                } else {
                                    Button("Restart Helper") { Task { await model.restartHelper() } }
                                        .buttonStyle(.glass)
                                }
                            }
                            if model.helperRegistered {
                                Button("Turn Off", role: .destructive) { Task { await model.disableHelper() } }
                                    .buttonStyle(.glass)
                                    .help("macOS stops the helper and the fans go back to macOS.")
                            }
                            if model.busy { ProgressView().controlSize(.small) }
                        }
                        .controlSize(.large)
                        .disabled(model.busy)
                        if let error = model.lastError {
                            Text(error)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let state = model.helperState {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    detail("Version", state.version + (model.helperOutdated ? " (expected \(FanPilot.version))" : ""), "number")
                    detail("Runs as", state.isRoot ? "root" : "user" + (state.dryRun ? ", dry run" : ""), "person.badge.key")
                    if let flag = state.unlockFlag {
                        detail("Ftst unlock", flag == 0 ? "Off · macOS has the fans" : "On · FanPilot has the fans", "key")
                    }
                    detail("Power", state.onBattery ? "Battery" : "Power adapter", state.onBattery ? "battery.75percent" : "powerplug")
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader("Activity", symbol: "list.bullet.rectangle")
                    if let events = model.helperState?.events, !events.isEmpty {
                        ForEach(events.reversed().prefix(60)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(event.date, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)
                                Text(event.message)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        Text(model.helperStatus.isRunning ? "No activity yet." : "Activity appears here once the helper runs.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("If the fans ever seem stuck: choose the macOS profile, turn the helper off here, or restart the Mac. From Terminal: sudo /Applications/FanPilot.app/Contents/MacOS/fanpilotctl auto. The helper's log is /Library/Logs/FanPilot-helper.log.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .navigationTitle("Helper")
    }

    private func detail(_ title: String, _ value: String, _ symbol: String) -> some View {
        GlassCard(padding: 14, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }
        }
    }

    private var statusText: String {
        switch model.helperStatus {
        case .checking: return "Checking…"
        case .notInstalled: return "Off"
        case .needsApproval: return "Waiting for your approval"
        case .notResponding: return "Not responding"
        case .running: return model.helperOutdated ? "Needs a restart" : "Running"
        }
    }

    private var statusSymbol: String {
        switch model.helperStatus {
        case .running: return model.helperOutdated ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .checking: return "hourglass"
        default: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.helperStatus {
        case .running: return model.helperOutdated ? .orange : .green
        case .checking: return .gray
        default: return .orange
        }
    }
}
