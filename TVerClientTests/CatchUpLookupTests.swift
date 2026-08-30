import Foundation
@testable import TVerClient
import XCTest

/// Network-free coverage for the catch-up (見逃し配信) episode matcher.
///
/// Programme-guide titles carry broadcaster decorations (【無料】, [字], (再), …) that the
/// VOD catalogue does not use, so guide entries can only be matched after normalisation.
final class CatchUpLookupTests: XCTestCase {
    // MARK: - Normalisation

    func testNormalizerStripsBroadcasterDecorations() {
        let decorated = CatchUpTitleNormalizer.normalize("【無料】アメトーーク！[字]（再）")
        XCTAssertEqual(decorated, CatchUpTitleNormalizer.normalize("アメトーーク"))
        XCTAssertFalse(decorated.isEmpty)
    }

    func testNormalizerTreatsWidthAndCaseAsEquivalent() {
        XCTAssertEqual(
            CatchUpTitleNormalizer.normalize("ＶＩＶＡＮＴ"),
            CatchUpTitleNormalizer.normalize("vivant")
        )
    }

    func testNormalizerKeepsMeaningfulBracketContent() {
        // "(再)" is noise, "(第1話)" is not.
        XCTAssertTrue(CatchUpTitleNormalizer.normalize("ドラマ（第1話）").contains("1"))
    }

    func testSearchKeywordsDropDecorationsButStayHumanReadable() {
        let keywords = CatchUpMatcher.searchKeywords(
            seriesTitle: "【無料】VIVANT[字]",
            title: "第1話"
        )
        XCTAssertEqual(keywords.first, "VIVANT")
        XCTAssertTrue(keywords.contains("第1話"))
    }

    func testSearchKeywordsDeduplicate() {
        let keywords = CatchUpMatcher.searchKeywords(seriesTitle: "VIVANT", title: "VIVANT")
        XCTAssertEqual(keywords, ["VIVANT"])
    }

    // MARK: - Broadcast date parsing

    func testBroadcastDayParsesJapaneseLabel() {
        let parsed = CatchUpMatcher.broadcastDay(from: "8月27日(木)放送分")
        XCTAssertEqual(parsed?.month, 8)
        XCTAssertEqual(parsed?.day, 27)
        XCTAssertNil(CatchUpMatcher.broadcastDay(from: ""))
    }

    // MARK: - Matching

    func testMatchesDecoratedGuideTitleToCatalogueEpisode() {
        let match = CatchUpMatcher.bestMatch(
            among: [Self.ametalk, Self.unrelated],
            seriesTitle: "【無料】アメトーーク！[字]",
            episodeTitle: "東京吉本芸人の実情",
            broadcastDate: Self.jstDate(month: 8, day: 27)
        )
        XCTAssertEqual(match?.id, "ep3dxmhg0g")
    }

    func testPrefersEpisodeBroadcastOnTheGuideDay() {
        let older = CatchUpEpisodeCandidate(
            id: "old", seriesID: "sr542nxzof", title: "前回の放送",
            seriesTitle: "アメトーーク！", broadcastDateLabel: "8月20日(木)放送分", endAt: 9_999_999_999
        )
        let match = CatchUpMatcher.bestMatch(
            among: [older, Self.ametalk],
            seriesTitle: "アメトーーク！",
            episodeTitle: "アメトーーク！",
            broadcastDate: Self.jstDate(month: 8, day: 27)
        )
        XCTAssertEqual(match?.id, "ep3dxmhg0g", "The same-day broadcast must win")
    }

    func testRejectsUnrelatedSeries() {
        XCTAssertNil(
            CatchUpMatcher.bestMatch(
                among: [Self.unrelated],
                seriesTitle: "アメトーーク！",
                episodeTitle: "東京吉本芸人の実情",
                broadcastDate: Self.jstDate(month: 8, day: 27)
            )
        )
    }

    func testReturnsNilForEmptyCandidateList() {
        XCTAssertNil(
            CatchUpMatcher.bestMatch(
                among: [],
                seriesTitle: "アメトーーク！",
                episodeTitle: "東京吉本芸人の実情",
                broadcastDate: nil
            )
        )
    }

    func testMatchingWorksWithoutABroadcastDate() {
        let match = CatchUpMatcher.bestMatch(
            among: [Self.ametalk, Self.unrelated],
            seriesTitle: "アメトーーク！",
            episodeTitle: "東京吉本芸人の実情",
            broadcastDate: nil
        )
        XCTAssertEqual(match?.id, "ep3dxmhg0g")
    }

    func testScoreIsBoundedAndOrdered() {
        let strong = CatchUpMatcher.score(
            candidate: Self.ametalk,
            seriesTitle: "アメトーーク！",
            episodeTitle: "東京吉本芸人の実情",
            broadcastDate: Self.jstDate(month: 8, day: 27)
        )
        let weak = CatchUpMatcher.score(
            candidate: Self.unrelated,
            seriesTitle: "アメトーーク！",
            episodeTitle: "東京吉本芸人の実情",
            broadcastDate: Self.jstDate(month: 8, day: 27)
        )
        XCTAssertGreaterThan(strong, weak)
        XCTAssertLessThanOrEqual(strong, 1.0)
        XCTAssertGreaterThanOrEqual(weak, 0.0)
    }

    func testSimilarityIsSymmetricAndSelfMaximal() {
        let lhs = CatchUpTitleNormalizer.normalize("アメトーーク")
        let rhs = CatchUpTitleNormalizer.normalize("アメトーク")
        XCTAssertEqual(CatchUpMatcher.similarity(lhs, rhs), CatchUpMatcher.similarity(rhs, lhs))
        XCTAssertEqual(CatchUpMatcher.similarity(lhs, lhs), 1.0)
        XCTAssertEqual(CatchUpMatcher.similarity(lhs, ""), 0.0)
    }

    // MARK: - Fixtures

    private static let ametalk = CatchUpEpisodeCandidate(
        id: "ep3dxmhg0g",
        seriesID: "sr542nxzof",
        title: "東京吉本芸人の実情…9名が魂の叫び!! 千鳥も参戦",
        seriesTitle: "アメトーーク！",
        broadcastDateLabel: "8月27日(木)放送分",
        endAt: 1_788_453_180
    )

    private static let unrelated = CatchUpEpisodeCandidate(
        id: "epzzzzzzzz",
        seriesID: "srzzzzzzzz",
        title: "最新の天気と交通情報",
        seriesTitle: "夕方のニュース",
        broadcastDateLabel: "8月27日(木)放送分",
        endAt: 1_788_453_180
    )

    private static func jstDate(month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = 23
        components.minute = 0
        return calendar.date(from: components)!
    }
}
