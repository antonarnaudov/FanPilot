import Charts
import FanPilotCore
import SwiftUI

/// Interactive fan curve: drag points, double-click to add one.
struct CurveChart: View {
    @Binding var rule: FanRule
    @Binding var selectedPoint: UUID?
    let liveTemperature: Double?
    let livePercent: Double?
    let criticalTemperature: Double

    @State private var dragging: UUID?

    private static let xDomain = 20.0...110.0

    /// The curve extended flat to both edges of the chart.
    private var line: [(t: Double, p: Double)] {
        let sorted = rule.points.sorted { $0.temperature < $1.temperature }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        return [(Self.xDomain.lowerBound, first.percent)] + sorted.map { ($0.temperature, $0.percent) }
            + [(Self.xDomain.upperBound, last.percent)]
    }

    var body: some View {
        Chart {
            ForEach(Array(line.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("°C", point.t), y: .value("%", point.p))
                    .foregroundStyle(
                        LinearGradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("°C", point.t), y: .value("%", point.p))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // The zone where macOS keeps the fans.
            RectangleMark(xStart: .value("from", Self.xDomain.lowerBound), xEnd: .value("to", rule.stopTemperature), yStart: .value("low", 0), yEnd: .value("high", 100))
                .foregroundStyle(Color.secondary.opacity(0.07))
            RuleMark(x: .value("Start", rule.startTemperature))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.green)
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("on \(Int(rule.startTemperature))°").font(.caption2).foregroundStyle(.green)
                }
            RuleMark(x: .value("Stop", rule.stopTemperature))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    Text("off \(Int(rule.stopTemperature))°").font(.caption2).foregroundStyle(.secondary)
                }
            RuleMark(x: .value("Safety", criticalTemperature))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
                .foregroundStyle(.red.opacity(0.6))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("max \(Int(criticalTemperature))°").font(.caption2).foregroundStyle(.red)
                }

            if let live = liveTemperature {
                RuleMark(x: .value("Now", min(max(live, Self.xDomain.lowerBound), Self.xDomain.upperBound)),
                         yStart: .value("low", 0), yEnd: .value("high", 100))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    // Inside the plot at the bottom, clear of the labels along the top edge.
                    .annotation(position: .overlay, alignment: .bottom, spacing: 0) {
                        Text("now \(Int(live.rounded()))°")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                            .padding(.bottom, 6)
                    }
                if let percent = livePercent {
                    PointMark(x: .value("°C", live), y: .value("%", percent))
                        .symbol(.diamond)
                        .symbolSize(110)
                        .foregroundStyle(Color.orange)
                }
            }

            ForEach(rule.points) { point in
                PointMark(x: .value("°C", point.temperature), y: .value("%", point.percent))
                    .symbolSize(point.id == dragging || point.id == selectedPoint ? 170 : 90)
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .top, spacing: 4) {
                        if point.id == dragging || point.id == selectedPoint {
                            Text("\(Int(point.temperature))° · \(Int(point.percent))%")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4)
                                .background(.background, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
            }
        }
        .chartXScale(domain: Self.xDomain)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))°") } }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                guard let plot = proxy.plotFrame.map({ geometry[$0] }) else { return }
                                if dragging == nil {
                                    dragging = nearest(to: drag.startLocation, proxy: proxy, plot: plot)
                                    selectedPoint = dragging
                                }
                                if let id = dragging { move(id, to: drag.location, proxy: proxy, plot: plot) }
                            }
                            .onEnded { _ in dragging = nil }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { tap in
                            guard let plot = proxy.plotFrame.map({ geometry[$0] }) else { return }
                            add(at: tap.location, proxy: proxy, plot: plot)
                        }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture(count: 1).onEnded { tap in
                            guard let plot = proxy.plotFrame.map({ geometry[$0] }) else { return }
                            selectedPoint = nearest(to: tap.location, proxy: proxy, plot: plot)
                        }
                    )
            }
        }
        .accessibilityLabel("Fan curve")
        .accessibilityValue(rule.points.sorted { $0.temperature < $1.temperature }
            .map { "\(Int($0.temperature)) degrees: \(Int($0.percent)) percent" }.joined(separator: ", "))
    }

    private func nearest(to location: CGPoint, proxy: ChartProxy, plot: CGRect) -> UUID? {
        var best: (UUID, CGFloat)?
        for point in rule.points {
            guard let x = proxy.position(forX: point.temperature), let y = proxy.position(forY: point.percent) else { continue }
            let distance = hypot(plot.minX + x - location.x, plot.minY + y - location.y)
            if distance < 16, distance < (best?.1 ?? .infinity) { best = (point.id, distance) }
        }
        return best?.0
    }

    private func values(at location: CGPoint, proxy: ChartProxy, plot: CGRect) -> (Double, Double)? {
        guard let t: Double = proxy.value(atX: location.x - plot.minX),
              let p: Double = proxy.value(atY: location.y - plot.minY)
        else { return nil }
        return (t, p)
    }

    private func move(_ id: UUID, to location: CGPoint, proxy: ChartProxy, plot: CGRect) {
        guard let (t, p) = values(at: location, proxy: proxy, plot: plot) else { return }
        var points = rule.points.sorted { $0.temperature < $1.temperature }
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        // Points can't pass their neighbours.
        let low = index > 0 ? points[index - 1].temperature + 1 : Self.xDomain.lowerBound
        let high = index < points.count - 1 ? points[index + 1].temperature - 1 : Self.xDomain.upperBound
        points[index].temperature = (min(max(t, low), high) * 2).rounded() / 2
        points[index].percent = min(max(p, 0), 100).rounded()
        rule.points = points
    }

    private func add(at location: CGPoint, proxy: ChartProxy, plot: CGRect) {
        guard let (t, p) = values(at: location, proxy: proxy, plot: plot), Self.xDomain.contains(t) else { return }
        guard !rule.points.contains(where: { abs($0.temperature - t) < 1 }) else { return }
        let point = CurvePoint(t.rounded(), min(max(p, 0), 100).rounded())
        rule.points.append(point)
        selectedPoint = point.id
    }
}
