import SwiftUI

/// Colors, shapes, and small components shared by every screen.
enum Theme {
    static let brandStart = Color(red: 0.31, green: 0.36, blue: 1.0)
    static let brandEnd = Color(red: 0.64, green: 0.36, blue: 1.0)
    static let brand = LinearGradient(colors: [brandStart, brandEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cardRadius: CGFloat = 18
    static let card = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
    static let cardFill = Color(.secondarySystemBackground)
    /// A barely-there edge that keeps cards crisp on both light and dark backgrounds.
    static let hairline = Color.primary.opacity(0.06)
}

/// A soft, slowly breathing brand-colored glow to sit behind a hero mark.
struct AmbientGlow: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RadialGradient(
            colors: [Theme.brandEnd.opacity(0.28), Theme.brandStart.opacity(0.12), .clear],
            center: .center, startRadius: 0, endRadius: 130)
            .scaleEffect(breathe ? 1.08 : 0.92)
            .opacity(breathe ? 1 : 0.75)
            .animation(reduceMotion ? nil : .easeInOut(duration: 3.2).repeatForever(), value: breathe)
            .onAppear { breathe = true }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The app's mark: a tapping hand on the brand gradient.
struct AgentGlyph: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.brand)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A colored dot that softly pulses while something is in progress.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background {
                if pulsing {
                    Circle()
                        .fill(color.opacity(0.35))
                        .scaleEffect(animate ? 2.2 : 1)
                        .opacity(animate ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: animate)
                }
            }
            .onAppear { animate = pulsing }
            .onChange(of: pulsing) { _, value in animate = value }
    }
}

/// An SF Symbol on a tinted rounded square, like Settings rows.
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension AutomationPhase {
    var title: String {
        switch self {
        case .idle: "Automation off"
        case .starting: "Starting automation…"
        case .ready: "Ready"
        case .failed: "Automation failed"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .starting: .orange
        case .ready: .green
        case .failed: .red
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "hand.raised.slash.fill"
        case .starting: "hourglass"
        case .ready: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }
}

/// Markdown parsing is not free; answers are re-rendered on every transcript update, so cache the result.
@MainActor
enum Markdown {
    private static var cache: [String: AttributedString] = [:]

    static func attributed(_ text: String) -> AttributedString {
        if let cached = cache[text] { return cached }
        let parsed = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        cache[text] = parsed
        return parsed
    }
}
