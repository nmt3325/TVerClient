import SwiftUI
import UIKit

/// Native touch owner for the scrubber. This view is deliberately interactive:
/// it sits above the sibling background-tap plane and translates the same
/// recognizer callback used in production into a complete begin/change/end
/// scrub session. It therefore blocks blank-video taps without swallowing the
/// drag that must reach playback.
@MainActor
final class PlaybackScrubberInteractionView: UIView {
    static let accessibilityIdentifier = "playback.hit-target.scrubber"

    private final class CancellationEpoch {
        var value: UInt = 0
    }

    private var elapsed: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var isScrubbingEnabled = false
    private var session: ScrubSession?
    private var sessionDuration: TimeInterval?
    private var startLocation = CGPoint.zero
    private var onScrubStarted: () -> Void = {}
    private var onScrubChanged: (TimeInterval) -> Void = { _ in }
    private var onScrubEnded: (TimeInterval) -> Void = { _ in }
    private var onScrubCancelled: () -> Void = {}
    private let cancellationEpoch = CancellationEpoch()
    private var deferredCancellationTask: Task<Void, Never>?

    private(set) lazy var scrubRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleScrubRecognizer(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        accessibilityIdentifier = Self.accessibilityIdentifier
        addGestureRecognizer(scrubRecognizer)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("PlaybackScrubberInteractionView is created in code only")
    }

    func update(
        elapsed: TimeInterval,
        duration: TimeInterval,
        isEnabled: Bool,
        onScrubStarted: @escaping () -> Void,
        onScrubChanged: @escaping (TimeInterval) -> Void,
        onScrubEnded: @escaping (TimeInterval) -> Void,
        onScrubCancelled: @escaping () -> Void
    ) {
        let nextIsEnabled = isEnabled && duration.isFinite && duration > 0
        let invalidatesCurrentItem = sessionDuration.map {
            abs($0 - duration) > 0.5
        } ?? false

        self.elapsed = elapsed
        self.duration = duration
        isScrubbingEnabled = nextIsEnabled
        self.onScrubStarted = onScrubStarted
        self.onScrubChanged = onScrubChanged
        self.onScrubEnded = onScrubEnded
        self.onScrubCancelled = onScrubCancelled

        if session != nil, !nextIsEnabled || invalidatesCurrentItem {
            // Do not toggle the live recognizer's isEnabled property here.
            // UIKit synchronously emits .cancelled when it is disabled during
            // updateUIView, which can publish back into SwiftUI's transaction.
            cancelActiveScrub()
        }
    }

    @objc func handleScrubRecognizer(_ recognizer: UILongPressGestureRecognizer) {
        handleScrubGesture(
            state: recognizer.state,
            location: recognizer.location(in: self)
        )
    }

    /// The recognizer callback delegates to this state machine verbatim. Hosted
    /// regressions can drive it deterministically without private UITouch APIs.
    func handleScrubGesture(state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began:
            guard isScrubbingEnabled, session == nil, bounds.width > 0 else { return }
            invalidateDeferredCancellation()
            startLocation = location
            var newSession = ScrubSession(startTime: elapsed, duration: duration)
            newSession.jump(toX: location.x, width: bounds.width)
            session = newSession
            sessionDuration = duration
            onScrubStarted()
            impact()
            onScrubChanged(newSession.time)
        case .changed:
            updateSession(at: location)
        case .ended:
            updateSession(at: location)
            finishSession()
        case .cancelled, .failed:
            cancelActiveScrub()
        case .possible:
            break
        @unknown default:
            cancelActiveScrub()
        }
    }

    /// Invalidates ownership synchronously, but publishes controller/model
    /// cleanup on the next MainActor turn so update/dismantle cannot re-enter
    /// an active SwiftUI transaction. Cancellation never commits a stale seek.
    func cancelActiveScrub() {
        guard session != nil else { return }
        session = nil
        sessionDuration = nil
        cancellationEpoch.value &+= 1
        let generation = cancellationEpoch.value
        let epoch = cancellationEpoch
        let cancellation = onScrubCancelled
        deferredCancellationTask?.cancel()
        deferredCancellationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, epoch.value == generation else { return }
            cancellation()
        }
    }

    private func updateSession(at location: CGPoint) {
        guard var session else { return }
        let wasAtEdge = session.isAtEdge
        let speedChanged = session.apply(
            translation: CGSize(
                width: location.x - startLocation.x,
                height: location.y - startLocation.y
            ),
            width: bounds.width
        )
        if speedChanged || (session.isAtEdge && !wasAtEdge) { impact() }
        self.session = session
        onScrubChanged(session.time)
    }

    private func finishSession() {
        guard let session else { return }
        self.session = nil
        sessionDuration = nil
        invalidateDeferredCancellation()
        onScrubEnded(session.time)
    }

    private func invalidateDeferredCancellation() {
        cancellationEpoch.value &+= 1
        deferredCancellationTask?.cancel()
        deferredCancellationTask = nil
    }

    private func impact() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

