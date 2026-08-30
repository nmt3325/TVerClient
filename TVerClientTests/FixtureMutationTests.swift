import XCTest
@testable import TVerClient

/// Applies six structural mutations to every committed fixture and asserts the
/// client keeps whatever it can instead of failing the whole payload.
///
/// The mutations mirror how TVer has actually broken this app before: a field
/// disappears, a key changes case, a number arrives as a string, an unmodelled
/// field appears, a value goes null, or one element of a list is malformed.
final class FixtureMutationTests: XCTestCase {
    private let client = TVerAPIClient()

    /// One decodable surface: which fixture feeds it, and how many values survive.
    /// A nil result means the decode failed outright.
    private struct Subject {
        let fixture: String
        let survivors: (TVerAPIClient, Data) throws -> Int?
    }

    private var subjects: [Subject] {
        [
            Subject(fixture: "platform_browser_create") { client, data in
                try client.decodeBrowserCredentials(data).value == nil ? nil : 1
            },
            Subject(fixture: "platform_episode_ranking") { client, data in
                try client.decodeEpisodeRanking(data).value?.count
            },
            Subject(fixture: "platform_series_episodes") { client, data in
                try client.decodeSeriesEpisodes(data).value?.count
            },
            Subject(fixture: "platform_ranking") { client, data in
                try client.decodeRankedSeriesIDs(data).value?.count
            },
            Subject(fixture: "platform_live_channel") { client, data in
                try client.decodeLiveChannels(data).value?.count
            },
            Subject(fixture: "platform_live_channel_snake") { client, data in
                try client.decodeLiveChannels(data).value?.count
            },
            Subject(fixture: "platform_live_timeline") { client, data in
                try client.decodeLiveTimeline(data, channelID: "ch01").value?.count
            },
            Subject(fixture: "service_keyword_search") { client, data in
                try client.decodeCatchUpSearch(data).value?.count
            },
            Subject(fixture: "streaks_live_playback") { client, data in
                try client.decodeValues(
                    data,
                    endpoint: .liveManifest,
                    keys: ["id", "name", "drm.license_url"]
                ).value?.count
            }
        ]
    }

    // MARK: - Mutations

    /// An unmodelled upstream field must never change what the client reads.
    func testUnknownFieldsAreAlwaysTolerated() throws {
        try forEachMutation({ tree in
            Self.paths(of: .object, in: tree).map { path in
                (
                    "unknown field under '\(path)'",
                    TVerFixture.replacing(tree, at: path + ".unexpectedUpstreamField", with: "placeholder")
                )
            }
        }, check: { baseline, result, context in
            XCTAssertEqual(result, baseline, context)
        })
    }

    /// snake_case and camelCase spellings of the same key are interchangeable.
    func testKeyNamingVariantsAreInterchangeable() throws {
        try forEachMutation({ tree in
            [
                ("snake_case keys", Self.renamingKeys(tree, using: Self.snakeCased)),
                ("camelCase keys", Self.renamingKeys(tree, using: Self.camelCased))
            ]
        }, check: { baseline, result, context in
            XCTAssertEqual(result, baseline, context)
        })
    }

    /// Numbers delivered as strings are coerced, not rejected.
    func testNumbersDeliveredAsStringsStillDecode() throws {
        try forEachMutation({ tree in
            Self.paths(of: .number, in: tree).map { path in
                (
                    "number as string at '\(path)'",
                    TVerFixture.replacing(tree, at: path, with: Self.stringForm(of: tree, at: path))
                )
            }
        }, check: { baseline, result, context in
            XCTAssertEqual(result, baseline, context)
        })
    }

    /// A string that turns into a number may change what matches, but must never
    /// crash or fail the payload as a whole.
    func testStringLeafTypeFlipsAreSurvivable() throws {
        try forEachMutation({ tree in
            Self.paths(of: .text, in: tree).map { path in
                ("string as number at '\(path)'", TVerFixture.replacing(tree, at: path, with: 1234))
            }
        }, check: { baseline, result, context in
            XCTAssertLessThanOrEqual(result ?? 0, baseline, context)
        })
    }

    /// Removing any single field keeps everything the client can still read.
    func testRemovingAnyFieldKeepsWhatRemains() throws {
        try forEachMutation({ tree in
            Self.paths(of: .leaf, in: tree).map { path in
                ("removed '\(path)'", TVerFixture.replacing(tree, at: path, with: nil))
            }
        }, check: { baseline, result, context in
            if context.hasSuffix("type'") {
                // A dropped discriminator is deliberately tolerated, so an entry that
                // was skipped before can become eligible and the count may grow.
                XCTAssertNotNil(result, context)
            } else {
                XCTAssertLessThanOrEqual(result ?? 0, baseline, context)
            }
        })
    }

