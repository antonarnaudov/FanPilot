import FanPilotCore
import ServiceManagement
import SwiftUI

/// The Settings window (⌘,), with toolbar tabs like every Mac app's settings.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Control", systemImage: "fan") {
                ControlSettings()
            }
            Tab("Safety", systemImage: "exclamationmark.shield") {
                SafetySettingsPane()
            }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Menu Bar") {
                Picker("Show", selection: $model.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                Picker("Temperature", selection: $model.menuBarSensor) {
                    ForEach(SensorSelector.summaries, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Open FanPilot at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
            } footer: {
                FormFooter("The helper runs your profile from startup either way. This only adds the menu bar icon.")
            }
            Section {
                LabeledContent("Version", value: FanPilot.appVersion)
                LabeledContent("Helper", value: FanPilot.version)
                Link("FanPilot on GitHub", destination: URL(string: "https://github.com/antonarnaudov/FanPilot")!)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct ControlSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("On battery, use", selection: batteryProfile) {
                    Text("The selected profile").tag(UUID?.none)
                    Divider()
                    ForEach(model.config.profiles) { profile in
                        Text(profile.name).tag(UUID?.some(profile.id))
                    }
                }
            } footer: {
                FormFooter("For example Cool while plugged in, and macOS on battery to save power.")
            }
            Section {
                Picker("Update every", selection: interval) {
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                }
            } footer: {
                FormFooter("How often the helper reads the sensors and adjusts the fans.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var batteryProfile: Binding<UUID?> {
        Binding(get: { model.config.batteryProfileID }, set: { id in model.updateConfig { $0.batteryProfileID = id } })
    }

    private var interval: Binding<Double> {
        Binding(get: { model.config.interval }, set: { value in model.updateConfig { $0.interval = value } })
    }
}

struct SafetySettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ValueSlider(title: "Full speed at", value: critical, range: 80...105, step: 1,
                            format: { "\(Int($0))°C" },
                            minimumSymbol: "thermometer.low", maximumSymbol: "thermometer.high")
                ValueSlider(title: "Only after it lasts", value: sustain, range: 0...20, step: 1,
                            format: { "\(Int($0)) s" },
                            help: "Ignores short spikes of single cores, so the fans don't blast for a second.")
                ValueSlider(title: "Until it falls by", value: margin, range: 3...15, step: 1,
                            format: { "\(Int($0))°C" })
            } footer: {
                FormFooter("When the hottest CPU or GPU sensor reaches this temperature, every fan FanPilot controls runs at full speed. With the macOS profile, Apple's own protection is in charge.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var critical: Binding<Double> {
        Binding(get: { model.config.safety.criticalTemperature },
                set: { value in model.updateConfig { $0.safety.criticalTemperature = value } })
    }

    private var sustain: Binding<Double> {
        Binding(get: { model.config.safety.sustain },
                set: { value in model.updateConfig { $0.safety.sustainSeconds = value } })
    }

    private var margin: Binding<Double> {
        Binding(get: { model.config.safety.releaseMargin },
                set: { value in model.updateConfig { $0.safety.releaseMargin = value } })
    }
}
