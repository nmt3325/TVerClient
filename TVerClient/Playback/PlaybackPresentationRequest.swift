import SwiftUI

/// One delivery across the tab stacks, including lazily mounted recipients.
@MainActor
final class PlayerPresentationGate: ObservableObject {
    private(set) var lastDeliveredToken = 0

    func claim(_ token: Int, isRecipient: Bool) -> Bool {
        guard isRecipient, token > lastDeliveredToken else { return false }
        lastDeliveredToken = token
        return true
    }
}

private struct PlayerPresentationGateKey: EnvironmentKey {
    static let defaultValue: PlayerPresentationGate? = nil
}
private struct AcceptsPlayerPresentationKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var playerPresentationGate: PlayerPresentationGate? {
        get { self[PlayerPresentationGateKey.self] }
        set { self[PlayerPresentationGateKey.self] = newValue }
    }
    var acceptsPlayerPresentation: Bool {
        get { self[AcceptsPlayerPresentationKey.self] }
        set { self[AcceptsPlayerPresentationKey.self] = newValue }
    }
}

@MainActor
private struct PlayerPresentationRequestModifier: ViewModifier {
    let token: Int
    let action: () -> Void
    @Environment(\.playerPresentationGate) private var gate
    @Environment(\.acceptsPlayerPresentation) private var isRecipient

    func body(content: Content) -> some View {
        content
            .onChange(of: token) { deliver($0) }
            .onAppear {
                // Standalone screens retain change-only behavior. A lazy root
                // tab may claim a pending request, but not replay an old one.
                if gate != nil { deliver(token) }
            }
            .onChange(of: isRecipient) { accepts in
                if accepts, gate != nil { deliver(token) }
            }
    }

    private func deliver(_ value: Int) {
        guard value > 0, isRecipient else { return }
        if let gate, !gate.claim(value, isRecipient: isRecipient) { return }
        action()
    }
}

extension View {
    @MainActor
    func onPlayerPresentationRequest(
        _ token: Int,
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(PlayerPresentationRequestModifier(token: token, action: action))
    }
}
