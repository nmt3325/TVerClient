import Combine
import SwiftUI

/// 番組表の表示方法。既定はリスト。
///
/// 格子は一覧性が高い代わりに、密度を下げると1枠が 44pt を割り、指では狙えない。
/// そこで標準の `List` に寄せた縦一列を既定にし、格子は選んだときだけ出す。
enum GuideLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case list
    case grid

    var id: String { rawValue }

    /// 表示切り替えに出す名前。
    var title: String {
        switch self {
        case .list: return "リスト"
        case .grid: return "番組表"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.3x3"
        }
    }
}

/// 保存された選択と、リストを強制する条件から、実際に出す表示方法を決める。
enum GuideLayoutModeResolver {
    /// - Parameters:
    ///   - stored: 利用者が選んで永続した表示方法。未設定なら空文字。
    ///   - usesAccessibleList: 読み上げ中や特大文字など、格子が成立しない状態か。
    static func resolve(stored: String, usesAccessibleList: Bool) -> GuideLayoutMode {
        if usesAccessibleList {
            // 読み上げ順と当たり判定が壊れるので、保存された選択より優先してリストにする。
            return .list
        }
        return GuideLayoutMode(rawValue: stored) ?? .list
    }
}

/// リストのスクロール先 ID。番組 ID は局をまたぐと重複しうるので局 ID と組む。
enum ProgramGuideListRowID {
    static func make(channelID: String, programID: String) -> String {
        "guide.row.\(channelID).\(programID)"
    }

    static func section(channelID: String) -> String {
        "guide.section.\(channelID)"
    }
}

/// リスト1局ぶん。`List` の `Section` と1対1で対応する。
struct ProgramGuideListSection: Identifiable {
    let channel: TVerLiveChannel
    let programs: [TVerLiveProgram]

    var id: String { channel.id }
}

/// A later channel's current show takes precedence over an earlier channel's future show.
enum ProgramGuideListNavigation {
    static func nowRowID(in sections: [ProgramGuideListSection], now: Date) -> String? {
        for section in sections {
            if let program = section.programs.first(where: {
                !$0.isPause && $0.startAt <= now && now < $0.endAt
            }) {
                return ProgramGuideListRowID.make(channelID: section.channel.id, programID: program.id)
            }
        }
        let upcoming = sections.compactMap { section -> (String, TVerLiveProgram)? in
            guard let program = section.programs.filter({ !$0.isPause && $0.startAt >= now })
                .min(by: { $0.startAt < $1.startAt }) else { return nil }
            return (section.channel.id, program)
        }.min { $0.1.startAt < $1.1.startAt }
        if let (channelID, program) = upcoming {
            return ProgramGuideListRowID.make(channelID: channelID, programID: program.id)
        }
        // If every station is paused, still move to the current slot without labeling it playable.
        for section in sections {
            if let program = section.programs.first(where: { $0.startAt <= now && now < $0.endAt }) {
                return ProgramGuideListRowID.make(channelID: section.channel.id, programID: program.id)
            }
        }
        return nil
    }
}

/// Returning from a detail sheet must not reset the list to the live edge.
struct ProgramGuideInitialPosition {
    private(set) var positionedDate: Date?

    mutating func target(in sections: [ProgramGuideListSection], on selectedDate: Date, now: Date) -> String? {
        guard !sections.isEmpty, positionedDate != selectedDate else { return nil }
        positionedDate = selectedDate
        guard GuideBroadcastAxis.isSameDay(selectedDate, now) else { return nil }
        return ProgramGuideListNavigation.nowRowID(in: sections, now: now)
    }
}

/// Visible identity belongs to every row, not only to a section header that
/// scrollTo(..., anchor: .top) can legitimately move off-screen.
struct ProgramGuideListRowMetadata: Equatable {
    let stationName: String
    let timeRange: String

    init(channel: TVerLiveChannel, program: TVerLiveProgram) {
        stationName = channel.name
        timeRange = GuideBroadcastAxis.timeRangeLabel(for: program)
    }
}

