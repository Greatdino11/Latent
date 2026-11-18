import Foundation

/// A whole roll in one file, for moving it to a reinstalled copy of the app (e.g. via SideStore).
/// Format: "LATROLL1", then for each file: name length (UInt32), UTF-8 name, data length (UInt64), bytes.
/// Written and read one file at a time, so big rolls never sit in memory at once.
enum RollArchive {
    static let fileExtension = "latentroll"
    private static let magic = Data("LATROLL1".utf8)

    enum Failure: LocalizedError {
        case notAnArchive, truncated
        var errorDescription: String? {
            self == .notAnArchive ? "That file isn't a Latent roll." : "The roll file is incomplete."
        }
    }

    /// Writes every roll file (prints, negatives, recipes, Photos links) to a new archive and returns its URL.
    static func export(from folder: URL, progress: (Int, Int) -> Void = { _, _ in }) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("Latent Roll \(stamp.string(from: Date())).\(fileExtension)")
        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.write(contentsOf: magic)
        for (i, file) in files.enumerated() {
            let name = Data(file.lastPathComponent.utf8)
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            try handle.write(contentsOf: withUnsafeBytes(of: UInt32(name.count).littleEndian) { Data($0) })
            try handle.write(contentsOf: name)
            try handle.write(contentsOf: withUnsafeBytes(of: UInt64(data.count).littleEndian) { Data($0) })
            try handle.write(contentsOf: data)
            progress(i + 1, files.count)
        }
        return out
    }

    /// Restores an archive into the roll folder. Existing files are kept; returns how many files were added.
    @discardableResult
    static func importArchive(_ url: URL, into folder: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: magic.count) == magic else { throw Failure.notAnArchive }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = 0
        while let lenData = try handle.read(upToCount: 4), lenData.count == 4 {
            let nameLen = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard nameLen > 0, nameLen < 1024, let nameData = try handle.read(upToCount: nameLen), nameData.count == nameLen,
                  let name = String(data: nameData, encoding: .utf8),
                  let sizeData = try handle.read(upToCount: 8), sizeData.count == 8 else { throw Failure.truncated }
            let size = Int(sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
            let data = size == 0 ? Data() : (try handle.read(upToCount: size) ?? Data())
            guard data.count == size else { throw Failure.truncated }
            // Plain file names only — never let an archive write outside the roll folder.
            let safe = (name as NSString).lastPathComponent
            guard !safe.isEmpty, safe == name, !safe.hasPrefix(".") else { continue }
            let target = folder.appendingPathComponent(safe)
            if !FileManager.default.fileExists(atPath: target.path) {
                try data.write(to: target, options: .atomic)
                added += 1
            }
        }
        return added
    }
}
