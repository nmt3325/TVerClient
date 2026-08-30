import CoreMedia
import Foundation

/// The chase-time bookkeeping from Apple QA1820.
///
/// Seeking on every drag update cancels the previous seek over and over, so
/// the video never catches up with the finger. Instead only one seek is ever
/// in flight: newer targets are remembered and chased from the completion
/// handler of the running seek.
struct ChaseTimeSeeker: Equatable {
    private(set) var chaseTime: CMTime = .invalid
    private(set) var isSeekInProgress = false

    /// Records a new target. Returns the time to hand to `AVPlayer`, or nil
    /// when the target is unchanged or a seek is already running.
    mutating func request(_ time: CMTime) -> CMTime? {
        guard time.isValid, time != chaseTime else { return nil }
        chaseTime = time
        guard !isSeekInProgress else { return nil }
        isSeekInProgress = true
        return time
    }

    /// Reports the seek that just finished. Returns the next target to chase,
    /// or nil once the playhead reached the latest requested time.
    mutating func complete(_ time: CMTime) -> CMTime? {
        guard isSeekInProgress else { return nil }
        guard chaseTime.isValid, time != chaseTime else {
            isSeekInProgress = false
            return nil
        }
        return chaseTime
    }

    mutating func reset() {
        chaseTime = .invalid
        isSeekInProgress = false
    }
}
