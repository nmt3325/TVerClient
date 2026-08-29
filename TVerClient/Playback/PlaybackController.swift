import AVFoundation
import Foundation
import MediaPlayer

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentProgram: TVerProgram?
    @Published private(set) var isPlaying = false
    @Published private(set) var error: TVerClientError?

    let player: AVPlayer

    private let resolver: any TVerStreamResolving
    private let audioSession: AVAudioSession
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var remoteTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var requestGeneration = 0

    init(
        resolver: any TVerStreamResolving = BrightcoveStreamResolver(),
        player: AVPlayer = AVPlayer(),
        audioSession: AVAudioSession = .sharedInstance()
    ) {
        self.resolver = resolver
        self.player = player
        self.audioSession = audioSession
        installPlayerObservers()
        installRemoteCommands()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        for entry in remoteTargets {
            entry.command.removeTarget(entry.target)
        }
    }

    var errorMessage: String? {
        error?.localizedDescription
    }

    func play(_ program: TVerProgram) async {
        requestGeneration += 1
        let generation = requestGeneration
        currentProgram = program
        isPlaying = false
        error = nil
        player.pause()
        updateNowPlayingInfo(elapsed: 0)

        do {
            let streamURL = try await resolver.resolveStream(for: program)
            guard generation == requestGeneration else { return }

            try activateAudioSession()
            let item = AVPlayerItem(url: streamURL)
            player.replaceCurrentItem(with: item)
            player.play()
            isPlaying = true
            updateNowPlayingInfo(elapsed: 0)
        } catch {
            guard generation == requestGeneration else { return }
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            self.error = Self.playbackError(from: error)
            updateNowPlayingInfo(elapsed: 0)
        }
    }

    func resume() {
        guard player.currentItem != nil else { return }
        do {
            try activateAudioSession()
            player.play()
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            self.error = Self.playbackError(from: error)
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func stop() {
        requestGeneration += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentProgram = nil
        isPlaying = false
        error = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func togglePlayback() {
        isPlaying ? pause() : resume()
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let target = max(0, seconds)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlayingInfo(elapsed: target)
    }

    func seek(by offset: TimeInterval) {
        let current = player.currentTime().seconds
        seek(to: (current.isFinite ? current : 0) + offset)
    }

    private func activateAudioSession() throws {
        try audioSession.setCategory(.playback, mode: .moviePlayback)
        try audioSession.setActive(true)
    }

    private func installPlayerObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.updateNowPlayingInfo(elapsed: time.seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else {
                    return
                }
                self.isPlaying = false
                self.updateNowPlayingInfo()
            }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        let playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        remoteTargets.append((center.playCommand, playTarget))

        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        remoteTargets.append((center.pauseCommand, pauseTarget))

        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayback() }
            return .success
        }
        remoteTargets.append((center.togglePlayPauseCommand, toggleTarget))

        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in self?.seek(to: event.positionTime) }
            return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, seekTarget))
    }

    private func updateNowPlayingInfo(elapsed: TimeInterval? = nil) {
        guard let program = currentProgram else { return }

        let currentTime = elapsed ?? player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: program.title,
            MPMediaItemPropertyAlbumTitle: program.seriesTitle,
            MPMediaItemPropertyArtist: program.seriesTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime.isFinite ? max(0, currentTime) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private static func playbackError(from error: Error) -> TVerClientError {
        if let error = error as? TVerClientError {
            return error
        }
        return .api(error.localizedDescription)
    }
}
