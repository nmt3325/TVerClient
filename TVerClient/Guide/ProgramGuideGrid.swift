import SwiftUI
import UIKit

/// Newspaper-style program grid.
///
/// Vertical geometry is driven by `pointsPerMinute`, so pinching recomputes
/// real slot heights instead of magnifying the rendered grid.
struct ProgramGuideGrid: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    @Binding var pointsPerMinute: CGFloat
    let scrollToNowToken: Int
    let onSelect: (TVerLiveChannel, TVerLiveProgram) -> Void

    @EnvironmentObject private var availabilityStore: CatchUpAvailabilityStore
    @State private var contentOffset = CGPoint.zero
    @State private var appliedPointsPerMinute = GuideZoom.defaultPointsPerMinute
    @State private var pinchAnchorMinutes: CGFloat?
    @State private var pinchStartPointsPerMinute = GuideZoom.defaultPointsPerMinute
    @State private var isPinching = false
    @State private var lastPrefetchKey = ""

    private var contentSize: CGSize {
        ProgramGuideMetrics.gridSize(channelCount: guide.count, pointsPerMinute: pointsPerMinute)
    }

    private var hourHeight: CGFloat {
        GuideZoom.hourHeight(pointsPerMinute: pointsPerMinute)
    }

    var body: some View {
        GeometryReader { proxy in
            let bodyHeight = max(0, proxy.size.height - ProgramGuideMetrics.stationHeaderHeight)
            let viewportWidth = max(0, proxy.size.width - ProgramGuideMetrics.timeAxisWidth)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("時刻")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: ProgramGuideMetrics.timeAxisWidth, height: ProgramGuideMetrics.stationHeaderHeight)
                            .background(.regularMaterial)
                            .accessibilityAddTraits(.isHeader)
                        stationHeaders
                            .frame(height: ProgramGuideMetrics.stationHeaderHeight)
                    }
                    Divider()
                    HStack(spacing: 0) {
                        timeAxis(now: context.date, bodyHeight: bodyHeight)
                        SynchronizedGuideScrollView(
                            contentOffset: $contentOffset,
                            contentSize: contentSize,
                            onPinchBegan: { contentY, _ in beginPinch(contentY: contentY) },
                            onPinchChanged: { scale, focalY in
                                updatePinch(scale: scale, focalY: focalY, viewportHeight: bodyHeight)
                            },
                            onPinchEnded: endPinch
                        ) {
                            ProgramGuideCanvas(
                                guide: guide,
                                selectedDate: selectedDate,
                                now: context.date,
                                pointsPerMinute: pointsPerMinute,
                                availabilityFor: { channel, program in
                                    availabilityStore.availability(
                                        channelID: channel.id,
                                        program: program,
                                        channelState: channel.state,
                                        now: context.date
                                    )
                                },
                                onSelect: { channel, program in
                                    handleSelection(channel: channel, program: program, now: context.date)
                                }
                            )
                            .frame(width: contentSize.width, height: contentSize.height)
                        }
                    }
                }
                .onAppear {
                    appliedPointsPerMinute = GuideZoom.clamp(pointsPerMinute)
                    scrollToStartPosition(bodyHeight: bodyHeight)
                    prefetchVisible(now: context.date, bodyHeight: bodyHeight, viewportWidth: viewportWidth)
                }
                .onChange(of: context.date) { date in
                    prefetchVisible(now: date, bodyHeight: bodyHeight, viewportWidth: viewportWidth)
                }
                .onChange(of: contentOffset) { _ in
                    prefetchVisible(now: context.date, bodyHeight: bodyHeight, viewportWidth: viewportWidth)
                }
                .onChange(of: pointsPerMinute) { newValue in
                    applyZoomChange(to: newValue, bodyHeight: bodyHeight)
                }
                .onChange(of: scrollToNowToken) { _ in
                    scrollToNow(bodyHeight: bodyHeight)
                }
            }
        }
    }

    private var stationHeaders: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                ForEach(guide) { item in
                    HStack(spacing: DS.Spacing.s) {
                        CachedProgramImage(url: item.channel.iconURL, contentMode: .fit) {
                            Image(systemName: "tv").foregroundStyle(.secondary)
                        }
                        .frame(width: DS.Size.compactIcon, height: DS.Size.compactIcon)
                        .accessibilityHidden(true)
                        Text(item.channel.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: ProgramGuideMetrics.stationWidth, height: ProgramGuideMetrics.stationHeaderHeight)
                    .background(.regularMaterial)
                    .overlay(alignment: .trailing) { Divider() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.channel.name)、放送局")
                    .accessibilityAddTraits(.isHeader)
                }
            }
            .offset(x: -contentOffset.x)
            .frame(width: contentSize.width, alignment: .leading)
        }
        .clipped()
    }

    /// Hour ruler plus the pinned "now" pill.
    private func timeAxis(now: Date, bodyHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemGroupedBackground)
            ZStack(alignment: .topLeading) {
                ForEach(0 ..< 24, id: \.self) { hour in
                    Text(ProgramGuideMetrics.hourLabel(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: ProgramGuideMetrics.timeAxisWidth - 8, alignment: .trailing)
                        .offset(y: CGFloat(hour) * hourHeight - 7)
                }
            }
            .frame(height: contentSize.height, alignment: .top)
            .offset(y: -contentOffset.y)
            currentTimePill(now: now, bodyHeight: bodyHeight)
        }
        .frame(width: ProgramGuideMetrics.timeAxisWidth, height: bodyHeight, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func currentTimePill(now: Date, bodyHeight: CGFloat) -> some View {
        if ProgramGuideMetrics.isSameDay(now, selectedDate) {
            let y = ProgramGuideMetrics.yPosition(for: now, on: selectedDate, pointsPerMinute: pointsPerMinute)
                - contentOffset.y
            if y >= -12, y <= bodyHeight + 12 {
                Text(now, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, 1)
                    .background(DS.Palette.live, in: Capsule())
                    .frame(width: ProgramGuideMetrics.timeAxisWidth - 6, alignment: .trailing)
                    .offset(y: y - 8)
            }
        }
    }

    // MARK: - Zoom

    private func beginPinch(contentY: CGFloat) {
        isPinching = true
        pinchStartPointsPerMinute = GuideZoom.clamp(pointsPerMinute)
        pinchAnchorMinutes = ProgramGuideMetrics.minutes(
            atOffsetY: contentY,
            pointsPerMinute: pinchStartPointsPerMinute
        )
    }

    private func updatePinch(scale: CGFloat, focalY: CGFloat, viewportHeight: CGFloat) {
        guard isPinching, let anchorMinutes = pinchAnchorMinutes else { return }
        // Quantised so a continuous gesture does not re-lay out the whole grid
        // for every pixel the fingers travel.
        let target = GuideZoom.clamp(((pinchStartPointsPerMinute * scale) / 0.02).rounded() * 0.02)
        guard abs(target - appliedPointsPerMinute) > 0.001 else { return }
        appliedPointsPerMinute = target
        pointsPerMinute = target
        contentOffset.y = ProgramGuideMetrics.anchoredOffsetY(
            anchorMinutes: anchorMinutes,
            focalY: focalY,
            pointsPerMinute: target,
            viewportHeight: viewportHeight
        )
    }

    private func endPinch() {
        isPinching = false
        pinchAnchorMinutes = nil
    }

    /// Keeps the middle of the viewport steady when the zoom is changed from
    /// the toolbar rather than by a pinch.
    private func applyZoomChange(to newValue: CGFloat, bodyHeight: CGFloat) {
        guard !isPinching else { return }
        let previous = appliedPointsPerMinute
        let updated = GuideZoom.clamp(newValue)
        appliedPointsPerMinute = updated
        guard bodyHeight > 0, abs(updated - previous) > 0.001 else { return }
        let focalY = bodyHeight / 2
        let anchorMinutes = ProgramGuideMetrics.minutes(
            atOffsetY: contentOffset.y + focalY,
            pointsPerMinute: previous
        )
        contentOffset.y = ProgramGuideMetrics.anchoredOffsetY(
            anchorMinutes: anchorMinutes,
            focalY: focalY,
            pointsPerMinute: updated,
            viewportHeight: bodyHeight
        )
    }

    // MARK: - Scrolling

    private func scrollToStartPosition(bodyHeight: CGFloat) {
        let now = Date()
        let target = ProgramGuideMetrics.isSameDay(now, selectedDate)
            ? now
            : ProgramGuideMetrics.calendar.date(bySettingHour: 6, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        contentOffset.y = ProgramGuideMetrics.initialOffsetY(
            for: target,
            on: selectedDate,
            viewportHeight: bodyHeight,
            pointsPerMinute: pointsPerMinute
        )
    }

    private func scrollToNow(bodyHeight: CGFloat) {
        scrollToStartPosition(bodyHeight: bodyHeight)
    }

    // MARK: - Availability

    private func handleSelection(channel: TVerLiveChannel, program: TVerLiveProgram, now: Date) {
        let state = availabilityStore.availability(
            channelID: channel.id,
            program: program,
            channelState: channel.state,
            now: now
        )
        // The slot was never checked, so ask now: the badge turns into a
        // spinner while the sheet opens and settles on 見逃し / 見逃しなし.
        if case .unknown = state {
            Task {
                await availabilityStore.resolve(
                    channelID: channel.id,
                    program: program,
                    channelState: channel.state
                )
            }
        }
        onSelect(channel, program)
    }

    /// Only asks about slots the user can actually see: a whole day of every
    /// channel would be hundreds of requests.
    private func prefetchVisible(now: Date, bodyHeight: CGFloat, viewportWidth: CGFloat) {
        guard bodyHeight > 0, !guide.isEmpty else { return }
        let zoom = GuideZoom.clamp(pointsPerMinute)
        let topMinutes = ProgramGuideMetrics.minutes(atOffsetY: contentOffset.y, pointsPerMinute: zoom)
        let visibleMinutes = bodyHeight / zoom
        let firstColumn = max(0, Int(contentOffset.x / ProgramGuideMetrics.stationWidth))
        let columnCount = max(1, Int((viewportWidth / ProgramGuideMetrics.stationWidth).rounded(.up)) + 1)
        let lastColumn = min(guide.count, firstColumn + columnCount)
        guard firstColumn < lastColumn else { return }

        let key = [
            String(Int(topMinutes / 30)),
            String(Int(visibleMinutes / 30)),
            String(firstColumn),
            String(lastColumn),
            String(Int(now.timeIntervalSinceReferenceDate / 300)),
            String(Int(selectedDate.timeIntervalSinceReferenceDate)),
        ].joined(separator: "|")
        guard key != lastPrefetchKey else { return }
        lastPrefetchKey = key

        // A little slack above and below, so a short scroll does not have to
        // wait for a fresh round of lookups.
        let day = ProgramGuideMetrics.dayInterval(for: selectedDate)
        let start = day.start.addingTimeInterval(Double(max(0, topMinutes - 30)) * 60)
        let end = day.start.addingTimeInterval(Double(topMinutes + visibleMinutes + 30) * 60)
        let window = DateInterval(start: start, end: max(start, end))
        for item in guide[firstColumn ..< lastColumn] {
            let programs = ProgramGuideMetrics.programs(
                item.programs,
                on: selectedDate,
                overlapping: window
            )
            availabilityStore.prefetch(channelID: item.channel.id, programs: programs, now: now)
        }
    }
}

/// Absolutely positioned slots for one day, drawn at the current zoom.
struct ProgramGuideCanvas: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    let now: Date
    let pointsPerMinute: CGFloat
    let availabilityFor: (TVerLiveChannel, TVerLiveProgram) -> CatchUpAvailability
    let onSelect: (TVerLiveChannel, TVerLiveProgram) -> Void

    private var width: CGFloat {
        CGFloat(guide.count) * ProgramGuideMetrics.stationWidth
    }

    private var height: CGFloat {
        ProgramGuideMetrics.dayHeight(pointsPerMinute: pointsPerMinute)
    }

    private var hourHeight: CGFloat {
        GuideZoom.hourHeight(pointsPerMinute: pointsPerMinute)
    }

    /// Half-hour rules are dropped once they would sit on top of each other.
    private var showsHalfHourLines: Bool {
        hourHeight >= 60
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)
            columnBackgrounds
            gridLines
            programs
            currentTimeLine
        }
        .frame(width: width, height: height)
    }

    private var columnBackgrounds: some View {
        HStack(spacing: 0) {
            ForEach(Array(guide.enumerated()), id: \.element.id) { index, _ in
                (index.isMultiple(of: 2)
                    ? Color(uiColor: .systemBackground)
                    : Color(uiColor: .secondarySystemBackground).opacity(0.45))
                    .frame(width: ProgramGuideMetrics.stationWidth, height: height)
            }
        }
    }

    private var gridLines: some View {
        let divisions = showsHalfHourLines ? 48 : 24
        let spacing = height / CGFloat(divisions)
        return ZStack(alignment: .topLeading) {
            ForEach(0 ... divisions, id: \.self) { index in
                let isHourLine = !showsHalfHourLines || index.isMultiple(of: 2)
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(isHourLine ? 0.42 : 0.18))
                    .frame(width: width, height: isHourLine ? 1 : 0.5)
                    .offset(y: CGFloat(index) * spacing)
            }
            ForEach(0 ... guide.count, id: \.self) { column in
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(0.35))
                    .frame(width: 1, height: height)
                    .offset(x: ProgramGuideMetrics.xPosition(forColumn: column))
            }
        }
        .accessibilityHidden(true)
    }

    private var programs: some View {
        ForEach(Array(guide.enumerated()), id: \.element.id) { column, item in
            ForEach(ProgramGuideMetrics.programs(item.programs, on: selectedDate)) { program in
                let y = ProgramGuideMetrics.yPosition(
                    for: program.startAt,
                    on: selectedDate,
                    pointsPerMinute: pointsPerMinute
                )
                let programHeight = ProgramGuideMetrics.height(
                    for: program,
                    on: selectedDate,
                    pointsPerMinute: pointsPerMinute
                )
                ProgramGuideBlock(
                    stationName: item.channel.name,
                    program: program,
                    isOnAir: program.startAt <= now && now < program.endAt,
                    availability: availabilityFor(item.channel, program)
                ) {
                    onSelect(item.channel, program)
                }
                .frame(width: ProgramGuideMetrics.stationWidth - 6, height: programHeight)
                .offset(
                    x: ProgramGuideMetrics.xPosition(forColumn: column) + 3,
                    y: y
                )
            }
        }
    }

    @ViewBuilder
    private var currentTimeLine: some View {
        if ProgramGuideMetrics.isSameDay(now, selectedDate) {
            let y = ProgramGuideMetrics.yPosition(for: now, on: selectedDate, pointsPerMinute: pointsPerMinute)
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Palette.live).frame(width: width, height: 1)
                Circle().fill(DS.Palette.live).frame(width: 7, height: 7).offset(x: -3)
            }
            .offset(y: y)
            .accessibilityHidden(true)
        }
    }
}