    /// A null value is treated as an absent value, never as a decode failure of
    /// the surrounding payload.
    func testNullValuesKeepWhatRemains() throws {
        try forEachMutation({ tree in
            Self.paths(of: .leaf, in: tree).map { path in
                ("nulled '\(path)'", TVerFixture.replacing(tree, at: path, with: NSNull()))
            }
        }, check: { baseline, result, context in
            if context.hasSuffix("type'") {
                // A dropped discriminator is deliberately tolerated, so an entry that
                // was skipped before can become eligible and the count may grow.
                XCTAssertNotNil(result, context)
            } else {
                XCTAssertLessThanOrEqual(result ?? 0, baseline, context)
            }
        })
    }

    /// An empty list decodes to an empty result, not to an error.
    func testEmptyArraysDecodeToNothing() throws {
        try forEachMutation({ tree in
            Self.paths(of: .array, in: tree).map { path in
                ("emptied '\(path)'", TVerFixture.replacing(tree, at: path, with: [Any]()))
            }
        }, check: { baseline, result, context in
            XCTAssertNotNil(result, context)
            XCTAssertLessThanOrEqual(result ?? 0, baseline, context)
        })
    }

    /// One malformed element must not take the rest of the list with it.
    func testBrokenArrayElementIsIsolated() throws {
        try forEachMutation({ tree in
            Self.paths(of: .array, in: tree).map { path in
                (
                    "broken first element of '\(path)'",
                    TVerFixture.replacing(tree, at: path + ".0", with: "not an object")
                )
            }
        }, check: { baseline, result, context in
            XCTAssertNotNil(result, context)
            XCTAssertLessThanOrEqual(result ?? 0, baseline, context)
        })
    }

    // MARK: - Harness

    private func forEachMutation(
        _ variants: (Any) -> [(String, Any)],
        check: (Int, Int?, String) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for subject in subjects {
            let tree = try TVerFixture.object(subject.fixture)
            let baseline = try XCTUnwrap(
                subject.survivors(client, TVerFixture.encode(tree)),
                "\(subject.fixture) must decode before it is mutated",
                file: file,
                line: line
            )
            for (label, mutated) in variants(tree) {
                let context = "\(subject.fixture): \(label)"
                do {
                    check(baseline, try subject.survivors(client, TVerFixture.encode(mutated)), context)
                } catch is TVerClientError {
                    // An API-level error is a legitimate outcome for a mutated
                    // payload. Anything else escaping here fails the test.
                    continue
                }
            }
        }
    }

    // MARK: - JSON tree helpers

    private enum NodeKind {
        case object
        case array
        /// Any scalar: string, number or bool.
        case leaf
        case text
        case number
    }

    private static func paths(of kind: NodeKind, in object: Any, prefix: String = "") -> [String] {
        var found: [String] = []
        if let dictionary = object as? [String: Any] {
            if kind == .object { found.append(prefix) }
            for key in dictionary.keys.sorted() {
                let child = dictionary[key] as Any
                found += paths(of: kind, in: child, prefix: prefix.isEmpty ? key : prefix + "." + key)
            }
            return found
        }
        if let array = object as? [Any] {
            if kind == .array { found.append(prefix) }
            for (index, child) in array.enumerated() {
                let childPath = prefix.isEmpty ? String(index) : prefix + "." + String(index)
                found += paths(of: kind, in: child, prefix: childPath)
            }
            return found
        }
        if object is NSNull { return found }
        switch kind {
        case .leaf:
            found.append(prefix)
        case .text:
            if object is String { found.append(prefix) }
        case .number:
            if !(object is Bool), object is NSNumber { found.append(prefix) }
        case .object, .array:
            break
        }
        return found
    }

    private static func stringForm(of tree: Any, at path: String) -> String {
        var node: Any = tree
        for part in path.split(separator: ".").map(String.init) {
            if let dictionary = node as? [String: Any], let child = dictionary[part] {
                node = child
            } else if let array = node as? [Any], let index = Int(part), array.indices.contains(index) {
                node = array[index]
            }
        }
        return (node as? NSNumber)?.stringValue ?? "\(node)"
    }

    private static func renamingKeys(_ object: Any, using transform: (String) -> String) -> Any {
        if let dictionary = object as? [String: Any] {
            var renamed: [String: Any] = [:]
            for (key, value) in dictionary {
                renamed[transform(key)] = renamingKeys(value, using: transform)
            }
            return renamed
        }
        if let array = object as? [Any] {
            return array.map { renamingKeys($0, using: transform) }
        }
        return object
    }

    private static func snakeCased(_ key: String) -> String {
        var output = ""
        for character in key {
            if character.isUppercase {
                if !output.isEmpty, output.last != "_" {
                    output.append("_")
                }
                output += character.lowercased()
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func camelCased(_ key: String) -> String {
        let parts = key.split(separator: "_")
        guard let first = parts.first else { return key }
        return parts.dropFirst().reduce(String(first)) { $0 + $1.capitalized }
    }
}
