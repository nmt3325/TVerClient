import SwiftUI
import UIKit

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
    var onAdjust: (TimeInterval) -> Void = { _ in }

    @GestureState private var isTouching = false
    @State private var session: ScrubSession?
    @State private var scrubTime: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isScrubbing: Bool { session != nil }
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
            .gesture(drag(width: width), including: isEnabled ? .all : .subviews)
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
        .onChange(of: isTouching) { touching in
            guard !touching, let session else { return }
            finish(session)
        }
    }

    private func knobOffset(progress: CGFloat, width: CGFloat) -> CGFloat {
        guard width > knobSize else { return 0 }
        return min(max(width * progress - knobSize / 2, 0), width - knobSize)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                guard isEnabled, duration > 0 else { return }
                var current: ScrubSession
                if let session {
                    current = session
                } else {
                    current = ScrubSession(startTime: elapsed, duration: duration)
                    current.jump(toX: value.startLocation.x, width: width)
                    onScrubStarted()
                    impact()
                }
                let wasAtEdge = current.isAtEdge
                let speedChanged = current.apply(translation: value.translation, width: width)
                if speedChanged || (current.isAtEdge && !wasAtEdge) { impact() }
                session = current
                scrubTime = current.time
                onScrubChanged(current.time)
            }
            .onEnded { _ in
                guard let session else { return }
                finish(session)
            }
    }

    private func finish(_ session: ScrubSession) {
        self.session = nil
        scrubTime = session.time
        onScrubEnded(session.time)
    }

    private func impact() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

#if DEBUG
    #Preview {
        PlaybackScrubber(elapsed: 320, duration: 1_800, bufferedFraction: 0.4)
            .padding()
            .background(Color.black)
    }
#endif
