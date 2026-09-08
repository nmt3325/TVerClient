import SwiftUI

/// Applies an accessibility identifier only when one is provided, so buttons
/// without a UI-test contract stay untouched.
struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// Circular player button with a guaranteed 44pt tap target.
@MainActor
struct PlayerIconButton: View {
    let systemImage: String
    let label: String
    var identifier: String?
    var glyphSize: CGFloat = 17
    var diameter: CGFloat = DS.Size.minimumTapTarget
    var isProminent: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(isProminent ? Color.black.opacity(0.3) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
    }
}

/// Badge shown after a double-tap skip, on the side that was tapped.
@MainActor
struct SkipRippleOverlay: View {
    let feedback: SkipFeedback?

    var body: some View {
        GeometryReader { proxy in
            if let feedback {
                HStack(spacing: 0) {
                    if feedback.isForward { Spacer(minLength: 0) }
                    VStack(spacing: DS.Spacing.xs) {
                        Image(systemName: feedback.systemImage)
                            .font(.system(size: 28, weight: .semibold))
                        Text(feedback.title)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .frame(width: proxy.size.width * 0.42, height: proxy.size.height)
                    .background(Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: proxy.size.height / 2, style: .continuous))
                    if !feedback.isForward { Spacer(minLength: 0) }
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.18), value: feedback)
    }
}

/// Top and bottom gradients that keep white controls readable over any frame.
struct PlayerScrim: View {
    var body: some View {
        // 固定の110+150ptを縦積みすると、16:9の小型ステージをはみ出す。
        // 一枚の相対グラデーションなら高さを奪わず、中央の操作も読める。
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.7), location: 0),
                .init(color: .black.opacity(0.25), location: 0.45),
                .init(color: .black.opacity(0.8), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}