@MainActor
private struct PlaybackScrubberInteractionSurface: UIViewRepresentable {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let isEnabled: Bool
    let onScrubStarted: () -> Void
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEnded: (TimeInterval) -> Void
    let onScrubCancelled: () -> Void

    func makeUIView(context: Context) -> PlaybackScrubberInteractionView {
        let view = PlaybackScrubberInteractionView()
        configure(view)
        return view
    }

    func updateUIView(_ view: PlaybackScrubberInteractionView, context: Context) {
        configure(view)
    }

    static func dismantleUIView(
        _ view: PlaybackScrubberInteractionView,
        coordinator: Void
    ) {
        view.cancelActiveScrub()
    }

    private func configure(_ view: PlaybackScrubberInteractionView) {
        view.update(
            elapsed: elapsed,
            duration: duration,
            isEnabled: isEnabled,
            onScrubStarted: onScrubStarted,
            onScrubChanged: onScrubChanged,
            onScrubEnded: onScrubEnded,
            onScrubCancelled: onScrubCancelled
        )
    }
}

/// The playback scrubber.
///
/// `Slider` is not usable here: it has no buffered range, no precision
/// scrubbing, a hit area far below 44pt and it reports a continuous stream of
/// values that would seek on every frame. The previous implementation also
/// lived inside `TimelineView(.periodic(by: 1))`, which rebuilt the slider
/// every second and dropped the drag - that is the seek bar bug this control
/// replaces.
///
/// The knob follows the finger through local gesture state and the seek is
/// only committed when the finger lifts.
@MainActor
struct PlaybackScrubber: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    var bufferedFraction: Double = 0
    var isEnabled: Bool = true
    var onScrubStarted: () -> Void = {}
    var onScrubChanged: (TimeInterval) -> Void = { _ in }
    var onScrubEnded: (TimeInterval) -> Void = { _ in }
    var onScrubCancelled: () -> Void = {}
    var onAdjust: (TimeInterval) -> Void = { _ in }

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayTime: TimeInterval { isScrubbing ? scrubTime : elapsed }
    private var trackHeight: CGFloat { isScrubbing ? 8 : 4 }
    private var knobSize: CGFloat { isScrubbing ? 18 : 12 }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = CGFloat(ScrubberMath.fraction(time: displayTime, duration: duration))
            let buffered = CGFloat(min(max(bufferedFraction, 0), 1))

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.24))
                Capsule().fill(Color.white.opacity(0.42))
                    .frame(width: width * buffered)
                Capsule().fill(Color.accentColor)
                    .frame(width: width * progress)
            }
            .frame(height: trackHeight)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobOffset(progress: progress, width: width))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                PlaybackScrubberInteractionSurface(
                    elapsed: elapsed,
                    duration: duration,
                    isEnabled: isEnabled,
                    onScrubStarted: {
                        scrubTime = elapsed
                        isScrubbing = true
                        onScrubStarted()
                    },
                    onScrubChanged: { time in
                        scrubTime = time
                        onScrubChanged(time)
                    },
                    onScrubEnded: { time in
                        scrubTime = time
                        isScrubbing = false
                        onScrubEnded(time)
                    },
                    onScrubCancelled: {
                        isScrubbing = false
                        onScrubCancelled()
                    }
                )
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isScrubbing)
        }
        .frame(height: 44)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel("再生位置")
        .accessibilityValue(ScrubberMath.accessibilityValue(elapsed: displayTime, duration: duration))
        .accessibilityHint("上下に指をずらすと精密に操作できます")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onAdjust(10)
            case .decrement: onAdjust(-10)
            @unknown default: break
            }
        }
    }

    private func knobOffset(progress: CGFloat, width: CGFloat) -> CGFloat {
        guard width > knobSize else { return 0 }
        return min(max(width * progress - knobSize / 2, 0), width - knobSize)
    }
}

#if DEBUG
    #Preview {
        PlaybackScrubber(elapsed: 320, duration: 1_800, bufferedFraction: 0.4)
            .padding()
            .background(Color.black)
    }
#endif
