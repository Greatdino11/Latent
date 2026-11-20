import Photos

/// Keeps the roll in step with the photo library: a frame whose saved copy is deleted in Photos leaves the roll
/// (into a 30-day trash), and comes back if the photo is restored from Recently Deleted.
///
/// Only runs with full library access: with limited access, photos outside the selection look "missing" and
/// would wrongly empty the roll.
@MainActor
final class PhotosSync: NSObject, PHPhotoLibraryChangeObserver {
    private let roll: RollStore
    private var observing = false
    private var pending: Task<Void, Never>?

    init(roll: RollStore) { self.roll = roll }

    static var hasFullAccess: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    /// Call at launch and when the app comes back to the foreground.
    func refresh() {
        guard Self.hasFullAccess else { return }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        roll.purgeTrash()
        reconcile()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleReconcile() }
    }

    private func scheduleReconcile() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(0.8))     // a delete of many photos arrives as a burst
            guard !Task.isCancelled else { return }
            reconcile()
        }
    }

    private func reconcile() {
        guard Self.hasFullAccess else { return }
        let linked = roll.items.compactMap { item in roll.photosID(for: item).map { (item, $0) } }
        let trashed = roll.trashedPhotoLinks()
        let ids = linked.map(\.1) + trashed.map(\.photosID)
        guard !ids.isEmpty else { return }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true                 // hidden in Photos isn't deleted
        var present = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options).enumerateObjects { asset, _, _ in
            present.insert(asset.localIdentifier)
        }
        let gone = linked.filter { !present.contains($0.1) }
        // If every linked photo seems to have vanished at once, the library is more likely unavailable (being
        // restored, signed out of iCloud) than emptied by hand: leave the roll alone.
        if gone.count == linked.count, linked.count > 5 { return }
        for (item, _) in gone { roll.trash(item) }
        for t in trashed where present.contains(t.photosID) { roll.restore(base: t.base) }
    }
}
