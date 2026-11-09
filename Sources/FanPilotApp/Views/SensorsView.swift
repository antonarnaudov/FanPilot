import FanPilotCore
import SwiftUI

/// Every live sensor as a heat map: one tile per sensor, coloured by temperature.
struct SensorsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        GlassPage {
            PageHeader("Sensors", subtitle: "\(model.readings.count) live temperature sensors")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(SensorSelector.summaries, id: \.self) { selector in
                    GlassCard(padding: 14, cornerRadius: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selector.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(Heat.text(model.value(selector), decimals: true))
                                .font(.system(.title, design: .rounded).weight(.semibold))
                                .foregroundStyle(Heat.color(model.value(selector)))
                                .monospacedDigit()
                        }
                    }
                }
            }

            ForEach(SensorGroup.allCases, id: \.self) { group in
                let items = filtered.filter { $0.group == group }.sorted { $0.value > $1.value }
                if !items.isEmpty {
                    GroupCard(group: group, readings: items)
                }
            }

            if model.readings.isEmpty {
                ContentUnavailableView("No Sensors", systemImage: "thermometer.medium.slash",
                                       description: Text("The SMC returned no temperature readings."))
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Find a sensor")
        .onAppear { model.needsAllSensors = true }
        .onDisappear { model.needsAllSensors = false }
        .navigationTitle("Sensors")
    }

    private var filtered: [SensorReading] {
        guard !search.isEmpty else { return model.readings }
        return model.readings.filter {
            $0.key.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)
        }
    }
}

private struct GroupCard: View {
    let group: SensorGroup
    let readings: [SensorReading]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "\(group.title) · \(readings.count)", symbol: symbol) {
                    if let hottest = readings.first?.value {
                        let average = readings.map(\.value).reduce(0, +) / Double(readings.count)
                        Text("hottest \(Heat.text(hottest)) · average \(Heat.text(average))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                    ForEach(readings) { reading in
                        SensorTile(reading: reading)
                    }
                }
            }
        }
    }

    private var symbol: String {
        switch group {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .storage: return "internaldrive"
        case .battery: return "battery.75percent"
        case .wireless: return "wifi"
        case .other: return "thermometer.medium"
        }
    }
}

private struct SensorTile: View {
    let reading: SensorReading

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(reading.key)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(Heat.text(reading.value))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Heat.tint(reading.value).opacity(0.28), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Heat.tint(reading.value).opacity(0.5), lineWidth: 1)
        }
        .help(reading.knownName.map { "\($0) (\(reading.key))" } ?? reading.key)
        .accessibilityElement(children: .combine)
    }
}
