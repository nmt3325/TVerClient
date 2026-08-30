import AVKit
import SwiftUI

/// Compatibility wrapper around `ContentStatusView`.
///
/// Screens owned by other tasks still call this, so the signature stays put,
/// but the layout now comes from the design system instead of a second
/// hand-rolled copy of the same empty state.
struct ScheduleStatusView<Accessory: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        ContentStatusView(
            .empty(title: title, message: message, systemImage: systemImage),
            accessory: { accessory }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 16:9 artwork for screens that have not moved to `MediaRow` yet.
struct ProgramThumbnail: View {
    let url: URL?

    var body: some View {
        CachedProgramImage(url: url, contentMode: .fill) {
            MediaThumbnailPlaceholder()
        }
        .background(DS.Palette.thumbnailPlaceholder)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 失敗を黙って終わらせないための、共通の言い換え。
///
/// `localizedDescription` をそのまま出すと、何が起きたのかも次に何を
/// すればよいのかも伝わらない。失敗は必ずここを通してから画面に出す。
struct StatusFailure: Equatable, Sendable {
    let title: String
    let message: String
    /// 「次に何をすればよいか」。空にならない。
    let recovery: String
    let isRetryable: Bool

    init(_ error: Error) {
        let presentation = TVerClientError.normalized(from: error).presentation
        title = presentation.title
        message = presentation.message
        recovery = presentation.recoverySuggestion
        isRetryable = presentation.isRetryable
    }

    /// バナーやログのように1行で出す場所向けの短い説明。
    var summary: String {
        message.isEmpty ? title : message
    }
}

/// Press feedback shared by the screens that still draw tappable blocks.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: DS.Motion.pressDuration), value: configuration.isPressed)
    }
}

#Preview("番組表") {
    RootTabView()
}
