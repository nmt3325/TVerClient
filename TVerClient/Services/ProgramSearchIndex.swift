import Foundation

struct ProgramSearchEntry: Identifiable, Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        case programGuide
        case videoOnDemand
        case library
    }

    let id: String
    let sourceID: String
    let source: Source
    let stationName: String
    let title: String
    let seriesTitle: String
    let description: String
    let startAt: Date?
    let endAt: Date?
    let isFavorite: Bool

    init(
        id: String,
        sourceID: String? = nil,
        source: Source,
        stationName: String = "",
        title: String,
        seriesTitle: String = "",
        description: String = "",
        startAt: Date? = nil,
        endAt: Date? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID ?? id
        self.source = source
        self.stationName = stationName
        self.title = title
        self.seriesTitle = seriesTitle
        self.description = description
        self.startAt = startAt
        self.endAt = endAt
        self.isFavorite = isFavorite
    }

    func isOnAir(at date: Date) -> Bool {
        guard let startAt, let endAt, startAt < endAt else { return false }
        return startAt <= date && date < endAt
    }
}

enum JapaneseSearchNormalizer {
    static func normalize(_ value: String) -> String {
        let compatible = value.precomposedStringWithCompatibilityMapping
        let katakana = compatible.applyingTransform(.hiraganaToKatakana, reverse: false) ?? compatible
        return katakana
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "ja_JP")
            )
            .lowercased(with: Locale(identifier: "ja_JP"))
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    static func terms(in query: String) -> [String] {
        query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(normalize)
            .filter { !$0.isEmpty }
    }
}

enum ProgramSearchTimeSlot: String, CaseIterable, Hashable, Sendable {
    case all
    case earlyMorning
    case morning
    case daytime
    case evening

    var accessibilityLabel: String {
        switch self {
        case .all: return "すべての時間帯"
        case .earlyMorning: return "深夜と早朝、0時から6時"
        case .morning: return "朝、6時から12時"
        case .daytime: return "昼、12時から18時"
        case .evening: return "夜、18時から24時"
        }
    }

    fileprivate var hourRange: Range<Int>? {
        switch self {
        case .all: return nil
        case .earlyMorning: return 0..<6
        case .morning: return 6..<12
        case .daytime: return 12..<18
        case .evening: return 18..<24
        }
    }
}

struct ProgramSearchFilters: Equatable, Sendable {
    var onlyOnAir = false
    var onlyFavorites = false
    var timeSlot: ProgramSearchTimeSlot = .all

    static let none = ProgramSearchFilters()
}

enum ProgramSearchSort: String, CaseIterable, Sendable {
    case sourceOrder
    case startTime
    case title
}

struct ProgramSearchIndex: Sendable {
    private struct IndexedEntry: Sendable {
        let entry: ProgramSearchEntry
        let normalizedFields: [String]
        let sourceOrder: Int
    }

    private let indexedEntries: [IndexedEntry]

    init(entries: [ProgramSearchEntry]) {
        indexedEntries = entries.enumerated().map { offset, entry in
            IndexedEntry(
                entry: entry,
                normalizedFields: [
                    entry.stationName,
                    entry.title,
                    entry.seriesTitle,
                    entry.description,
                ].map(JapaneseSearchNormalizer.normalize),
                sourceOrder: offset
            )
        }
    }

    var count: Int {
        indexedEntries.count
    }

    func search(
        query: String = "",
        filters: ProgramSearchFilters = .none,
        sort: ProgramSearchSort = .sourceOrder,
        now: Date = Date(),
        calendar: Calendar = ProgramSearchIndex.japaneseCalendar
    ) -> [ProgramSearchEntry] {
        let terms = JapaneseSearchNormalizer.terms(in: query)
        let matches = indexedEntries.filter { indexed in
            terms.allSatisfy { term in
                indexed.normalizedFields.contains { $0.contains(term) }
            }
            && (!filters.onlyOnAir || indexed.entry.isOnAir(at: now))
            && (!filters.onlyFavorites || indexed.entry.isFavorite)
            && matchesTimeSlot(indexed.entry, slot: filters.timeSlot, calendar: calendar)
        }

        return stableSort(matches, by: sort).map(\.entry)
    }

    static func programGuide(
        _ guide: [TVerGuideChannel],
        favoriteProgramIDs: Set<String> = []
    ) -> ProgramSearchIndex {
        ProgramSearchIndex(entries: guide.flatMap { guideChannel in
            guideChannel.programs.map { program in
                ProgramSearchEntry(
                    id: "guide:\(guideChannel.channel.id):\(program.id)",
                    sourceID: program.id,
                    source: .programGuide,
                    stationName: guideChannel.channel.name,
                    title: program.title,
                    seriesTitle: program.seriesTitle,
                    description: program.description,
                    startAt: program.startAt,
                    endAt: program.endAt,
                    isFavorite: favoriteProgramIDs.contains(program.id)
                )
            }
        })
    }

    static func videoOnDemand(
        _ days: [ProgramDay],
        favoriteProgramIDs: Set<String> = []
    ) -> ProgramSearchIndex {
        ProgramSearchIndex(entries: days.flatMap { day in
            day.programs.map { program in
                ProgramSearchEntry(
                    id: "vod:\(program.id)",
                    sourceID: program.id,
                    source: .videoOnDemand,
                    title: program.title,
                    seriesTitle: program.seriesTitle,
                    description: program.description,
                    startAt: day.date,
                    isFavorite: favoriteProgramIDs.contains(program.id)
                )
            }
        })
    }

    static func library(
        _ programs: [TVerProgram],
        favoriteProgramIDs: Set<String>
    ) -> ProgramSearchIndex {
        ProgramSearchIndex(entries: programs.map { program in
            ProgramSearchEntry(
                id: "library:\(program.id)",
                sourceID: program.id,
                source: .library,
                title: program.title,
                seriesTitle: program.seriesTitle,
                description: program.description,
                isFavorite: favoriteProgramIDs.contains(program.id)
            )
        })
    }

    private func stableSort(
        _ entries: [IndexedEntry],
        by sort: ProgramSearchSort
    ) -> [IndexedEntry] {
        entries.sorted { lhs, rhs in
            switch sort {
            case .sourceOrder:
                return lhs.sourceOrder < rhs.sourceOrder
            case .startTime:
                switch (lhs.entry.startAt, rhs.entry.startAt) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.sourceOrder < rhs.sourceOrder
                }
            case .title:
                let comparison = lhs.entry.title.localizedCompare(rhs.entry.title)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return lhs.sourceOrder < rhs.sourceOrder
            }
        }
    }

    private func matchesTimeSlot(
        _ entry: ProgramSearchEntry,
        slot: ProgramSearchTimeSlot,
        calendar: Calendar
    ) -> Bool {
        guard let hours = slot.hourRange else { return true }
        guard let start = entry.startAt, let endAt = entry.endAt, start < endAt else { return false }
        let end = endAt
        let programInterval = DateInterval(start: start, end: end)
        var day = calendar.startOfDay(for: start)
        let finalDay = calendar.startOfDay(for: end)

        while day <= finalDay {
            guard
                let slotStart = calendar.date(byAdding: .hour, value: hours.lowerBound, to: day),
                let slotEnd = calendar.date(byAdding: .hour, value: hours.upperBound, to: day)
            else { return false }

            let overlapStart = max(programInterval.start, slotStart)
            let overlapEnd = min(programInterval.end, slotEnd)
            if overlapStart < overlapEnd { return true }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return false
    }

    static var japaneseCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }
}
