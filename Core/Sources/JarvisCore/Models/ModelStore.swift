import CryptoKit
import Foundation

/// One file of a pinned model, as recorded by `scripts/model-manifest.py`.
public struct ModelFile: Sendable, Hashable {
    public let path: String
    public let size: Int64
    public let sha256: String
}

/// Files from one Hugging Face repository at a fixed commit, kept in one local folder.
public struct ModelSource: Sendable, Hashable {
    public let repo: String
    /// Full commit hash. Files are fetched from this commit only, never from a moving branch.
    public let revision: String
    /// Folder inside the repository ("" for the root).
    public let remoteFolder: String
    /// Folder under the download base where the files live.
    public let localFolder: String
    public let files: [ModelFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public func localURL(base: URL) -> URL {
        base.appendingPathComponent(localFolder, isDirectory: true)
    }

    func remoteURL(for file: ModelFile, hub: URL) -> URL {
        var url = hub.appendingPathComponent(repo).appendingPathComponent("resolve").appendingPathComponent(revision)
        if !remoteFolder.isEmpty { url = url.appendingPathComponent(remoteFolder) }
        return url.appendingPathComponent(file.path)
    }

    /// Identifies exactly which files were verified; stored in the folder's marker file.
    var fingerprint: String {
        var lines = ["\(repo)@\(revision)/\(remoteFolder)"]
        lines += files.map { "\($0.path) \($0.size) \($0.sha256)" }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ModelStoreError: Error, CustomStringConvertible, Equatable {
    case checksumMismatch(String)
    case httpStatus(Int, String)
    case insecureRedirect(String)
    case notEnoughSpace(neededBytes: Int64)

    public var description: String {
        switch self {
        case .checksumMismatch(let path):
            return "A downloaded model file failed its integrity check (\(path)). It was deleted; press Retry."
        case .httpStatus(let code, let path): return "Model download failed with HTTP \(code) (\(path))."
        case .insecureRedirect(let host): return "Model download was redirected to an insecure address (\(host))."
        case .notEnoughSpace: return "Not enough disk space for the model download."
        }
    }
}

/// Downloads pinned model files and verifies their SHA-256 before anything loads them.
///
/// A folder counts as ready only when its marker holds the source's fingerprint, written after
/// every file matched its recorded size and hash. Files that are missing or do not match are
/// (re)downloaded from the pinned commit. This protects against tampered or swapped files on the
/// network path and on the hosting side; it does not try to defend against other software running
/// as the same user, which could change the app's files as well.
public enum ModelStore {
    static let markerName = ".jarvis-verified"
    public static let hub = URL(string: "https://huggingface.co")!
    /// Headroom beyond the download itself: CoreML writes a compiled cache on first load.
    static let extraFreeBytes: Int64 = 1_500_000_000

    public enum Phase: Sendable, Equatable {
        case verifying
        case downloading(Double)  // 0...1
    }

    /// Whether every source is present and was verified (cheap: reads marker files only).
    public static func isReady(_ sources: [ModelSource], base: URL = WhisperModel.defaultDownloadBase) -> Bool {
        sources.allSatisfy { isVerified($0, base: base) }
    }

    static func isVerified(_ source: ModelSource, base: URL) -> Bool {
        let marker = source.localURL(base: base).appendingPathComponent(markerName)
        guard let content = try? String(contentsOf: marker, encoding: .utf8) else { return false }
        return content == source.fingerprint
    }

    /// Make every source ready: verify what is on disk, download what is missing or wrong.
    /// Runs off the main actor; `progress` is called from background threads.
    @concurrent
    public static func ensure(
        _ sources: [ModelSource],
        base: URL = WhisperModel.defaultDownloadBase,
        hub: URL = ModelStore.hub,
        progress: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws {
        let unverified = sources.filter { !isVerified($0, base: base) }
        guard !unverified.isEmpty else { return }
        progress(.verifying)

        var pending: [(ModelSource, ModelFile)] = []
        for source in unverified {
            try Task.checkCancellation()
            for file in try invalidFiles(source, base: base) { pending.append((source, file)) }
        }

        if !pending.isEmpty {
            let needed = pending.reduce(Int64(0)) { $0 + $1.1.size }
            try checkFreeSpace(base: base, needed: needed + extraFreeBytes)
            progress(.downloading(0))
            let downloader = ModelDownloader()
            defer { downloader.finish() }
            var done: Int64 = 0
            for (source, file) in pending {
                try Task.checkCancellation()
                let completed = done
                try await fetch(file, of: source, base: base, hub: hub, downloader: downloader) { written in
                    progress(.downloading(min(1, Double(completed + written) / Double(needed))))
                }
                done += file.size
            }
        }

        for source in unverified {
            let folder = source.localURL(base: base)
            try Data(source.fingerprint.utf8).write(to: folder.appendingPathComponent(markerName), options: .atomic)
            // Marker of earlier versions, which did not verify hashes.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(".jarvis-download-complete"))
            Log.models.info(
                "verified \(source.repo, privacy: .public)/\(source.remoteFolder, privacy: .public) @ \(source.revision.prefix(12), privacy: .public)"
            )
        }
    }

    /// Delete a source's files so the next `ensure` downloads them again.
    public static func remove(_ sources: [ModelSource], base: URL = WhisperModel.defaultDownloadBase) {
        for source in sources { try? FileManager.default.removeItem(at: source.localURL(base: base)) }
    }

    // MARK: - Verification

    /// Files that are missing or differ from the manifest. Files that differ are deleted.
    static func invalidFiles(_ source: ModelSource, base: URL) throws -> [ModelFile] {
        let folder = source.localURL(base: base)
        let fm = FileManager.default
        var invalid: [ModelFile] = []
        for file in source.files {
            let url = folder.appendingPathComponent(file.path)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                (attributes[.size] as? NSNumber)?.int64Value == file.size,
                (try? sha256(of: url)) == file.sha256
            else {
                if fm.fileExists(atPath: url.path) {
                    Log.models.notice("model file does not match, downloading again: \(file.path, privacy: .public)")
                    try? fm.removeItem(at: url)
                }
                invalid.append(file)
                continue
            }
        }
        return invalid
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download

    private static func fetch(
        _ file: ModelFile, of source: ModelSource, base: URL, hub: URL, downloader: ModelDownloader,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let destination = source.localURL(base: base).appendingPathComponent(file.path)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        try? fm.removeItem(at: partial)
        defer { try? fm.removeItem(at: partial) }

        try await downloader.download(source.remoteURL(for: file, hub: hub), to: partial, progress: progress)
        guard try sha256(of: partial) == file.sha256 else {
            Log.models.error("checksum mismatch for \(source.repo, privacy: .public)/\(file.path, privacy: .public)")
            throw ModelStoreError.checksumMismatch(file.path)
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
    }

    static func checkFreeSpace(base: URL, needed: Int64) throws {
        var probe = base
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
            throw ModelStoreError.notEnoughSpace(neededBytes: needed)
        }
    }
}
