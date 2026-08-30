import AVFoundation
import Foundation
import MediaPlayer

enum PlaybackState: Equatable, Sendable {
    case idle
    case resolving
    case playing
    case paused
    case ended
    case failed(TVerClientError)
}

/// The slice of `AVAudioSession` the playback stack depends on.
///
/// The real session is process wide, so interruption handling can only be
/// pinned down by a test when the controller talks to this protocol instead of
/// the singleton.
protocol PlaybackAudioSessioning: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: PlaybackAudioSessioning {}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentProgram: TVerProgram?
    @Published private(set) var currentLiveChannel: TVerLiveChannel?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var error: TVerClientError?
    /// Playhead in seconds. Frozen while the user drags the scrubber so the
    /// knob never jumps back to a stale periodic observer value.
    @Published private(set) var currentTime: TimeInterval = 0
    /// Duration of the current item, nil for live and not yet known items.
    @Published private(set) var duration: TimeInterval?
    /// How far the item is buffered ahead of the playhead, 0...1.
    @Published private(set) var loadedFraction: Double = 0
    /// True while a seek is still chasing the requested time.
    @Published private(set) var isSeeking = false
    /// True while a finger is on the scrubber.
    @Published private(set) var isScrubbing = false
    @Published private(set) var playbackSpeed: PlaybackSpeed = .normal
    @Published private(set) var subtitleOptions: [MediaSelectionEntry] = []
    @Published private(set) var audioOptions: [MediaSelectionEntry] = []

    let player: AVPlayer
    private let resolver: any TVerStreamResolving
    private let liveResolver: any TVerLiveStreamResolving
    private let audioSession: any PlaybackAudioSessioning
    private let notificationCenter: NotificationCenter
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var remoteTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var requestGeneration = 0
    private var wantsPlayback = false
    private var seeker = ChaseTimeSeeker()
    private var legibleGroup: AVMediaSelectionGroup?
    private var audibleGroup: AVMediaSelectionGroup?
    /// Set only when the system suspended playback that we had asked for, so
    /// the end of an interruption restores those sessions and nothing else.
    private var shouldResumeAfterInterruption = false

    init(
        resolver: any TVerStreamResolving = BrightcoveStreamResolver(),
        liveResolver: any TVerLiveStreamResolving = LiveStreamResolver(),
        player: AVPlayer = AVPlayer(),
        audioSession: any PlaybackAudioSessioning = AVAudioSession.sharedInstance(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.resolver = resolver
        self.liveResolver = liveResolver
        self.player = player
        self.audioSession = audioSession
        self.notificationCenter = notificationCenter
        installPlayerObservers()
        installAudioSessionObservers()
        installRemoteCommands()
    }

    deinit {
        itemStatusObservation?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        let observers: [NSObjectProtocol?] = [endObserver, failedObserver, interruptionObserver, routeChangeObserver]
        for observer in observers.compactMap({ $0 }) { notificationCenter.removeObserver(observer) }
        for entry in remoteTargets { entry.command.removeTarget(entry.target) }
    }

    var errorMessage: String? { error?.localizedDescription }
    var errorPresentation: TVerErrorPresentation? { error?.presentation }
    var isLive: Bool { currentLiveChannel != nil }
    var isLoading: Bool { state == .resolving }
    /// Seeking needs a finite duration, so live streams stay excluded.
    var canSeek: Bool { !isLive && (duration ?? 0) > 0 }
    var chaseTime: CMTime { seeker.chaseTime }
    var isSeekInProgress: Bool { seeker.isSeekInProgress }

    func play(_ program: TVerProgram) async {
        beginRequest(program: program, liveChannel: nil)
        let generation = requestGeneration
        do {
            // A downloaded episode must play from disk, never from the network.
            if let offlineURL = OfflineAssetRegistry.assetURL(for: program.id) {
                recordPlaybackCheckpoint("Offline asset resolved")
                try await start(url: offlineURL, generation: generation)
                return
            }
            let url = try await resolver.resolveStream(for: program)
            recordPlaybackCheckpoint("VOD stream resolved")
            try await start(url: url, generation: generation)
        } catch {
            finishWithError(error, generation: generation)
        }
    }

    func playLive(_ channel: TVerLiveChannel) async {
        beginRequest(program: nil, liveChannel: channel)
        let generation = requestGeneration
        guard channel.isPlayable else {
            finishWithError(TVerClientError.noPlayableStream, generation: generation)
            return
        }
        do {
            let url = try await liveResolver.resolveLiveStream(for: channel)
            recordPlaybackCheckpoint("Live stream resolved")
            try await start(url: url, generation: generation)
        } catch {
            finishWithError(error, generation: generation)
        }
    }

    func resume() {
        guard let item = player.currentItem else { return }
        do {
            try activateAudioSession()
            wantsPlayback = true
            error = nil
            // AVPlayer ignores `play()` while the playhead sits at the end of
            // the item. Without this rewind the state machine, the transport
            // controls and the lock screen all report playback while the
            // player stays silent.
            if hasPlayedToEnd(item) {
                seeker.reset()
                player.seek(to: .zero)
                currentTime = 0
            }
            startPlayback()
            if item.status == .readyToPlay {
                transition(to: .playing)
            } else {
                transition(to: .resolving)
            }
        } catch {
            applyPlaybackFailure(error)
        }
    }

    func pause() {
        wantsPlayback = false
        // An explicit pause outranks a pending interruption restore.
        shouldResumeAfterInterruption = false
        player.pause()
        transition(to: .paused)
    }

    func stop() {
        requestGeneration += 1
        wantsPlayback = false
        shouldResumeAfterInterruption = false
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        resetTimingState()
        currentProgram = nil
        currentLiveChannel = nil
        error = nil
        transition(to: .idle, updateNowPlaying: false)
        configureRemoteCommandsForCurrentItem()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func togglePlayback() { isPlaying ? pause() : resume() }

    func seek(to seconds: TimeInterval) {
        guard !isLive, seconds.isFinite else { return }
        let target = ScrubberMath.clamped(seconds, duration: duration ?? 0)
        currentTime = target
        seekToTime(CMTime(seconds: target, preferredTimescale: 600))
        updateNowPlayingInfo(elapsed: target)
    }

    func seek(by offset: TimeInterval) {
        guard !isLive else { return }
        // While a seek is still chasing, the player clock lags behind the
        // requested position, so repeated skips must stack on our own value.
        let playerTime = player.currentTime().seconds
        let base = (isSeekInProgress || isScrubbing || !playerTime.isFinite) ? currentTime : playerTime
        seek(to: base + offset)
    }

    /// Chase-time seeking, Apple QA1820.
    ///
    /// Only one seek is ever in flight: a newer target is remembered and
    /// chased from the completion handler. Issuing a seek per drag update
    /// instead cancels the previous one forever and the picture never
    /// catches up with the finger.
    func seekToTime(_ time: CMTime) {
        guard let next = seeker.request(time) else { return }
        isSeeking = true
        performSeek(to: next)
    }

    /// Freezes the published playhead while the scrubber is being dragged.
    func beginScrubbing() {
        guard canSeek else { return }
        isScrubbing = true
    }

    func previewScrub(to seconds: TimeInterval) {
        guard isScrubbing else { return }
        currentTime = ScrubberMath.clamped(seconds, duration: duration ?? 0)
    }

    func endScrubbing(at seconds: TimeInterval) {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: seconds)
    }

    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        playbackSpeed = speed
        // `defaultRate` keeps the choice across pauses, and `rate` only sticks
        // when it is applied after `play()`.
        player.defaultRate = Float(speed.rawValue)
        if isPlaying { startPlayback() }
        updateNowPlayingInfo()
    }

    func selectSubtitle(id: String) {
        guard let item = player.currentItem, let group = legibleGroup else { return }
        if id == MediaSelectionEntry.offIdentifier {
            item.select(nil, in: group)
        } else if let index = Int(id), group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
        }
        updateMediaSelectionEntries()
    }

    func selectAudio(id: String) {
        guard let item = player.currentItem,
              let group = audibleGroup,
              let index = Int(id),
              group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
        updateMediaSelectionEntries()
    }

    private func performSeek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let next = self.seeker.complete(time) {
                    self.performSeek(to: next)
                } else {
                    self.isSeeking = false
                    self.refreshTimingState()
                }
            }
        }
    }

    private func resetTimingState() {
        seeker.reset()
        isScrubbing = false
        isSeeking = false
        currentTime = 0
        duration = nil
        loadedFraction = 0
        legibleGroup = nil
        audibleGroup = nil
        subtitleOptions = []
        audioOptions = []
    }

    /// Keeps duration and the buffered range in sync with the current item.
    private func refreshTimingState() {
        guard let item = player.currentItem else {
            duration = nil
            loadedFraction = 0
            return
        }
        let itemDuration = item.duration.seconds
        let resolved: TimeInterval? = (itemDuration.isFinite && itemDuration > 0) ? itemDuration : nil
        if duration != resolved { duration = resolved }
        loadedFraction = BufferMath.loadedFraction(
            ranges: item.loadedTimeRanges.map(\.timeRangeValue),
            currentTime: currentTime,
            duration: resolved ?? 0
        )
    }

    private func refreshMediaSelection(for item: AVPlayerItem) {
        legibleGroup = nil
        audibleGroup = nil
        subtitleOptions = []
        audioOptions = []
        Task { @MainActor [weak self] in
            let asset = item.asset
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            guard let self, item === self.player.currentItem else { return }
            self.legibleGroup = legible
            self.audibleGroup = audible
            self.updateMediaSelectionEntries()
        }
    }

    private func updateMediaSelectionEntries() {
        guard let item = player.currentItem else {
            subtitleOptions = []
            audioOptions = []
            return
        }
        let selection = item.currentMediaSelection
        if let group = legibleGroup, !group.options.isEmpty {
            let selected = selection.selectedMediaOption(in: group)
            var entries = [
                MediaSelectionEntry(
                    id: MediaSelectionEntry.offIdentifier,
                    title: "オフ",
                    isSelected: selected == nil
                ),
            ]
            entries.append(contentsOf: group.options.enumerated().map { index, option in
                MediaSelectionEntry(
                    id: String(index),
                    title: option.displayName,
                    isSelected: option == selected
                )
            })
            subtitleOptions = entries
        } else {
            subtitleOptions = []
        }
        if let group = audibleGroup, !group.options.isEmpty {
            let selected = selection.selectedMediaOption(in: group)
            audioOptions = group.options.enumerated().map { index, option in
                MediaSelectionEntry(
                    id: String(index),
                    title: option.displayName,
                    isSelected: option == selected
                )
            }
        } else {
            audioOptions = []
        }
    }

    private func beginRequest(program: TVerProgram?, liveChannel: TVerLiveChannel?) {
        requestGeneration += 1
        DiagnosticLogStore.shared.record(
            .info,
            category: "playback",
            message: liveChannel == nil ? "VOD playback request started" : "Live playback request started"
        )
        wantsPlayback = true
        currentProgram = program
        currentLiveChannel = liveChannel
        error = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        resetTimingState()
        transition(to: .resolving)
        configureRemoteCommandsForCurrentItem()
    }

    private func start(url: URL, generation: Int) async throws {
        guard generation == requestGeneration else { return }
        recordPlaybackCheckpoint("Audio session activation started")
        try activateAudioSession()
        recordPlaybackCheckpoint("Audio session activated")
        let item = AVPlayerItem(url: url)
        observeStatus(of: item, generation: generation)
        player.replaceCurrentItem(with: item)
        refreshMediaSelection(for: item)
        recordPlaybackCheckpoint("Player item attached")
        startPlayback()
        transition(to: .resolving)
    }

    /// `rate` is only honoured once playback has started, so the selected
    /// speed is applied right after `play()`.
    private func startPlayback() {
        player.play()
        player.rate = Float(playbackSpeed.rawValue)
    }

    private func observeStatus(of item: AVPlayerItem, generation: Int) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                      generation == self.requestGeneration,
                      item === self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    self.recordPlaybackCheckpoint("Player item ready")
                    self.refreshTimingState()
                    self.updateMediaSelectionEntries()
                    if self.wantsPlayback {
                        self.startPlayback()
                        self.transition(to: .playing)
                    } else {
                        self.transition(to: .paused)
                    }
                case .failed:
                    self.applyPlaybackFailure(item.error ?? TVerClientError.playback("再生項目を読み込めませんでした。"))
                case .unknown:
                    self.transition(to: .resolving)
                @unknown default:
                    self.applyPlaybackFailure(TVerClientError.playback("不明な再生エラーが発生しました。"))
                }
            }
        }
    }

    private func finishWithError(_ sourceError: Error, generation: Int) {
        guard generation == requestGeneration else { return }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.replaceCurrentItem(with: nil)
        wantsPlayback = false
        let normalized = TVerClientError.normalized(from: sourceError, playback: true)
        error = normalized
        transition(to: .failed(normalized))
        recordPlaybackFailure(normalized, phase: "stream-resolution")
    }

    private func applyPlaybackFailure(_ sourceError: Error) {
        let normalized = TVerClientError.normalized(from: sourceError, playback: true)
        wantsPlayback = false
        player.pause()
        error = normalized
        transition(to: .failed(normalized))
        recordPlaybackFailure(normalized, phase: "player")
    }

    private func recordPlaybackCheckpoint(_ message: String) {
        DiagnosticLogStore.shared.record(
            .info,
            category: "playback",
            message: message,
            metadata: ["contentType": isLive ? "live" : "vod"]
        )
    }

    private func recordPlaybackFailure(_ error: TVerClientError, phase: String) {
        DiagnosticLogStore.shared.record(
            .error,
            category: "playback",
            message: "Playback failed",
            metadata: [
                "phase": phase,
                "category": error.presentation.category.rawValue,
                "error": error.localizedDescription,
                "contentType": isLive ? "live" : "vod",
            ]
        )
    }

    private func transition(to newState: PlaybackState, updateNowPlaying: Bool = true) {
        state = newState
        isPlaying = newState == .playing
        if updateNowPlaying { updateNowPlayingInfo() }
    }

    private func activateAudioSession() throws {
        try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
        try audioSession.setActive(true, options: [])
    }

    private func installPlayerObservers() {
        // Twice a second keeps the scrubber smooth without burning CPU.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.handlePeriodicTime(time) }
        }
        endObserver = notificationCenter.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.wantsPlayback = false
                self.transition(to: .ended)
            }
        }
        failedObserver = notificationCenter.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                let sourceError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    ?? TVerClientError.playback("再生を完了できませんでした。")
                self.applyPlaybackFailure(sourceError)
            }
        }
    }

    /// Phone calls, Siri and other apps take the audio session away from us.
    /// Without these observers the player goes silent while `state`,
    /// `isPlaying` and the lock screen keep claiming playback is running, and
    /// nothing ever brings the sound back.
    private func installAudioSessionObservers() {
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let typeRawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let optionsRawValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRawValue: typeRawValue, optionsRawValue: optionsRawValue)
            }
        }
        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let reasonRawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonRawValue: reasonRawValue)
            }
        }
    }

    private func handleInterruption(typeRawValue: UInt, optionsRawValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else { return }
        switch type {
        case .began:
            // The system already stopped the audio; only our state is lying.
            guard wantsPlayback else { return }
            shouldResumeAfterInterruption = true
            wantsPlayback = false
            player.pause()
            transition(to: .paused)
            DiagnosticLogStore.shared.record(
                .warning,
                category: "playback",
                message: "Playback interrupted by the system",
                metadata: ["contentType": isLive ? "live" : "vod"]
            )
        case .ended:
            // One restore per interruption, so a repeated `.ended`
            // notification can never start a second playback.
            guard shouldResumeAfterInterruption else { return }
            shouldResumeAfterInterruption = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
            guard options.contains(.shouldResume) else {
                DiagnosticLogStore.shared.record(
                    .warning,
                    category: "playback",
                    message: "Interruption ended without a resume hint",
                    metadata: ["contentType": isLive ? "live" : "vod"]
                )
                return
            }
            guard player.currentItem != nil else {
                // The stream is still being resolved, so let the pending item
                // start on its own instead of activating a session for nothing.
                wantsPlayback = true
                return
            }
            resume()
            DiagnosticLogStore.shared.record(
                .info,
                category: "playback",
                message: "Playback resumed after an interruption",
                metadata: ["contentType": isLive ? "live" : "vod"]
            )
        @unknown default:
            break
        }
    }

    /// Unplugging headphones or losing a Bluetooth device stops the audio at
    /// the route level. Reporting the pause keeps the transport controls
    /// honest instead of showing a playing state with no sound.
    private func handleRouteChange(reasonRawValue: UInt) {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRawValue) else { return }
        guard reason == .oldDeviceUnavailable, wantsPlayback else { return }
        shouldResumeAfterInterruption = false
        wantsPlayback = false
        player.pause()
        transition(to: .paused)
        DiagnosticLogStore.shared.record(
            .warning,
            category: "playback",
            message: "Playback paused because the audio route disappeared",
            metadata: ["contentType": isLive ? "live" : "vod"]
        )
    }

    /// Published playhead updates, suppressed while the user drags the
    /// scrubber or while a seek is still chasing its target - otherwise the
    /// knob snaps back to where the player used to be.
    private func handlePeriodicTime(_ time: CMTime) {
        refreshTimingState()
        guard !isScrubbing, !isSeekInProgress else { return }
        let seconds = time.seconds
        if seconds.isFinite { currentTime = max(0, seconds) }
        updateNowPlayingInfo(elapsed: currentTime)
    }

    /// True when the playhead already reached the end of a finite item.
    private func hasPlayedToEnd(_ item: AVPlayerItem) -> Bool {
        guard !isLive else { return false }
        if state == .ended { return true }
        let duration = item.duration.seconds
        let current = item.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite else { return false }
        return current >= duration - 0.05
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        let play = center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        let pause = center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        let toggle = center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayback() }; return .success }
        let seek = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return self?.isLive == true ? .commandFailed : .success
        }
        remoteTargets = [(center.playCommand, play), (center.pauseCommand, pause), (center.togglePlayPauseCommand, toggle), (center.changePlaybackPositionCommand, seek)]
        configureRemoteCommandsForCurrentItem()
    }

    private func configureRemoteCommandsForCurrentItem() {
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !isLive
    }

    private func updateNowPlayingInfo(elapsed: TimeInterval? = nil) {
        let title: String
        let album: String
        let artist: String
        if let live = currentLiveChannel {
            title = live.currentProgram?.seriesTitle ?? "TVer リアルタイム配信"
            album = live.currentProgram?.title ?? "ライブ配信"
            artist = live.name
        } else if let program = currentProgram {
            title = program.title
            album = program.seriesTitle
            artist = program.seriesTitle
        } else { return }

        let currentTime = elapsed ?? player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: album,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackSpeed.rawValue : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive
        ]
        if !isLive {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime.isFinite ? max(0, currentTime) : 0
            if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
