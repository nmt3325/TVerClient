import Foundation

/// Stage at which live stream resolution stopped, mirroring the three network
/// hops the official player performs.
enum LiveResolutionStage: String, Sendable {
    case metadata
    case session
    case manifest
}

/// Resolves TVer's official live Streaks flow. Live SSAI media must be
/// sessionized before its manifest is handed to AVPlayer.
final class LiveStreamResolver: TVerLiveStreamResolving, @unchecked Sendable {
    private static let playerInfoURL = URL(string: "https://player.tver.jp/player/streaks_info_v2.json")!
    private let session: URLSession
    private let dateProvider: () -> Date
    private let requestObserver: ((URLRequest) -> Void)?
    private let healthReporter: EndpointHealthReporting

    init(
        session: URLSession = TVerNetworking.makeEphemeralSession(),
        dateProvider: @escaping () -> Date = Date.init,
        requestObserver: ((URLRequest) -> Void)? = nil,
        healthReporter: EndpointHealthReporting = EndpointHealthStore.shared
    ) {
        self.session = session
        self.dateProvider = dateProvider
        self.requestObserver = requestObserver
        self.healthReporter = healthReporter
    }

    func resolveLiveStream(for channel: TVerLiveChannel) async throws -> URL {
        let info = try await json(from: Self.playerInfoURL, stage: .metadata)
        let legacyKey = "tver-\(channel.apiKey)"
        guard let projectInfo = (info[channel.projectID] ?? info[legacyKey] ?? info[channel.apiKey]) as? [String: Any],
              let keyObject = projectInfo["api_key"] as? [String: Any] else {
            reportManifest(outcome: .failed, category: .upstreamChange, note: "player info has no api_key for this project")
            throw TVerClientError.noPlayableStream
        }

        let apiKeys = Self.orderedAPIKeys(keyObject, at: dateProvider())
        guard !apiKeys.isEmpty,
              let project = Self.pathSegment(channel.projectID),
              let reference = Self.pathSegment(channel.mediaID) else {
            reportManifest(outcome: .failed, category: .upstreamChange, note: "channel is missing usable project or media identifiers")
            throw TVerClientError.noPlayableStream
        }

        // The official live module never supplies the VOD-only `ati` query.
        guard let playbackURL = URL(string: "https://playback.api.streaks.jp/v1/projects/\(project)/medias/\(reference)") else {
            reportManifest(outcome: .failed, category: .clientBug, note: "playback URL could not be built")
            throw TVerClientError.invalidResponse
        }

        // Each API key is a separate network attempt and is reported as such.
        // Only metadata failures are worth retrying with the next key; once a
        // payload is in hand the manifest stage runs exactly once so its
        // failure reason is no longer replaced by a generic retry loop.
        var media: [String: Any]?
        for apiKey in apiKeys {
            var request = URLRequest(url: playbackURL)
            Self.addOfficialHeaders(to: &request)
            request.setValue(apiKey, forHTTPHeaderField: "X-Streaks-Api-Key")
            let started = Date()
            do {
                let result = try await load(request)
                guard let root = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any] else {
                    report(
                        stage: .metadata, outcome: .failed, category: .upstreamChange,
                        httpStatus: result.statusCode, startedAt: started,
                        note: "playback payload is not a JSON object"
                    )
                    continue
                }
                report(
                    stage: .metadata, outcome: .ok,
                    httpStatus: result.statusCode, startedAt: started
                )
                media = (root["media"] as? [String: Any]) ?? root
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as LiveHTTPFailure {
                report(
                    stage: .metadata, outcome: .failed, category: failure.category,
                    httpStatus: failure.statusCode, startedAt: started,
                    note: "playback metadata request failed"
                )
                continue
            } catch {
                report(
                    stage: .metadata, outcome: .failed, category: .clientBug,
                    startedAt: started, note: "playback metadata attempt raised an unexpected error"
                )
                continue
            }
        }

        guard let media else {
            reportManifest(outcome: .failed, category: .upstreamChange, note: "every playback API key was rejected")
            throw TVerClientError.noPlayableStream
        }

        do {
            return try await resolveManifest(media: media, channel: channel)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TVerClientError {
            throw error
        } catch {
            throw TVerClientError.noPlayableStream
        }
    }

    private func resolveManifest(media: [String: Any], channel: TVerLiveChannel) async throws -> URL {
        let sources = Self.sourceDictionaries(media["sources"])
        let hlsSources = sources.filter(Self.isClearHLS)
        guard let preferred = hlsSources.first,
              let preferredRawURL = Self.string(preferred["src"]),
              let preferredURL = URL(string: preferredRawURL),
              TVerNetworking.isPermittedStreamURL(preferredURL) else {
            reportManifest(outcome: .failed, category: .upstreamChange, note: "payload exposed no permitted DRM-free HLS source")
            throw TVerClientError.noPlayableStream
        }

        let mediaUsesSSAI = Self.isEnabledSSAI(media["ssai"])
        let selectedSources = hlsSources.filter { source in
            (mediaUsesSSAI || Self.isEnabledSSAI(source["ssai"])) &&
            !Self.isSessionized(Self.string(source["src"])) &&
            Self.string(source["id"]) != nil
        }

        guard !selectedSources.isEmpty else {
            // Already-sessionized and genuinely non-SSAI sources retain the
            // historical clear-HLS fallback. Raw SSAI sources never do.
            if mediaUsesSSAI || Self.isEnabledSSAI(preferred["ssai"]) {
                if Self.isSessionized(preferredRawURL) {
                    reportManifest(outcome: .ok, category: .none, note: "payload already carried a sessionized manifest")
                    return preferredURL
                }
                reportManifest(outcome: .failed, category: .upstreamChange, note: "SSAI media exposed no sessionizable source")
                throw TVerClientError.noPlayableStream
            }
            // Handing AVPlayer the raw clear-HLS source skips the official
            // session, so it is a fallback rather than a success.
            reportManifest(
                outcome: .fallbackUsed,
                category: .upstreamChange,
                note: "no SSAI source advertised; using non-sessionized clear HLS"
            )
            return preferredURL
        }

        // The official playback API returns snake_case identifiers at the root
        // of the payload (project_id / id / ref_id). Older camelCase spellings
        // and the requested channel remain as fallbacks.
        let wireProjectID = Self.string(media["project"])
            ?? Self.string(media["projectId"])
            ?? Self.string(media["project_id"])
            ?? Self.string(channel.projectID)
        let wireMediaID = Self.string(media["mediaId"])
            ?? Self.string(media["id"])
            ?? Self.string(media["media_id"])
            ?? Self.string(media["ref_id"])
        guard let projectID = wireProjectID,
              let mediaID = wireMediaID,
              let project = Self.pathSegment(projectID),
              let mediaPath = Self.pathSegment(mediaID),
              let sessionURL = URL(string: "https://ssai.api.streaks.jp/v1/projects/\(project)/medias/\(mediaPath)/ssai/session") else {
            reportManifest(outcome: .failed, category: .upstreamChange, note: "payload carried no usable SSAI session identifiers")
            throw TVerClientError.noPlayableStream
        }

        let sourceIDs = selectedSources.compactMap { Self.string($0["id"]) }
        guard !sourceIDs.isEmpty else {
            reportManifest(outcome: .failed, category: .upstreamChange, note: "selected sources carried no identifiers")
            throw TVerClientError.noPlayableStream
        }

        var adsParams = Self.defaultLiveAdsParams(for: channel)
        let wireAdFields = (media["ad_fields"] as? [String: Any]) ?? (media["adFields"] as? [String: Any]) ?? [:]
        for (key, value) in wireAdFields { adsParams[key] = value }

        var request = URLRequest(url: sessionURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        Self.addOfficialHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "X-Streaks-Api-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "ads_params": adsParams,
            "id": sourceIDs.joined(separator: ",")
        ])

        let sessionStartedAt = Date()
        let sessionResult: (data: Data, statusCode: Int)
        do {
            sessionResult = try await load(request)
        } catch let failure as LiveHTTPFailure {
            report(
                stage: .session, outcome: .failed, category: failure.category,
                httpStatus: failure.statusCode, startedAt: sessionStartedAt,
                note: "SSAI session request failed"
            )
            reportManifest(outcome: .failed, category: failure.category, note: "SSAI session could not be created")
            throw TVerClientError.noPlayableStream
        }

        guard let entries = (try? JSONSerialization.jsonObject(with: sessionResult.data)) as? [[String: Any]] else {
            report(
                stage: .session, outcome: .failed, category: .upstreamChange,
                httpStatus: sessionResult.statusCode, startedAt: sessionStartedAt,
                note: "session payload is not a JSON array"
            )
            reportManifest(outcome: .failed, category: .upstreamChange, note: "SSAI session payload changed shape")
            throw TVerClientError.invalidResponse
        }
        report(
            stage: .session, outcome: .ok,
            httpStatus: sessionResult.statusCode, startedAt: sessionStartedAt
        )

        for source in selectedSources {
            guard let sourceID = Self.string(source["id"]),
                  let rawSource = Self.string(source["src"]),
                  let entry = entries.first(where: { Self.string($0["id"]) == sourceID }),
                  let opaqueQuery = Self.stringPreservingWhitespace(entry["query"]),
                  !opaqueQuery.isEmpty else { continue }
            let separator = rawSource.contains("?") ? "&" : "?"
            guard let finalURL = URL(string: rawSource + separator + opaqueQuery),
                  TVerNetworking.isPermittedStreamURL(finalURL),
                  Self.isSessionized(finalURL.absoluteString) else { continue }
            reportManifest(outcome: .ok, category: .none, note: "sessionized live manifest resolved")
            return finalURL
        }
        reportManifest(
            outcome: .failed,
            category: .upstreamChange,
            note: "session response matched none of the \(selectedSources.count) selected sources"
        )
        throw TVerClientError.noPlayableStream
    }

