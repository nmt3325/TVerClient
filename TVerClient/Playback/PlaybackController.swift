import AVFoundation
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentProgram: TVerProgram?
    @Published private(set) var isPlaying = false
    let player = AVPlayer()

    func play(_ program: TVerProgram) async {
        currentProgram = program
        isPlaying = false
    }

    func togglePlayback() {
        isPlaying.toggle()
        isPlaying ? player.play() : player.pause()
    }
}