/// 番組表のリスト表示。標準の List で番組を読み、引っぱって更新する。
@MainActor
struct ProgramGuideProgramList: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    /// 「今」を押した回数。増えたら現在の枠へスクロールする。
    let scrollToNowToken: Int
    let onSelect: (TVerLiveChannel, TVerLiveProgram, CatchUpAvailability) -> Void
    let onRefresh: () async -> Void

    @EnvironmentObject private var availabilityStore: CatchUpAvailabilityStore
    @EnvironmentObject private var tabReselection: TabReselection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var initialPosition = ProgramGuideInitialPosition()

    var body: some View {
        ScrollViewReader { proxy in
            let listSections = sections
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List {
                    ForEach(listSections) { section in
                        Section {
                            ForEach(section.programs) { program in
                                row(channel: section.channel, program: program, now: context.date)
                                    .id(ProgramGuideListRowID.make(
                                        channelID: section.channel.id,
                                        programID: program.id
                                    ))
                            }
                        } header: {
                            Text(section.channel.name)
                                .id(section.id == listSections.first?.id
                                    ? StandardScrollAnchor.top
                                    : ProgramGuideListRowID.section(channelID: section.channel.id))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await onRefresh() }
                .task(id: selectedDate) {
                    // Let List install its rows before asking ScrollViewReader for their IDs.
                    await Task.yield()
                    guard !Task.isCancelled,
                          let target = initialPosition.target(in: listSections, on: selectedDate, now: Date())
                    else { return }
                    proxy.scrollTo(target, anchor: .top)
                }
                .onChange(of: scrollToNowToken) { _ in
                    guard let target = ProgramGuideListNavigation.nowRowID(in: listSections, now: Date()) else { return }
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(target, anchor: .top) }
                }
                .onReceive(tabReselection.events) { tab in
                    guard tab == .guide else { return }
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(StandardScrollAnchor.top, anchor: .top) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(channel: TVerLiveChannel, program: TVerLiveProgram, now: Date) -> some View {
        let isOnAir = GuideProgramTimeStatus.isOnAir(program, now: now)
        let availability = availabilityStore.availability(
            channelID: channel.id,
            program: program,
            channelState: channel.state,
            now: now
        )
        let badge = GuideAvailabilityPresentation.badgeKind(isOnAir: isOnAir, availability: availability)
        let metadata = ProgramGuideListRowMetadata(channel: channel, program: program)
        Button {
            onSelect(channel, program, availability)
        } label: {
            LabeledContent {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } label: {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    // Keep the full station name near the time even when the
                    // section header is off-screen. A separate line also fits AX5.
                    Text(metadata.stationName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Spacing.s) {
                            timeLabel(metadata.timeRange)
                            if let badge { MediaBadge(badge) }
                        }
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            timeLabel(metadata.timeRange)
                            if let badge { MediaBadge(badge) }
                        }
                    }
                    Text(program.seriesTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    if program.title != program.seriesTitle {
                        Text(program.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(minHeight: ProgramGuideMetrics.minimumTapTarget)
        // A no-catch-up badge is enough; fading the whole row made its title harder to read.
        .onAppear { availabilityStore.prefetch(channelID: channel.id, programs: [program]) }
        .onChange(of: isOnAir) { onAir in
            if !onAir { availabilityStore.prefetch(channelID: channel.id, programs: [program]) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            GuideAvailabilityPresentation.accessibilityLabel(
                base: TVerAccessibilityText.guideProgram(
                    stationName: channel.name,
                    program: program,
                    isOnAir: isOnAir
                ),
                isOnAir: isOnAir,
                availability: availability
            )
        )
        .accessibilityHint(
            GuideAvailabilityPresentation.accessibilityHint(isOnAir: isOnAir, availability: availability)
        )
        .accessibilityAddTraits(isOnAir ? .isSelected : [])
    }

    private func timeLabel(_ timeRange: String) -> some View {
        Text(timeRange)
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 選択中の日に番組がある局だけを、放送順に並べて返す。
    private var sections: [ProgramGuideListSection] {
        guide.compactMap { item -> ProgramGuideListSection? in
            let programs = GuideBroadcastAxis.programs(item.programs, on: selectedDate)
                .sorted { $0.startAt < $1.startAt }
            guard !programs.isEmpty else { return nil }
            return ProgramGuideListSection(channel: item.channel, programs: programs)
        }
    }

}

/// Date, adjacent-day navigation and the live edge stay together without covering any rows.
@MainActor
struct ProgramGuideDateSelector: View {
    let dates: [Date]
    @Binding var selectedDate: Date
    var onJumpToNow: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: DS.Spacing.xs) {
                    dateControls
                    nowButton
                }
            } else {
                HStack(spacing: DS.Spacing.s) {
                    dateControls
                    nowButton
                }
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private var dateControls: some View {
        HStack(spacing: DS.Spacing.xs) {
            if dates.count > 1 { dayButton(direction: -1) }
            if dates.count > 1 {
                Menu {
                    Picker("放送日", selection: selection) {
                        ForEach(dates, id: \.self) { date in
                            Text(longLabel(for: date))
                                .accessibilityLabel(accessibilityLabel(for: date))
                                .tag(date)
                        }
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(longLabel(for: selection.wrappedValue))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: ProgramGuideMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("放送日")
                .accessibilityValue(accessibilityLabel(for: selection.wrappedValue))
                .accessibilityHint("放送日を選びます。1日は朝5時から翌朝5時までです")
            } else if let only = dates.first {
                Text(longLabel(for: only))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: ProgramGuideMetrics.minimumTapTarget, alignment: .leading)
                    .accessibilityLabel(accessibilityLabel(for: only))
            }
            if dates.count > 1 { dayButton(direction: 1) }
        }
    }

    private func dayButton(direction: Int) -> some View {
        let target = GuideDayNavigation.adjacentDate(in: dates, to: selection.wrappedValue, direction: direction)
        return Button {
            if let target { selectedDate = target }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.subheadline.weight(.semibold))
                .frame(width: ProgramGuideMetrics.minimumTapTarget, height: ProgramGuideMetrics.minimumTapTarget)
        }
        .disabled(target == nil)
        .accessibilityLabel(direction < 0 ? "前の放送日" : "次の放送日")
    }

    @ViewBuilder
    private var nowButton: some View {
        if let onJumpToNow {
            Button(action: onJumpToNow) {
                Text("現在")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: ProgramGuideMetrics.minimumTapTarget, minHeight: ProgramGuideMetrics.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("現在時刻に戻る")
            .accessibilityHint("今日の放送中または次の番組へ移動します")
        }
    }

    private var selection: Binding<Date> {
        Binding(
            get: { dates.first { GuideBroadcastAxis.isSameDay($0, selectedDate) } ?? dates.first ?? selectedDate },
            set: { selectedDate = $0 }
        )
    }

    private func longLabel(for date: Date) -> String {
        let day = GuideBroadcastAxis.monthDayLabel(for: date)
        if let relative = GuideBroadcastAxis.relativeDayLabel(for: date) { return "\(relative) \(day)" }
        return "\(day)（\(GuideBroadcastAxis.weekdayLabel(for: date))）"
    }

    private func accessibilityLabel(for date: Date) -> String {
        TVerAccessibilityText.guideDate(
            date,
            relativeLabel: GuideBroadcastAxis.relativeDayLabel(for: date) ?? GuideBroadcastAxis.weekdayLabel(for: date)
        )
    }
}
