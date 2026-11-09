import FanPilotCore
import SwiftUI

// MARK: - Colour and temperature

enum Heat {
    /// Text colour for a temperature: only warm values draw attention.
    static func color(_ celsius: Double?) -> Color {
        guard let celsius else { return .secondary }
        switch celsius {
        case ..<75: return .primary
        case ..<90: return .orange
        default: return .red
        }
    }

    static let stops: [Color] = [.blue, .cyan, .green, .yellow, .orange, .red]
    static let gradient = Gradient(colors: stops)
    static let range = 20.0...110.0

    /// 0 at 20 °C, 1 at 110 °C.
    static func fraction(_ celsius: Double?) -> Double {
        (clamp(celsius) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// The colour of a temperature on the blue → red scale.
    static func tint(_ celsius: Double?) -> Color {
        let position = fraction(celsius) * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        return stops[index].mix(with: stops[index + 1], by: position - Double(index))
    }

    static func text(_ celsius: Double?, decimals: Bool = false) -> String {
        guard let celsius else { return "–" }
        return decimals ? String(format: "%.1f°", celsius) : "\(Int(celsius.rounded()))°"
    }

    static func clamp(_ celsius: Double?) -> Double {
        min(max(celsius ?? range.lowerBound, range.lowerBound), range.upperBound)
    }
}

enum Palette {
    static let names = ["blue", "cyan", "teal", "green", "mint", "yellow", "orange", "red", "pink", "purple", "indigo", "gray"]

    static func color(_ name: String?) -> Color {
        switch name {
        case "cyan": return .cyan
        case "teal": return .teal
        case "green": return .green
        case "mint": return .mint
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        case "pink": return .pink
        case "purple": return .purple
        case "indigo": return .indigo
        case "gray": return .gray
        default: return .blue
        }
    }
}

extension Profile {
    var tint: Color { Palette.color(color) }
}

extension NumberFormatter {
    static let rpm: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

func rpmNumber(_ rpm: Double) -> String {
    NumberFormatter.rpm.string(from: NSNumber(value: rpm.rounded())) ?? "\(Int(rpm))"
}

func rpmText(_ rpm: Double) -> String {
    rpm < 1 ? "Off" : "\(rpmNumber(rpm)) rpm"
}

// MARK: - Glass surfaces

/// A Liquid Glass card: the surface every block of content sits on.
struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    var padding: CGFloat = 20
    var cornerRadius: CGFloat = 26
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular,
                         in: .rect(cornerRadius: cornerRadius))
    }
}

/// The small caption at the top of a card, like a widget's header.
struct CardHeader<Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(_ title: String, symbol: String) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

/// A large page title, as in Apple's current apps.
struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 4)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A scrolling page over the live heat backdrop, which extends under the glass sidebar.
struct GlassPage<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(DesignPreview.scrollsToBottom ? .bottom : .top)
        .background {
            HeatBackdrop(temperature: model.value(.hottest), tint: model.effectiveProfile.tint)
                .ignoresSafeArea()
                .backgroundExtensionEffect()
        }
        .toolbar(removing: .title)
    }
}

// MARK: - Readouts

/// A capsule meter: how far along its range a value is, with an optional target mark.
struct CapsuleMeter: View {
    let fraction: Double
    var target: Double? = nil
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(geometry.size.height, width * min(max(fraction, 0), 1)))
                    .opacity(fraction > 0 ? 1 : 0)
                if let target {
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 3, height: geometry.size.height + 6)
                        .offset(x: width * min(max(target, 0), 1) - 1.5)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A status capsule: symbol and a few words, tinted.
struct StatusCapsule: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

/// A round profile icon on glass, filled with the profile's colour when on.
struct ProfileIcon: View {
    let profile: Profile
    var size: CGFloat = 26
    var active = true

    var body: some View {
        Image(systemName: profile.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .glassEffect(active ? Glass.regular.tint(profile.tint) : .regular, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A slider on its own line with the title and value above it, for glass cards.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let format: (Double) -> String
    var help: String? = nil
    var minimumSymbol: String? = nil
    var maximumSymbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                Text(format(value))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.08), in: .capsule)
                    .contentTransition(.numericText(value: value))
            }
            Slider(value: stepped, in: range) {
                Text(title)
            } minimumValueLabel: {
                symbol(minimumSymbol)
            } maximumValueLabel: {
                symbol(maximumSymbol)
            }
            .labelsHidden()
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Continuous slider (no tick marks), rounded to `step`.
    private var stepped: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                let rounded = (newValue / step).rounded() * step
                if rounded != value { value = rounded }
            })
    }

    @ViewBuilder
    private func symbol(_ name: String?) -> some View {
        if let name {
            Image(systemName: name)
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
    }
}

/// A slider row for grouped settings forms (the Settings window).
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let format: (Double) -> String
    var help: String? = nil
    var minimumSymbol: String? = nil
    var maximumSymbol: String? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: stepped, in: range) {
                    Text(title)
                } minimumValueLabel: {
                    symbol(minimumSymbol)
                } maximumValueLabel: {
                    symbol(maximumSymbol)
                }
                .labelsHidden()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .trailing)
            }
            .frame(maxWidth: 340)
        } label: {
            Text(title)
            if let help {
                Text(help)
            }
        }
    }

    private var stepped: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                let rounded = (newValue / step).rounded() * step
                if rounded != value { value = rounded }
            })
    }

    @ViewBuilder
    private func symbol(_ name: String?) -> some View {
        if let name {
            Image(systemName: name)
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
    }
}

/// Section footer text, aligned with the section (grouped forms right-align footers).
struct FormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Buttons

/// A full-width row that highlights on hover, like the items at the bottom of a menu bar extra.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(.rect(cornerRadius: 10))
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(0.1))
                        .opacity(isEnabled && (hovering || configuration.isPressed) ? 1 : 0)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == MenuRowButtonStyle {
    static var menuRow: MenuRowButtonStyle { MenuRowButtonStyle() }
}


/// Lays children out left to right and wraps onto new lines, for any number of items.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