    private func json(from url: URL, stage: LiveResolutionStage) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        Self.addOfficialHeaders(to: &request)
        let started = Date()
        do {
            let result = try await load(request)
            guard let value = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any] else {
                report(
                    stage: stage, outcome: .failed, category: .upstreamChange,
                    httpStatus: result.statusCode, startedAt: started,
                    note: "player info payload is not a JSON object"
                )
                throw TVerClientError.invalidResponse
            }
            report(stage: stage, outcome: .ok, httpStatus: result.statusCode, startedAt: started)
            return value
        } catch let failure as LiveHTTPFailure {
            report(
                stage: stage, outcome: .failed, category: failure.category,
                httpStatus: failure.statusCode, startedAt: started,
                note: "player info request failed"
            )
            throw TVerClientError.noPlayableStream
        }
    }

    /// Transport level failure. Unlike the previous implementation this keeps
    /// the HTTP status so the diagnostics screen can tell an upstream change
    /// (4xx) apart from an outage (5xx) or a network problem.
    private struct LiveHTTPFailure: Error {
        let statusCode: Int?
        let category: EndpointFailureCategory
    }

    private func load(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        requestObserver?(request)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LiveHTTPFailure(statusCode: nil, category: .clientBug)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw LiveHTTPFailure(
                    statusCode: http.statusCode,
                    category: http.statusCode >= 500 ? .environment : .upstreamChange
                )
            }
            return (data, http.statusCode)
        } catch let failure as LiveHTTPFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveHTTPFailure(statusCode: nil, category: .network)
        }
    }

    private func report(
        stage: LiveResolutionStage,
        outcome: EndpointOutcome,
        category: EndpointFailureCategory = .none,
        httpStatus: Int? = nil,
        startedAt: Date,
        note: String? = nil
    ) {
        var text = "live \(stage.rawValue)"
        if let note, !note.isEmpty { text += ": \(note)" }
        healthReporter.record(EndpointHealthEvent(
            endpoint: .liveManifest,
            outcome: outcome,
            category: category,
            httpStatus: httpStatus,
            durationMS: Self.elapsedMS(since: startedAt),
            note: text
        ))
    }

    /// Reports what AVPlayer is actually going to be handed. A downgrade to a
    /// non-sessionized manifest is reported as `.fallbackUsed`, never `.ok`.
    private func reportManifest(
        outcome: EndpointOutcome,
        category: EndpointFailureCategory,
        note: String
    ) {
        healthReporter.record(EndpointHealthEvent(
            endpoint: .mediaManifest,
            outcome: outcome,
            category: category,
            note: "live manifest: \(note)"
        ))
    }

    private static func elapsedMS(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    private static func orderedAPIKeys(_ keyObject: [String: Any], at date: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let month = calendar.component(.month, from: date)
        let slot = month % 6 == 0 ? 6 : month % 6
        let preferredName = String(format: "key%02d", slot)

        var names = keyObject.keys.sorted()
        if let index = names.firstIndex(of: preferredName) {
            names.insert(names.remove(at: index), at: 0)
        }
        return names.compactMap { string(keyObject[$0]) }
    }

    private static func addOfficialHeaders(to request: inout URLRequest) {
        request.setValue("https://tver.jp", forHTTPHeaderField: "Origin")
        request.setValue("https://tver.jp/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
    }

    private static func defaultLiveAdsParams(for channel: TVerLiveChannel) -> [String: Any] {
        let emptyKeys = [
            "tvcu_pcode", "tvcu_ccode", "tvcu_zcode", "tvcu_gender", "tvcu_gender_code",
            "tvcu_age", "tvcu_agegrp", "rdid", "idtype", "is_lat", "bundle", "interest",
            "item_eventid", "item_programkey", "item_category", "item_episodecode",
            "item_originalmeta1", "item_originalmeta2", "ntv_ppid", "tbs_ppid", "tx_ppid",
            "ex_ppid", "cx_ppid_gam", "mbs_ppid_gam", "abc_ppid", "tvo_ppid", "ktv_ppid",
            "ytv_ppid", "ntv_ppid2", "tbs_ppid2", "tx_ppid2", "ex_ppid2", "cx_ppid2",
            "mbs_ppid2", "abc_ppid2", "tvo_ppid2", "ktv_ppid2", "ytv_ppid2", "vr_uuid",
            "platformAdUid", "platformUid", "accountId", "memberId", "memberIdHash", "luid",
            "platformVrUid"
        ]
        var result = Dictionary(uniqueKeysWithValues: emptyKeys.map { ($0, "") })
        result["delivery_type"] = "simul"
        result["is_dvr"] = "0"
        result["video_id"] = channel.currentProgram?.id ?? ""
        result["device"] = "pc"
        result["device_code"] = "0001"
        result["tag_type"] = "browser"
        result["car"] = "0"
        result["personalIsLat"] = "0"
        result["c"] = "simul"
        return result
    }

    private static func sourceDictionaries(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let source = value as? [String: Any] { return [source] }
        return []
    }

    private static func isClearHLS(_ source: [String: Any]) -> Bool {
        guard let raw = string(source["src"]), let url = URL(string: raw),
              TVerNetworking.isPermittedStreamURL(url),
              isDRMFree(source) else { return false }
        let type = string(source["type"])?.lowercased() ?? ""
        return type.contains("mpegurl") || raw.lowercased().contains(".m3u8")
    }

    private static func isDRMFree(_ source: [String: Any]) -> Bool {
        for key in ["key_systems", "keySystems"] where source.keys.contains(key) {
            guard let systems = source[key] as? [String: Any], systems.isEmpty else { return false }
        }
        for key in ["drm", "protected"] where isEnabledSSAI(source[key]) { return false }
        if string(source["license_url"]) != nil || string(source["licenseUrl"]) != nil {
            return false
        }
        return true
    }

    private static func isEnabledSSAI(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String:
            return !text.isEmpty && !["false", "0", "disabled", "none"].contains(text.lowercased())
        case let dictionary as [String: Any]:
            if let enabled = dictionary["enabled"] { return isEnabledSSAI(enabled) }
            return !dictionary.isEmpty
        default: return false
        }
    }

    private static func isSessionized(_ rawURL: String?) -> Bool {
        guard let rawURL,
              let components = URLComponents(string: rawURL) else { return false }
        return components.queryItems?.contains { item in
            item.name.lowercased() == "session"
                && item.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } == true
    }

    private static func string(_ value: Any?) -> String? {
        let text = value as? String
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func stringPreservingWhitespace(_ value: Any?) -> String? {
        value as? String
    }

    private static func pathSegment(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
