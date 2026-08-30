import XCTest
@testable import TVerClient

/// Loads the committed synthetic fixtures and edits them as plain JSON trees.
///
/// Resources land flat in the test bundle, so the bundle is tried with and
/// without the Fixtures subdirectory before falling back to the source folder.
enum TVerFixture {
    static let names = [
        "platform_browser_create",
        "platform_episode_ranking",
        "platform_ranking",
        "platform_series_episodes",
        "platform_live_channel",
        "platform_live_channel_snake",
        "platform_live_timeline",
        "service_keyword_search",
        "streaks_live_playback"
    ]

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String {
            "fixture \(name).json was not found in the test bundle or in TVerClientTests/Fixtures"
        }
    }

    static func url(_ name: String) throws -> URL {
        let bundle = Bundle(for: Token.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return url
        }
        let onDisk = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name + ".json")
        if FileManager.default.fileExists(atPath: onDisk.path) {
            return onDisk
        }
        throw Missing(name: name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func object(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed])
    }

    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    /// Rebuilds the tree with the value at a dotted path replaced. Integer
    /// components index arrays, and a nil value removes the entry.
    static func replacing(_ object: Any, at path: String, with value: Any?) -> Any {
        replacing(object, parts: path.split(separator: ".").map(String.init)[...], with: value)
    }

    static func mutated(_ name: String, at path: String, with value: Any?) throws -> Data {
        try encode(replacing(object(name), at: path, with: value))
    }

    private static func replacing(_ object: Any, parts: ArraySlice<String>, with value: Any?) -> Any {
        guard let head = parts.first else { return value ?? NSNull() }
        let rest = parts.dropFirst()

        if var dictionary = object as? [String: Any] {
            if rest.isEmpty {
                if let value {
                    dictionary[head] = value
                } else {
                    dictionary.removeValue(forKey: head)
                }
            } else if let child = dictionary[head] {
                dictionary[head] = replacing(child, parts: rest, with: value)
            }
            return dictionary
        }

        if var array = object as? [Any], let index = Int(head), array.indices.contains(index) {
            if rest.isEmpty {
                if let value {
                    array[index] = value
                } else {
                    array.remove(at: index)
                }
            } else {
                array[index] = replacing(array[index], parts: rest, with: value)
            }
            return array
        }

        return object
    }

    private final class Token {}
}

final class TVerAPIDecodingTests: XCTestCase {
    private let client = TVerAPIClient()

    func testEveryFixtureIsReadable() throws {
        for name in TVerFixture.names {
            XCTAssertFalse(try TVerFixture.data(name).isEmpty, name)
        }
    }

    func testEpisodeRankingFixtureDecodes() throws {
        let outcome = try client.decodeEpisodeRanking(TVerFixture.data("platform_episode_ranking"))
        XCTAssertNil(outcome.failure)
        let episodes = try XCTUnwrap(outcome.value)
        XCTAssertEqual(episodes.map(\.id), ["ep000001", "ep000002", "ep000003"])
        XCTAssertEqual(episodes.first?.seriesTitle, "サンプル番組A")
        XCTAssertEqual(episodes.first?.broadcastDateLabel, "1月5日(月)放送分")
        XCTAssertEqual(episodes.first?.endAt, 1893974400)
    }

    func testSeriesEpisodesFixtureDecodesFlatContents() throws {
        let episodes = try XCTUnwrap(
            client.decodeSeriesEpisodes(TVerFixture.data("platform_series_episodes")).value
        )
        XCTAssertEqual(episodes.map(\.id), ["ep000010", "ep000011"])
    }

    func testRankedSeriesIDsFollowRank() throws {
        let ids = try XCTUnwrap(client.decodeRankedSeriesIDs(TVerFixture.data("platform_ranking")).value)
        XCTAssertEqual(ids, ["sr000001", "sr000002", "sr000003"])
    }

