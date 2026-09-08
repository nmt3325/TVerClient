import Foundation
import SwiftUI

/// The playback session, not a disappearing view, owns an in-flight PiP.
/// No coordinator retains itself: entries survive only while a surface owns
/// them or the coordinator's exact layer-retention contract requires them.
@MainActor
final class PlaybackPictureInPictureOwnership {
    private final class Entry {
        let coordinator: PictureInPictureCoordinator
        // nil is the source-compatible legacy owner; it is idempotent too.
        var owners: Set<UUID?> = []

        init(_ coordinator: PictureInPictureCoordinator) {
            self.coordinator = coordinator
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func bind(
        _ coordinator: PictureInPictureCoordinator,
        owner: UUID?,
        restore: @escaping () -> Void
    ) {
        // An owner moving to another coordinator relinquishes only its old
        // claim; an old PiP transition may still need that retired entry.
        for entry in Array(entries.values) where entry.coordinator !== coordinator {
            entry.owners.remove(owner)
            releaseIfUnneeded(entry.coordinator)
        }
        let key = ObjectIdentifier(coordinator)
        let entry = entries[key] ?? Entry(coordinator)
        entry.owners.insert(owner)
        entries[key] = entry
        coordinator.restoresUserInterface = restore
        coordinator.playbackRetentionDidChange = { [weak self, weak coordinator] in
            guard let coordinator else { return }
            self?.releaseIfUnneeded(coordinator)
        }
    }

    func unbind(_ coordinator: PictureInPictureCoordinator, owner: UUID?) {
        guard let entry = entries[ObjectIdentifier(coordinator)],
              entry.owners.remove(owner) != nil else { return }
        releaseIfUnneeded(coordinator)
    }

    func stopAll() {
        // Delegate callbacks can synchronously remove entries while stopping.
        for entry in Array(entries.values) {
            entry.coordinator.stop()
            releaseIfUnneeded(entry.coordinator)
        }
    }

    private func releaseIfUnneeded(_ coordinator: PictureInPictureCoordinator) {
        let key = ObjectIdentifier(coordinator)
        guard let entry = entries[key], entry.owners.isEmpty,
              !coordinator.requiresPlaybackRetention else { return }
        coordinator.playbackRetentionDidChange = nil
        coordinator.restoresUserInterface = nil
        entries.removeValue(forKey: key)
    }
}

/// A stable, per-surface scope makes duplicate appear/disappear calls harmless
/// and prevents a departing inline surface from unbinding the full-screen one.
@MainActor
struct PlaybackPictureInPictureSurfaceBinding: ViewModifier {
    let controller: PlaybackController
    let coordinator: PictureInPictureCoordinator
    let isEnabled: Bool
    @State private var owner = UUID()

    init(
        controller: PlaybackController,
        coordinator: PictureInPictureCoordinator,
        isEnabled: Bool = true
    ) {
        self.controller = controller
        self.coordinator = coordinator
        self.isEnabled = isEnabled
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard isEnabled else { return }
                controller.bindPictureInPicture(coordinator, owner: owner)
            }
            .onDisappear {
                controller.unbindPictureInPicture(coordinator, owner: owner)
            }
    }
}
