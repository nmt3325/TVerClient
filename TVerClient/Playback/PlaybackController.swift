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

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentProgram: TVerProgram?
    @Published private(set) var currentLiveChannel: TVerLiveChannel?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var error: TVerClientError?

    let player: AVPlayer
    private let resolver: any TVerStreamResolving
    private let liveResolver: any TVerLiveStreamResolving
    private let audioSession: AVAudioSession
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var remoteTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var requestGeneration = 0
    private var wantsPlayback = false

    init(
        resolver: any TVerStreamResolving = BrightcoveStreamResolver(),
        liveResolver: any TVerLiveStreamResolving = LiveStreamResolver(),
        player: AVPlayer = AVPlayer(),
        audioSession: AVAudioSession = .sharedInstance()
    ) {
        self.resolver = resolver
        self.liveResolver = liveResolver
        self.player = player
        self.audioSession = audioSession
        installPlayerObservers()
        installRemoteCommands()
    }

    deinit {
        itemStatusObservation?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        for entry in remoteTargets { entry.command.removeTarget(entry.target) }
    }

    var errorMessage: String? { error?.localizedDescription }
    var errorPresentation: TVerErrorPresentation? { error?.presentation }
    var isLive: Bool { currentLiveChannel != nil }

    func play(_ program: TVerProgram) async {
        beginRequest(program: program, liveChannel: nil)
        let generation = requestGeneration
        do {
            try await start(url: resolver.resolveStream(for: program), generation: generation)
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
            try await start(url: liveResolver.resolveLiveStream(for: channel), generation: generation)
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
            player.play()
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
        player.pause()
        transition(to: .paused)
    }

    func stop() {
        requestGeneration += 1
        wantsPlayback = false
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
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
        let target = max(0, seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlayingInfo(elapsed: target)
    }

    func seek(by offset: TimeInterval) {
        guard !isLive else { return }
        let current = player.currentTime().seconds
        seek(to: (current.isFinite ? current : 0) + offset)
    }

    private func beginRequest(program: TVerProgram?, liveChannel: TVerLiveChannel?) {
        requestGeneration += 1
        wantsPlayback = true
        currentProgram = program
        currentLiveChannel = liveChannel
        error = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        transition(to: .resolving)
        configureRemoteCommandsForCurrentItem()
    }

    private func start(url: URL, generation: Int) async throws {
        guard generation == requestGeneration else { return }
        try activateAudioSession()
        let item = AVPlayerItem(url: url)
        observeStatus(of: item, generation: generation)
        player.replaceCurrentItem(with: item)
        player.play()
        transition(to: .resolving)
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
                    if self.wantsPlayback {
                        self.player.play()
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
    }

    private func applyPlaybackFailure(_ sourceError: Error) {
        let normalized = TVerClientError.normalized(from: sourceError, playback: true)
        wantsPlayback = false
        player.pause()
        error = normalized
        transition(to: .failed(normalized))
    }

    private func transition(to newState: PlaybackState, updateNowPlaying: Bool = true) {
        state = newState
        isPlaying = newState == .playing
        if updateNowPlaying { updateNowPlayingInfo() }
    }

    private func activateAudioSession() throws {
        try audioSession.setCategory(.playback, mode: .moviePlayback)
        try audioSession.setActive(true)
    }

    private func installPlayerObservers() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.updateNowPlayingInfo(elapsed: time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.wantsPlayback = false
                self.transition(to: .ended)
            }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                let sourceError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    ?? TVerClientError.playback("再生を完了できませんでした。")
                self.applyPlaybackFailure(sourceError)
            }
        }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
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
