import SwiftUI
import UIKit

/// Newspaper-style program grid.
///
/// Vertical geometry is driven by `pointsPerMinute`, so pinching recomputes
/// real slot heights instead of magnifying the rendered grid.
///
/// 以前はスクロールのたびに全チャンネル分のセルを作り直していた。いまは
/// レイアウトを（番組表, 放送日, 倍率）が変わったときだけ `GuideColumnLayout` に
/// 畳み込み、キャンバスを `Equatable` にして可視範囲のセルだけを描く。
struct ProgramGuideGrid: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    @Binding var pointsPerMinute: CGFloat
    let scrollToNowToken: Int
    let onSelect: (TVerLiveChannel, TVerLiveProgram, CatchUpAvailability) -> Void

    @EnvironmentObject private var availabilityStore: CatchUpAvailabilityStore
    @State private var contentOffset = CGPoint.zero
    /// 描画に使う倍率。ピンチ中はこちらだけを動かし、指を離したときに
    /// 1回だけ保存先の `pointsPerMinute` へ書き戻す。
    @State private var zoom = GuideZoom.defaultPointsPerMinute
    @State private var columns: [GuideColumnLayout] = []
    @State private var visibleWindow = GuideVisibleWindow.unbounded
    @State private var pinchAnchorMinutes: CGFloat?
    @State private var pinchStartPointsPerMinute = GuideZoom.defaultPointsPerMinute
    @State private var isPinching = false
    @State private var lastPrefetchKey = ""

    private var contentSize: CGSize {
        ProgramGuideMetrics.gridSize(channelCount: guide.count, pointsPerMinute: zoom)
    }

    private var hourHeight: CGFloat {
        GuideZoom.hourHeight(pointsPerMinute: zoom)
    }

    var body: some View {
        GeometryReader { proxy in
            let bodyHeight = max(0, proxy.size.height - ProgramGuideMetrics.stationHeaderHeight)
            let viewportWidth = max(0, proxy.size.width - ProgramGuideMetrics.timeAxisWidth)
            let viewportSize = CGSize(width: viewportWidth, height: bodyHeight)
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
                                columns: columns,
                                window: visibleWindow,
                                availability: visibleAvailability(now: context.date),
                                nowLineY: nowLineY(now: context.date),
                                now: context.date,
                                pointsPerMinute: zoom,
                                contentSize: contentSize,
                                onSelect: { channel, program, state in
                                    handleSelection(
                                        channel: channel,
                                        program: program,
                                        availability: state,
                                        now: context.date
                                    )
                                }
                            )
                            .equatable()
                            .frame(width: contentSize.width, height: contentSize.height)
                        }
                    }
                }
                .onAppear {
                    zoom = GuideZoom.clamp(pointsPerMinute)
                    rebuildLayout()
                    scrollToStartPosition(bodyHeight: bodyHeight)
                    updateVisibleWindow(viewportSize: viewportSize)
                    prefetchVisible(now: context.date, bodyHeight: bodyHeight, viewportWidth: viewportWidth)
                }
                .onChange(of: context.date) { date in
                    prefetchVisible(now: date, bodyHeight: bodyHeight, viewportWidth: viewportWidth)
                }
                .onChange(of: contentOffset) { _ in
                    updateVisibleWindow(viewportSize: viewportSize)
                    prefetchVisible(now: context.date, bodyHeight: bodyHeight, viewportWidth: viewportWidth)
                }
                .onChange(of: guide) { _ in
                    rebuildLayout()
                    updateVisibleWindow(viewportSize: viewportSize)
                }
                .onChange(of: selectedDate) { _ in
                    rebuildLayout()
                    scrollToStartPosition(bodyHeight: bodyHeight)
                    updateVisibleWindow(viewportSize: viewportSize)
                }
                .onChange(of: zoom) { _ in
                    rebuildLayout()
                    updateVisibleWindow(viewportSize: viewportSize)
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

    /// Hour ruler plus the pinned "now" pill. 放送日は5時始まりなので、目盛りは
    /// 05:00〜28:00 を並べる。
    private func timeAxis(now: Date, bodyHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemGroupedBackground)
            ZStack(alignment: .topLeading) {
                ForEach(0 ..< GuideBroadcastAxis.hoursPerDay, id: \.self) { row in
                    Text(GuideBroadcastAxis.hourLabel(forRow: row))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: ProgramGuideMetrics.timeAxisWidth - 8, alignment: .trailing)
                        .offset(y: CGFloat(row) * hourHeight - 7)
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
        if GuideBroadcastAxis.isSameDay(now, selectedDate) {
            let y = GuideBroadcastAxis.yPosition(for: now, on: selectedDate, pointsPerMinute: zoom)
                - contentOffset.y
            if y >= -12, y <= bodyHeight + 12 {
                Text(GuideBroadcastAxis.timeLabel(for: now))
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

    // MARK: - Layout

    private func rebuildLayout() {
        columns = ProgramGuideLayout.columns(
            for: guide,
            on: selectedDate,
            pointsPerMinute: zoom
        )
    }

    private func updateVisibleWindow(viewportSize: CGSize) {
        let window = ProgramGuideLayout.visibleWindow(
            contentOffset: contentOffset,
            viewportSize: viewportSize,
            columnCount: columns.count
        )
        guard window != visibleWindow else { return }
        visibleWindow = window
    }

    /// 見えている枠の見逃し状態だけを値として渡す。クロージャで渡すと
    /// キャンバスの等価判定ができない。
    private func visibleAvailability(now: Date) -> [String: CatchUpAvailability] {
        var result: [String: CatchUpAvailability] = [:]
        for (index, column) in columns.enumerated() where visibleWindow.contains(column: index) {
            for frame in column.frames where visibleWindow.intersects(y: frame.y, maxY: frame.maxY) {
                let key = CatchUpAvailabilityStore.key(
                    channelID: column.channel.id,
                    programID: frame.program.id
                )
                result[key] = availabilityStore.availability(
                    channelID: column.channel.id,
                    program: frame.program,
                    channelState: column.channel.state,
                    now: now
                )
            }
        }
        return result
    }

    /// 現在時刻線の位置。TimelineView が1分ごとに進めるので、開いたまま放置しても動く。
    private func nowLineY(now: Date) -> CGFloat? {
        guard GuideBroadcastAxis.isSameDay(now, selectedDate) else { return nil }
        return GuideBroadcastAxis.yPosition(for: now, on: selectedDate, pointsPerMinute: zoom)
    }

    // MARK: - Zoom

    private func beginPinch(contentY: CGFloat) {
        isPinching = true
        pinchStartPointsPerMinute = zoom
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
        guard abs(target - zoom) > 0.001 else { return }
        zoom = target
        // 指を置いた位置の時刻をそのままにする。横方向は触らないので
        // 見ていたチャンネルもずれない。
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
        guard abs(pointsPerMinute - zoom) > 0.0001 else { return }
        pointsPerMinute = zoom
    }

    /// Keeps the middle of the viewport steady when the zoom is changed from
    /// the toolbar rather than by a pinch.
    private func applyZoomChange(to newValue: CGFloat, bodyHeight: CGFloat) {
        guard !isPinching else { return }
        let previous = zoom
        let updated = GuideZoom.clamp(newValue)
        guard abs(updated - previous) > 0.001 else { return }
        zoom = updated
        guard bodyHeight > 0 else { return }
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
        let day = GuideBroadcastAxis.dayInterval(for: selectedDate)
        // 放送日は5時始まり。今日以外は朝6時あたりから見せる。
        let target = GuideBroadcastAxis.isSameDay(now, selectedDate)
            ? now
            : day.start.addingTimeInterval(3600)
        contentOffset.y = GuideBroadcastAxis.initialOffsetY(
            for: target,
            on: selectedDate,
            viewportHeight: bodyHeight,
            pointsPerMinute: zoom
        )
    }

    private func scrollToNow(bodyHeight: CGFloat) {
        scrollToStartPosition(bodyHeight: bodyHeight)
    }

    // MARK: - Availability

    private func handleSelection(
        channel: TVerLiveChannel,
        program: TVerLiveProgram,
        availability: CatchUpAvailability,
        now: Date
    ) {
        var state = availability
        if case .unknown = state {
            state = availabilityStore.availability(
                channelID: channel.id,
                program: program,
                channelState: channel.state,
                now: now
            )
        }
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
        onSelect(channel, program, state)
    }

    /// Only asks about slots the user can actually see: a whole day of every
    /// channel would be hundreds of requests.
    private func prefetchVisible(now: Date, bodyHeight: CGFloat, viewportWidth: CGFloat) {
        guard bodyHeight > 0, !guide.isEmpty else { return }
        let scale = GuideZoom.clamp(zoom)
        let topMinutes = ProgramGuideMetrics.minutes(atOffsetY: contentOffset.y, pointsPerMinute: scale)
        let visibleMinutes = bodyHeight / scale
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
        let day = GuideBroadcastAxis.dayInterval(for: selectedDate)
        let start = day.start.addingTimeInterval(Double(max(0, topMinutes - 30)) * 60)
        let end = day.start.addingTimeInterval(Double(topMinutes + visibleMinutes + 30) * 60)
        let window = DateInterval(start: start, end: max(start, end))
        for item in guide[firstColumn ..< lastColumn] {
            let programs = GuideBroadcastAxis.programs(
                item.programs,
                on: selectedDate,
                overlapping: window
            )
            availabilityStore.prefetch(channelID: item.channel.id, programs: programs, now: now)
        }
    }
}

/// キャンバスが描く1列。何列目なのかを保ったまま可視分だけ間引くための入れ物。
private struct GuideCanvasColumn: Identifiable {
    let index: Int
    let column: GuideColumnLayout

    var id: String { column.id }
}

/// Absolutely positioned slots for one day, drawn at the current zoom.
///
/// `Equatable` なのは意図的。親はスクロールのたびに body を見直すので、
/// これがないと番組表全体が毎回作り直されてしまう。
struct ProgramGuideCanvas: View, Equatable {
    let columns: [GuideColumnLayout]
    let window: GuideVisibleWindow
    let availability: [String: CatchUpAvailability]
    let nowLineY: CGFloat?
    let now: Date
    let pointsPerMinute: CGFloat
    let contentSize: CGSize
    let onSelect: (TVerLiveChannel, TVerLiveProgram, CatchUpAvailability) -> Void

    static func == (lhs: ProgramGuideCanvas, rhs: ProgramGuideCanvas) -> Bool {
        lhs.pointsPerMinute == rhs.pointsPerMinute
            && lhs.contentSize == rhs.contentSize
            && lhs.nowLineY == rhs.nowLineY
            && lhs.now == rhs.now
            && lhs.window == rhs.window
            && lhs.availability == rhs.availability
            && lhs.columns == rhs.columns
    }

    private var width: CGFloat {
        contentSize.width
    }

    private var height: CGFloat {
        contentSize.height
    }

    private var hourHeight: CGFloat {
        GuideZoom.hourHeight(pointsPerMinute: pointsPerMinute)
    }

    /// Half-hour rules are dropped once they would sit on top of each other.
    private var showsHalfHourLines: Bool {
        hourHeight >= 60
    }

    private var visibleColumns: [GuideCanvasColumn] {
        columns.enumerated().compactMap { index, column in
            window.contains(column: index)
                ? GuideCanvasColumn(index: index, column: column)
                : nil
        }
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
        ForEach(visibleColumns) { entry in
            (entry.index.isMultiple(of: 2)
                ? Color(uiColor: .systemBackground)
                : Color(uiColor: .secondarySystemBackground).opacity(0.45))
                .frame(width: ProgramGuideMetrics.stationWidth, height: height)
                .offset(x: ProgramGuideMetrics.xPosition(forColumn: entry.index))
        }
    }

    private var gridLines: some View {
        let divisions = showsHalfHourLines
            ? GuideBroadcastAxis.hoursPerDay * 2
            : GuideBroadcastAxis.hoursPerDay
        let spacing = height / CGFloat(divisions)
        let rows = (0 ... divisions).filter { index in
            let y = CGFloat(index) * spacing
            return window.intersects(y: y, maxY: y)
        }
        let boundaries = (0 ... columns.count).filter { column in
            window.contains(column: column) || window.contains(column: column - 1)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(rows, id: \.self) { index in
                let isHourLine = !showsHalfHourLines || index.isMultiple(of: 2)
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(isHourLine ? 0.42 : 0.18))
                    .frame(width: width, height: isHourLine ? 1 : 0.5)
                    .offset(y: CGFloat(index) * spacing)
            }
            ForEach(boundaries, id: \.self) { column in
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(0.35))
                    .frame(width: 1, height: height)
                    .offset(x: ProgramGuideMetrics.xPosition(forColumn: column))
            }
        }
        .accessibilityHidden(true)
    }

    private var programs: some View {
        ForEach(visibleColumns) { entry in
            ForEach(visibleFrames(in: entry.column)) { frame in
                let state = state(for: entry.column.channel, program: frame.program)
                ProgramGuideBlock(
                    stationName: entry.column.channel.name,
                    program: frame.program,
                    isOnAir: frame.program.startAt <= now && now < frame.program.endAt,
                    availability: state
                ) {
                    onSelect(entry.column.channel, frame.program, state)
                }
                .frame(width: ProgramGuideMetrics.stationWidth - 6, height: frame.height)
                .offset(
                    x: ProgramGuideMetrics.xPosition(forColumn: entry.index) + 3,
                    y: frame.y
                )
            }
        }
    }

    @ViewBuilder
    private var currentTimeLine: some View {
        if let nowLineY {
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Palette.live).frame(width: width, height: 1)
                Circle().fill(DS.Palette.live).frame(width: 7, height: 7).offset(x: -3)
            }
            .offset(y: nowLineY)
            .accessibilityHidden(true)
        }
    }

    private func visibleFrames(in column: GuideColumnLayout) -> [GuideSlotFrame] {
        column.frames.filter { window.intersects(y: $0.y, maxY: $0.maxY) }
    }

    private func state(
        for channel: TVerLiveChannel,
        program: TVerLiveProgram
    ) -> CatchUpAvailability {
        let key = CatchUpAvailabilityStore.key(channelID: channel.id, programID: program.id)
        return availability[key] ?? .unknown
    }
}

/// One broadcast slot.
struct ProgramGuideBlock: View {
    let stationName: String
    let program: TVerLiveProgram
    let isOnAir: Bool
    let availability: CatchUpAvailability
    let action: () -> Void

    /// 見逃し配信がない終了済みの枠。暗くはするが押せなくはしない。
    /// 以前はセルごと disabled にしていたため、番組詳細も通知予約もできなかった。
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
                            Text(GuideBroadcastAxis.timeRangeLabel(for: program))
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
        }
        .opacity(hasNothingToPlay ? 0.72 : 1)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityInputLabels([program.seriesTitle, program.title])
        .accessibilityAddTraits(isOnAir ? .isSelected : [])
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