    func testBrowserCredentialsFixtureDecodes() throws {
        let credentials = try XCTUnwrap(
            client.decodeBrowserCredentials(TVerFixture.data("platform_browser_create")).value
        )
        XCTAssertEqual(credentials.uid, "placeholder-uid-00000000")
        XCTAssertEqual(credentials.token, "placeholder-token-00000000")
    }

    func testLiveChannelFixtureDecodes() throws {
        let channels = try XCTUnwrap(
            client.decodeLiveChannels(TVerFixture.data("platform_live_channel")).value
        )
        XCTAssertEqual(channels.map(\.id), ["ch01", "ch02"])
        XCTAssertEqual(channels.first?.name, "サンプルチャンネル1")
        XCTAssertEqual(channels.first?.apiKey, "ch01")
        XCTAssertEqual(channels.first?.mediaID, "ref:placeholder-simul-ch01")
        XCTAssertEqual(
            channels.first?.iconURL?.absoluteString,
            "https://statics.tver.jp/images/icon/ch01.jpg?v=2"
        )
    }

    /// Regression: snake_case keys, a missing `type` and a stringified version
    /// used to drop channels outright.
    func testSnakeCaseLiveChannelsMatchCamelCase() throws {
        let camel = try XCTUnwrap(
            client.decodeLiveChannels(TVerFixture.data("platform_live_channel")).value
        )
        let snake = try XCTUnwrap(
            client.decodeLiveChannels(TVerFixture.data("platform_live_channel_snake")).value
        )
        XCTAssertEqual(snake.map(\.id), camel.map(\.id))
        XCTAssertEqual(snake.map(\.projectID), camel.map(\.projectID))
        XCTAssertEqual(snake.map(\.mediaID), camel.map(\.mediaID))
        XCTAssertEqual(snake.map(\.apiKey), camel.map(\.apiKey))
        XCTAssertEqual(snake.first?.iconURL, camel.first?.iconURL)
    }

    func testLiveTimelineKeepsPauseProgram() throws {
        let programs = try XCTUnwrap(
            client.decodeLiveTimeline(TVerFixture.data("platform_live_timeline"), channelID: "ch01").value
        )
        XCTAssertEqual(programs.map(\.isPause), [false, false, true])
        XCTAssertEqual(programs.first?.startAt, Date(timeIntervalSince1970: 1893456000))
        XCTAssertEqual(
            programs.first?.thumbnailURL?.absoluteString,
            "https://statics.tver.jp/images/placeholder/lv000001.jpg"
        )
        XCTAssertEqual(programs.last?.id, "pause-ch01-1893463200")
        XCTAssertEqual(programs.last?.title, "配信休止")
    }

    func testKeywordSearchIgnoresNonEpisodeEntries() throws {
        let episodes = try XCTUnwrap(
            client.decodeCatchUpSearch(TVerFixture.data("service_keyword_search")).value
        )
        XCTAssertEqual(episodes.map(\.id), ["ep000020", "ep000021"])
        let candidates = client.catchUpCandidates(fromEpisodes: episodes)
        XCTAssertEqual(candidates.map(\.id), ["ep000020", "ep000021"])
        XCTAssertEqual(candidates.first?.seriesTitle, "サンプル検索番組")
        XCTAssertEqual(candidates.first?.seriesID, "sr000005")
    }

    func testStreaksPlaybackValuesAreReadable() throws {
        let outcome = try client.decodeValues(
            TVerFixture.data("streaks_live_playback"),
            endpoint: .liveManifest,
            keys: ["id", "name", "drm.license_url"]
        )
        XCTAssertEqual(try XCTUnwrap(outcome.value), [
            "ref:placeholder-simul-ch01",
            "サンプルライブ配信",
            "https://placeholder.example/license"
        ])
    }

    /// Regression: a payload without `code` was rejected as an API error.
    func testMissingCodeIsSuccess() throws {
        let data = try TVerFixture.mutated("platform_episode_ranking", at: "code", with: nil)
        XCTAssertEqual(try XCTUnwrap(client.decodeEpisodeRanking(data).value).count, 3)
    }

