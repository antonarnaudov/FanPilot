import SwiftUI

/// The calm, neutral surface behind FanPilot's glass: the system window
/// background with a faint light-to-dark fall-off for depth, like the menu bar
/// window. It deliberately carries no colour; temperatures and the active
/// profile show their colour in the content, not the whole window.
struct HeatBackdrop: View {
    let temperature: Double?
    let tint: Color

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                LinearGradient(colors: [Color.primary.opacity(0.05), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
    }
}
