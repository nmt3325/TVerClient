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

/// 番組表のリスト表示。
///
/// 標準の `List` + `Section` + `LabeledContent` で組み、引っぱって更新やスワイプ、
/// 行の押し込みといった OS の作法をそのまま使えるようにしている。
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

    var body: some View {
        ScrollViewReader { proxy in
            let listSections = sections
            List {
                ForEach(listSections) { section in
                    Section {
                        ForEach(section.programs) { program in
                            row(channel: section.channel, program: program)
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
            .onChange(of: scrollToNowToken) { _ in
                guard let target = nowRowID(now: Date()) else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
            }
            .onReceive(tabReselection.events) { tab in
                guard tab == .guide else { return }
                withAnimation { proxy.scrollTo(StandardScrollAnchor.top, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func row(channel: TVerLiveChannel, program: TVerLiveProgram) -> some View {
        let now = Date()
        let isOnAir = program.startAt <= now && now < program.endAt
        let availability = availabilityStore.availability(
            channelID: channel.id,
            program: program,
            channelState: channel.state,
            now: now
        )
        let hasNothingToPlay = GuideAvailabilityPresentation
            .hasNothingToPlay(isOnAir: isOnAir, availability: availability)
        Button {
            onSelect(channel, program, availability)
        } label: {
            LabeledContent {
                // 押すと詳細が開くことを、標準の一覧と同じ形で示す。
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } label: {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Text(GuideBroadcastAxis.timeRangeLabel(for: program))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        if isOnAir {
                            Text("放送中")
                                .font(.subheadline.bold())
                                .foregroundStyle(DS.Palette.live)
                        }
                    }
                    Text(program.seriesTitle)
                        .font(.body)
                    if program.title != program.seriesTitle {
                        Text(program.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let kind = GuideAvailabilityPresentation
                        .badgeKind(isOnAir: isOnAir, availability: availability)
                    {
                        MediaBadge(kind)
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
        // 見逃しが無くても詳細の閲覧と通知予約は使えるので、押せなくしない。
        .opacity(hasNothingToPlay ? 0.72 : 1)
        .onAppear {
            // 見逃しの有無は、行が実際に見えたときだけ問い合わせる。
            availabilityStore.prefetch(channelID: channel.id, programs: [program])
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
            GuideAvailabilityPresentation.accessibilityHint(
                isOnAir: isOnAir,
                availability: availability
            )
        )
        .accessibilityAddTraits(isOnAir ? .isSelected : [])
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

    /// 「今」で戻る先。放送中の枠が無ければ、次に始まる枠に寄せる。
    private func nowRowID(now: Date) -> String? {
        for section in sections {
            let onAir = section.programs.first { $0.startAt <= now && now < $0.endAt }
            let upcoming = section.programs.first { $0.startAt >= now }
            guard let target = onAir ?? upcoming else { continue }
            return ProgramGuideListRowID.make(
                channelID: section.channel.id,
                programID: target.id
            )
        }
        return nil
    }
}

/// 放送日の切り替え。自作の横スクロールチップをやめ、標準の `Picker` に寄せる。
///
/// 日数が少ないうちは `.segmented`、増えたら `.menu` に落として文字を潰さない。
@MainActor
struct ProgramGuideDateSelector: View {
    let dates: [Date]
    @Binding var selectedDate: Date

    /// これを超える日数を segmented に詰めると、1つあたりが 44pt を割る。
    private let segmentedLimit = 4

    var body: some View {
        content
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: ProgramGuideMetrics.minimumTapTarget)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if dates.count > segmentedLimit {
            picker(usesShortLabel: false)
                .pickerStyle(.menu)
        } else if dates.count > 1 {
            picker(usesShortLabel: true)
                .pickerStyle(.segmented)
        } else if let only = dates.first {
            // 選べる日が1日だけなら切り替えを出さず、その日を示すだけにする。
            Text(longLabel(for: only))
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(accessibilityLabel(for: only))
        }
    }

    private func picker(usesShortLabel: Bool) -> some View {
        Picker("放送日", selection: selection) {
            ForEach(dates, id: \.self) { date in
                Text(usesShortLabel ? shortLabel(for: date) : longLabel(for: date))
                    .accessibilityLabel(accessibilityLabel(for: date))
                    .tag(date)
            }
        }
    }

    /// 表示中の日を、必ず選択肢のどれかに寄せて返す。
    private var selection: Binding<Date> {
        Binding(
            get: {
                dates.first { GuideBroadcastAxis.isSameDay($0, selectedDate) } ?? selectedDate
            },
            set: { selectedDate = $0 }
        )
    }

    private func shortLabel(for date: Date) -> String {
        GuideBroadcastAxis.relativeDayLabel(for: date) ?? GuideBroadcastAxis.monthDayLabel(for: date)
    }

    private func longLabel(for date: Date) -> String {
        guard let relative = GuideBroadcastAxis.relativeDayLabel(for: date) else {
            return GuideBroadcastAxis.fullDayLabel(for: date)
        }
        return "\(relative)（\(GuideBroadcastAxis.monthDayLabel(for: date))）"
    }

    private func accessibilityLabel(for date: Date) -> String {
        TVerAccessibilityText.guideDate(
            date,
            relativeLabel: GuideBroadcastAxis.relativeDayLabel(for: date)
                ?? GuideBroadcastAxis.weekdayLabel(for: date)
        )
    }
}
