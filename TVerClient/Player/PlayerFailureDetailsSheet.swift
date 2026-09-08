import SwiftUI

/// Keeps the full error and recovery text reachable even when episode details
/// are absent in landscape or full screen. No extra navigation stack is needed.
@MainActor
struct PlayerFailureDetailsSheet: View {
    let presentation: TVerErrorPresentation
    let action: PlayerPrimaryAction
    let officialURL: URL?
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Text("再生エラーの詳細")
                    .font(.headline)
                Spacer(minLength: DS.Spacing.s)
                Button("閉じる") { dismiss() }
                    .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    Text(presentation.title)
                        .font(.title2.weight(.semibold))
                    Text(presentation.message)
                    Text(presentation.recoverySuggestion)
                        .foregroundStyle(.secondary)
                    Button(action: retry) {
                        Label(action.title, systemImage: action.systemImage)
                            .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!action.isEnabled)
                    if let officialURL {
                        Link(destination: officialURL) {
                            Label("TVer公式ページで開く", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.l)
        .foregroundStyle(.primary)
        .tint(Color.accentColor)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