    /// Regression: `"code": "0"` is still a success.
    func testStringCodeZeroIsSuccess() throws {
        let data = try TVerFixture.mutated("platform_episode_ranking", at: "code", with: "0")
        XCTAssertEqual(try XCTUnwrap(client.decodeEpisodeRanking(data).value).count, 3)
    }

    func testNonZeroCodeSurfacesAPIError() throws {
        var object = try TVerFixture.object("platform_episode_ranking")
        object = TVerFixture.replacing(object, at: "code", with: 1)
        object = TVerFixture.replacing(object, at: "message", with: "placeholder error")
        let data = try TVerFixture.encode(object)
        XCTAssertThrowsError(try client.decodeEpisodeRanking(data)) { error in
            guard let clientError = error as? TVerClientError, case .api = clientError else {
                return XCTFail("expected an api error, got \(error)")
            }
        }
    }

    /// Regression: numbers delivered as strings used to fail the whole payload.
    func testNumericStringsAreCoerced() throws {
        let data = try TVerFixture.mutated(
            "platform_episode_ranking",
            at: "result.contents.0.contents.0.content.endAt",
            with: "1893974400"
        )
        XCTAssertEqual(try XCTUnwrap(client.decodeEpisodeRanking(data).value).first?.endAt, 1893974400)
    }

    /// Regression: one broken element used to empty the entire list.
    func testBrokenElementIsIsolated() throws {
        let data = try TVerFixture.mutated(
            "platform_episode_ranking",
            at: "result.contents.0.contents.1.content",
            with: "not an object"
        )
        let outcome = try client.decodeEpisodeRanking(data)
        XCTAssertEqual(try XCTUnwrap(outcome.value).map(\.id), ["ep000001", "ep000003"])
        XCTAssertEqual(outcome.degradation?.droppedElementCount, 1)
    }

    /// Regression: an added upstream field must be counted, never fatal.
    func testUnknownFieldsAreCountedNotFatal() throws {
        let data = try TVerFixture.mutated(
            "platform_episode_ranking",
            at: "result.contents.0.contents.0.content.brandNewField",
            with: "placeholder"
        )
        let outcome = try client.decodeEpisodeRanking(data)
        XCTAssertEqual(try XCTUnwrap(outcome.value).count, 3)
        let unknown = try XCTUnwrap(outcome.degradation?.unknownKeys)
        XCTAssertTrue(unknown.contains { $0.hasSuffix("brandNewField") }, "unknown keys: \(unknown)")
    }

    /// Regression: the broadcast-date year came from the wall clock, so schedule
    /// results changed under the test suite depending on the day it ran.
    func testProgramDaysUseInjectedClock() throws {
        let episodes = [
            EpisodeContent(
                id: "ep000001",
                seriesID: "sr000001",
                title: "プレースホルダー",
                seriesTitle: "サンプル番組A",
                description: "",
                broadcastDateLabel: "12月31日",
                endAt: nil,
                thumbnailPath: nil
            )
        ]
        let firstNow = Date(timeIntervalSince1970: 1_768_000_000)
        let secondNow = firstNow.addingTimeInterval(365 * 24 * 60 * 60)
        let calendar = Calendar(identifier: .gregorian)

        let firstDays = TVerAPIClient(dateProvider: { firstNow }).programDays(fromEpisodes: episodes)
        let secondDays = TVerAPIClient(dateProvider: { secondNow }).programDays(fromEpisodes: episodes)
        let firstDate = try XCTUnwrap(firstDays.first?.date)
        let secondDate = try XCTUnwrap(secondDays.first?.date)

        XCTAssertNotEqual(
            calendar.component(.year, from: firstDate),
            calendar.component(.year, from: secondDate),
            "the broadcast year must follow the injected clock, not the wall clock"
        )
        XCTAssertLessThan(abs(firstDate.timeIntervalSince(firstNow)), 366 * 24 * 60 * 60)
        XCTAssertLessThan(abs(secondDate.timeIntervalSince(secondNow)), 366 * 24 * 60 * 60)
    }
}
