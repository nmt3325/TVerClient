import AVFoundation
import SwiftUI

struct PlaybackFailureView: View {
    let presentation: TVerErrorPresentation
    let officialURL: URL
    let retry: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(presentation.message)
                .font(.subheadline)
            Text(presentation.recoverySuggestion)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: retry) {
                Label("もう一度試す", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button { openURL(officialURL) } label: {
                Label("TVer公式ページで開く", systemImage: "safari")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct PlaybackTimelineView: View {
    @ObservedObject var playbackController: PlaybackController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = safeElapsed
            if let duration = safeDuration {
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { min(elapsed, duration) },
                            set: { playbackController.seek(to: $0) }
                        ),
                        in: 0 ... duration
                    )
                    .accessibilityLabel(TVerAccessibilityText.playbackTime(elapsed: elapsed, duration: duration))
                    HStack {
                        Text(formattedDuration(elapsed))
                        Spacer()
                        Text(formattedDuration(duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            } else {
                Text(TVerAccessibilityText.playbackTime(elapsed: elapsed, duration: nil))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel(TVerAccessibilityText.playbackTime(elapsed: elapsed, duration: nil))
            }
        }
    }

    private var safeElapsed: TimeInterval {
        let elapsed = playbackController.player.currentTime().seconds
        return elapsed.isFinite ? max(0, elapsed) : 0
    }

    private var safeDuration: TimeInterval? {
        guard let duration = playbackController.player.currentItem?.duration.seconds,
              duration.isFinite,
              duration > 0
        else { return nil }
        return duration
    }

    private func formattedDuration(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
