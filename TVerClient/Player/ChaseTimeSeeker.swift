import CoreMedia
import Foundation

/// The chase-time bookkeeping from Apple QA1820.
///
/// Seeking on every drag update cancels the previous seek over and over, so
/// the video never catches up with the finger. Instead only one seek is ever
/// in flight: newer targets are remembered and chased from the completion
/// handler of the running seek.
///
/// Every target carries the tolerance it has to be reached with. A drag asks
/// for a loose tolerance so the picture can keep up with the finger, while the
/// commit on finger lift asks for the exact frame - which is why the very same
/// time can be requested twice and still has to be issued the second time.
struct ChaseTimeSeeker: Equatable {
    private(set) var chaseTime: CMTime = .invalid
    /// Tolerance the current target has to be reached with.
    private(set) var chaseTolerance: CMTime = .zero
    private(set) var isSeekInProgress = false

    /// Records a new target. Returns the time to hand to `AVPlayer`, or nil
    /// when the target adds nothing or a seek is already running.
    mutating func request(_ time: CMTime, tolerance: CMTime = .zero) -> CMTime? {
        guard time.isValid else { return nil }
        // The same position still has to be issued again when it is now
        // wanted more precisely: that is the commit after a loose drag seek.
        if time == chaseTime, tolerance >= chaseTolerance { return nil }
        chaseTime = time
        chaseTolerance = tolerance
        guard !isSeekInProgress else { return nil }
        isSeekInProgress = true
        return time
    }

    /// Reports the seek that just finished. Returns the next target to chase,
    /// or nil once the playhead reached the latest requested time with the
    /// precision that was asked for.
    mutating func complete(_ time: CMTime, tolerance: CMTime = .zero) -> CMTime? {
        guard isSeekInProgress else { return nil }
        guard chaseTime.isValid, time != chaseTime || tolerance != chaseTolerance else {
            isSeekInProgress = false
            return nil
        }
        return chaseTime
    }

    mutating func reset() {
        chaseTime = .invalid
        chaseTolerance = .zero
        isSeekInProgress = false
    }
}
