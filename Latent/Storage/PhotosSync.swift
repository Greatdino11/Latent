import Photos

/// Keeps the roll in step with the photo library: a frame whose saved copy the user deletes in Photos leaves the
/// roll (into a trash they can see and restore from), and comes back if the photo is restored from Recently Deleted.
///
/// Only *real deletions* count: they're read from the library's persistent change history since the last check.
/// A link that merely doesn't resolve — another iPhone, a restored backup, an imported roll — is never treated as
/// a deletion, and nothing is ever deleted for good without the user asking.
@MainActor
final class PhotosSync: NSObject, PHPhotoLibraryChangeObserver {
    private let roll: RollStore
    private var observing = false
    private var pending: Task<Void, Never>?
    /// Told how many frames just moved to the trash, so the user hears about it.
    var onRemoved: ((Int) -> Void)?
    private static let tokenKey = "photosChangeToken"

    init(roll: RollStore) { self.roll = roll }

    static var hasFullAccess: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    /// Call at launch and when the app comes back to the foreground.
    func refresh() {
        guard Self.hasFullAccess else { return }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        sync()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleSync() }
    }

    private func scheduleSync() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(0.8))     // a delete of many photos arrives as a burst
            guard !Task.isCancelled else { return }
            sync()
        }
    }

    private func sync() {
        guard Self.hasFullAccess else { return }
        let library = PHPhotoLibrary.shared()
        var deleted = Set<String>()
        if let saved = loadToken() {
            do {
                for change in try library.fetchPersistentChanges(since: saved) {
                    if let details = try? change.changeDetails(for: .asset) { deleted.formUnion(details.deletedLocalIdentifiers) }
                }
            } catch {
                // A token from another library (new phone, restored backup) or too old to read: start afresh and
                // remove nothing.
                deleted = []
            }
        }
        saveToken(library.currentChangeToken)

        let linked = roll.items.compactMap { item in roll.photosID(for: item).map { (base: item.base, photosID: $0) } }
        let trashed = roll.trashedPhotoLinks()
        var present = Set<String>()
        if !trashed.isEmpty {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            PHAsset.fetchAssets(withLocalIdentifiers: trashed.map(\.photosID), options: options)
                .enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        }
        let plan = Self.plan(linked: linked, deleted: deleted, trashed: trashed, present: present)
        for base in plan.trash { if let item = roll.item(id: base) { roll.trash(item) } }
        for base in plan.restore { roll.restore(base: base) }
        if !plan.trash.isEmpty { onRemoved?(plan.trash.count) }
    }

    /// What to do, decided from facts alone (so it can be tested): trash frames whose photo was *reported deleted*,
    /// restore trashed frames whose photo is back.
    nonisolated static func plan(linked: [(base: String, photosID: String)], deleted: Set<String>,
                                 trashed: [(base: String, photosID: String)], present: Set<String>) -> (trash: [String], restore: [String]) {
        let trash = linked.filter { deleted.contains($0.photosID) }.map(\.base)
        let restore = trashed.filter { present.contains($0.photosID) && !deleted.contains($0.photosID) }.map(\.base)
        return (trash, restore)
    }

    private func loadToken() -> PHPersistentChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func saveToken(_ token: PHPersistentChangeToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.tokenKey)
        }
    }
}