/// One broadcast slot.
struct ProgramGuideBlock: View {
    let stationName: String
    let program: TVerLiveProgram
    let isOnAir: Bool
    let availability: CatchUpAvailability
    let action: () -> Void

    /// A finished slot with nothing behind it is dimmed and inert: finding
    /// that out only after tapping play was the complaint.
    private var hasNothingToPlay: Bool {
        GuideAvailabilityPresentation.hasNothingToPlay(isOnAir: isOnAir, availability: availability)
    }

    private var badgeKind: MediaBadgeKind? {
        GuideAvailabilityPresentation.badgeKind(isOnAir: isOnAir, availability: availability)
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let isCompact = height < ProgramGuideMetrics.minimumTapTarget
            Button(action: action) {
                VStack(alignment: .leading, spacing: height < 62 ? 1 : 3) {
                    if !isCompact {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(program.timeLabel)
                                .font(.caption2.monospacedDigit().weight(.semibold))
                            if isOnAir {
                                Text("放送中")
                                    .font(.caption2.bold())
                                    .foregroundStyle(DS.Palette.live)
                            }
                        }
                        .lineLimit(1)
                    }
                    Text(program.seriesTitle)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(titleLineLimit(height: height))
                    if height >= 76, program.title != program.seriesTitle {
                        Text(program.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(height >= 112 ? 2 : 1)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, isCompact ? 2 : 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(blockBackground)
                .overlay(alignment: .bottomTrailing) {
                    badge(height: height, width: proxy.size.width)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .stroke(borderColor, lineWidth: isOnAir ? 2 : 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hasNothingToPlay)
        }
        .opacity(hasNothingToPlay ? 0.45 : 1)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityInputLabels([program.seriesTitle, program.title])
        .accessibilityAddTraits(isOnAir ? .isSelected : [])
        .accessibilityRemoveTraits(hasNothingToPlay ? .isButton : [])
    }

    @ViewBuilder
    private func badge(height: CGFloat, width: CGFloat) -> some View {
        if let badgeKind {
            Group {
                if height >= 52, width >= 118 {
                    MediaBadge(badgeKind)
                } else {
                    Image(systemName: badgeKind.systemImage)
                        .imageScale(.small)
                        .foregroundStyle(badgeKind.tint)
                }
            }
            .padding(DS.Spacing.xxs)
            .accessibilityHidden(true)
        }
    }

    /// Below the tap-target height only the title fits.
    private func titleLineLimit(height: CGFloat) -> Int {
        if height < ProgramGuideMetrics.minimumTapTarget { return 1 }
        return height < 76 ? 1 : 2
    }

    private var blockBackground: Color {
        if program.isPause {
            return Color(uiColor: .tertiarySystemFill)
        }
        if isOnAir {
            return DS.Palette.live.opacity(0.1)
        }
        return Color(uiColor: .secondarySystemBackground)
    }

    private var borderColor: Color {
        if isOnAir { return DS.Palette.live }
        if case .available = availability { return DS.Palette.catchUp.opacity(0.55) }
        return Color(uiColor: .separator).opacity(0.42)
    }

    private var accessibilityLabel: String {
        GuideAvailabilityPresentation.accessibilityLabel(
            base: TVerAccessibilityText.guideProgram(
                stationName: stationName,
                program: program,
                isOnAir: isOnAir
            ),
            isOnAir: isOnAir,
            availability: availability
        )
    }

    private var accessibilityHint: String {
        GuideAvailabilityPresentation.accessibilityHint(isOnAir: isOnAir, availability: availability)
    }
}

/// Scroll view that mirrors its offset into SwiftUI and owns the pinch
/// gesture the grid zooms with. `MagnifyGesture` is iOS 17 only, so the
/// recogniser lives here where iOS 16 can use it too.
struct SynchronizedGuideScrollView<Content: View>: UIViewRepresentable {
    @Binding var contentOffset: CGPoint
    let contentSize: CGSize
    var onPinchBegan: ((CGFloat, CGFloat) -> Void)?
    var onPinchChanged: ((CGFloat, CGFloat) -> Void)?
    var onPinchEnded: (() -> Void)?
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceHorizontal = contentSize.width > 0
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.isDirectionalLockEnabled = false

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(pinch)

        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.addSubview(hostedView)
        scrollView.contentSize = contentSize
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.hostingController.rootView = content
        context.coordinator.hostingController.view.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize

        // While pinching, the offset is driven by the zoom anchor and has to be
        // applied even though the scroll view still counts as dragging.
        let isUserScrolling = scrollView.isDragging || scrollView.isDecelerating
        guard context.coordinator.isPinching || !isUserScrolling else { return }
        let target = clampedOffset(contentOffset, in: scrollView)
        if abs(scrollView.contentOffset.x - target.x) > 0.5
            || abs(scrollView.contentOffset.y - target.y) > 0.5
        {
            scrollView.setContentOffset(target, animated: false)
        }
    }

    private func clampedOffset(_ offset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
        CGPoint(
            x: min(max(0, offset.x), max(0, contentSize.width - scrollView.bounds.width)),
            y: min(max(0, offset.y), max(0, contentSize.height - scrollView.bounds.height))
        )
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: SynchronizedGuideScrollView
        let hostingController: UIHostingController<Content>
        private(set) var isPinching = false

        init(parent: SynchronizedGuideScrollView) {
            self.parent = parent
            hostingController = UIHostingController(rootView: parent.content)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isPinching else { return }
            guard parent.contentOffset != scrollView.contentOffset else { return }
            parent.contentOffset = scrollView.contentOffset
        }

        @objc
        func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            let contentY = gesture.location(in: scrollView).y
            let focalY = contentY - scrollView.contentOffset.y
            switch gesture.state {
            case .began:
                isPinching = true
                // Two-finger panning fights the zoom anchor, so the pan is
                // parked for the length of the pinch.
                scrollView.panGestureRecognizer.isEnabled = false
                parent.onPinchBegan?(contentY, focalY)
            case .changed:
                guard isPinching else { return }
                parent.onPinchChanged?(gesture.scale, focalY)
            case .ended, .cancelled, .failed:
                guard isPinching else { return }
                isPinching = false
                scrollView.panGestureRecognizer.isEnabled = true
                parent.onPinchEnded?()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
