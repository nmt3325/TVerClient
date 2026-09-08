import AVFoundation
import Foundation

/// The transport adapts to the stage's usable space, not the device model.
/// Every compact control still has at least a 44-point touch target.
struct PlayerControlLayout: Equatable {
    let compactTransport: Bool
    let separatesTitle: Bool
    let prioritizesFooter: Bool
    let condensesSupportingText: Bool
    let mergesPrimaryIntoHeader: Bool

    init(availableWidth: CGFloat, availableHeight: CGFloat, isFullScreen: Bool, hasLargeText: Bool = false) {
        prioritizesFooter = availableHeight < 260
        // A very short safe rectangle cannot fit header, transport and footer
        // as three separate rows, even at ordinary text sizes. Consolidate
        // only wide full-screen surfaces; retain semantic fonts and targets.
        let needsShortHeader = isFullScreen && availableWidth >= 480 && availableHeight < 180
        condensesSupportingText = (prioritizesFooter && hasLargeText) || needsShortHeader
        compactTransport = availableHeight < 220 || condensesSupportingText
        separatesTitle = isFullScreen && availableWidth < 500 && availableHeight >= 280
        // Five 44pt utilities plus compact transport and gaps fit in this
        // width. Reuse that row instead of shrinking large time labels.
        mergesPrimaryIntoHeader = isFullScreen && condensesSupportingText && availableWidth >= 480
    }

    var skipDiameter: CGFloat { compactTransport ? 44 : 52 }
    var playDiameter: CGFloat { compactTransport ? 48 : 64 }
    var transportSpacing: CGFloat { compactTransport ? 16 : 24 }
}

/// A failed resolution has no AVPlayerItem: `resume()` alone cannot recover it.
/// A recoverable audio failure, however, keeps its item and must keep its position.
enum PlayerPrimaryAction: Equatable {
    case play, pause, replay, resume, retry, loading, unavailable

    static func resolve(
        state: PlaybackState,
        isPlaying: Bool,
        hasCurrentItem: Bool,
        hasRetryTarget: Bool
    ) -> PlayerPrimaryAction {
        switch state {
        case .resolving:
            return .loading
        case .failed:
            if hasCurrentItem { return .resume }
            return hasRetryTarget ? .retry : .unavailable
        case .ended:
            return hasCurrentItem ? .replay : .unavailable
        case .idle, .playing, .paused:
            guard hasCurrentItem else { return .unavailable }
            return isPlaying ? .pause : .play
        }
    }

    var title: String {
        switch self {
        case .play: return "再生"
        case .pause: return "一時停止"
        case .replay: return "もう一度再生"
        case .resume: return "再開"
        case .retry: return "再試行"
        case .loading: return "読み込み中"
        case .unavailable: return "再生準備中"
        }
    }

    var systemImage: String {
        switch self {
        case .pause: return "pause.fill"
        case .retry, .resume, .replay: return "arrow.clockwise"
        case .loading: return "hourglass"
        case .play, .unavailable: return "play.fill"
        }
    }

    var isEnabled: Bool { self != .loading && self != .unavailable }

    @MainActor
    static func resolve(using controller: PlaybackController) -> PlayerPrimaryAction {
        resolve(
            state: controller.state,
            isPlaying: controller.isPlaying,
            hasCurrentItem: controller.player.currentItem != nil,
            hasRetryTarget: controller.currentProgram != nil || controller.currentLiveChannel != nil
        )
    }

    @MainActor
    func perform(using controller: PlaybackController) async {
        switch self {
        case .retry:
            // Ignore an old menu/button action if playback changed before its task ran.
            guard case .failed = controller.state, controller.player.currentItem == nil else { return }
            if let program = controller.currentProgram {
                await controller.play(program)
            } else if let channel = controller.currentLiveChannel {
                await controller.playLive(channel)
            }
        case .pause:
            guard controller.isPlaying, controller.player.currentItem != nil else { return }
            controller.pause()
        case .play, .resume, .replay:
            controller.resume()
        case .loading, .unavailable:
            break
        }
    }
}
