import Foundation
import Network
import Observation
import WhisperKit

/// Loads and switches speech models, reporting progress for the UI. Owns the live transcriber and
/// the VAD chunker. Model loading happens off the main thread; only status updates hop back.
@MainActor
@Observable
public final class ModelManager {
    public enum Status: Sendable, Equatable {
        case idle
        case downloading(Double)  // 0...1
        case loading  // CoreML compile / ANE specialization
        case ready
        case failed(String)

        public var isReady: Bool { self == .ready }
        public var label: String {
            switch self {
            case .idle: return "Not loaded"
            case .downloading(let p): return "Downloading \(Int(p * 100)) %"
            case .loading: return "Preparing model…"
            case .ready: return "Ready"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    public private(set) var status: Status = .idle
    public private(set) var loadedModel: WhisperModel?
    public private(set) var transcriber: WhisperKitTranscriber?
    public private(set) var chunker: VADChunker?
    public private(set) var lastLoadSeconds: Double = 0

    private var loadTask: Task<Void, Never>?
    private var vadConfig: VADChunker.Config

    public init(vadConfig: VADChunker.Config = VADChunker.Config()) {
        self.vadConfig = vadConfig
    }

    /// Written into the model folder after a download finished. Without it the folder may hold a
    /// partial download (quit, network drop, full disk), which must be resumed, not loaded.
    static let completeMarker = ".jarvis-download-complete"

    /// Free space needed before a first download: the model plus the CoreML compile cache.
    static let requiredFreeBytes: Int64 = 3_000_000_000

    public static func isDownloaded(_ model: WhisperModel) -> Bool {
        let folder = Self.folder(for: model)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(completeMarker).path) { return true }
        // Downloads from builds that did not write the marker: accept them when every component is
        // there (the large weight files arrive last), and record that.
        let required = [
            "config.json",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/weights/weight.bin",
        ]
        guard required.allSatisfy({ fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) else {
            return false
        }
        markComplete(folder)
        return true
    }

    static func markComplete(_ folder: URL) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(completeMarker).path, contents: Data())
    }

    /// Where FluidAudio keeps the voice activity model (~/Library/Application Support/FluidAudio).
    public static var vadModelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// Delete every downloaded model (speech and voice activity).
    public static func deleteAllModels() {
        try? FileManager.default.removeItem(at: WhisperModel.defaultDownloadBase)
        try? FileManager.default.removeItem(at: vadModelFolder)
    }

    public static func folder(for model: WhisperModel) -> URL {
        WhisperModel.defaultDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.variant)", isDirectory: true)
    }

    /// Load `model` (download first if needed). Cancels a load in flight. Safe to call repeatedly.
    public func load(_ model: WhisperModel) {
        if loadedModel == model, status.isReady { return }
        loadTask?.cancel()
        lastFailure = nil
        status = Self.isDownloaded(model) ? .loading : .downloading(0)
        let vadConfig = vadConfig
        let previous = transcriber
        loadTask = Task { [weak self] in
            // `self` is a weak var here; nested closures need an immutable copy.
            let owner: ModelManager? = self
            let started = Date()
            do {
                let folder: URL
                if Self.isDownloaded(model) {
                    folder = Self.folder(for: model)
                } else {
                    try Self.checkFreeSpace()
                    // Files already on disk are skipped, so an interrupted download resumes.
                    folder = try await WhisperKit.download(
                        variant: model.variant,
                        downloadBase: WhisperModel.defaultDownloadBase,
                        progressCallback: { progress in
                            let fraction = progress.fractionCompleted
                            Task { @MainActor in
                                if case .downloading = owner?.status { owner?.status = .downloading(fraction) }
                            }
                        }
                    )
                    Self.markComplete(folder)
                }
                try Task.checkCancellation()
                await MainActor.run { owner?.status = .loading }

                var options = WhisperKitTranscriber.Options()
                options.model = model
                options.modelFolder = folder
                let transcriber = WhisperKitTranscriber(options: options)
                async let chunkerLoad = VADChunker.make(config: vadConfig)
                try await transcriber.warmUp()
                let chunker = try await chunkerLoad
                try Task.checkCancellation()
                await previous?.unload()

                await MainActor.run {
                    guard let owner else { return }
                    owner.transcriber = transcriber
                    owner.chunker = chunker
                    owner.loadedModel = model
                    owner.lastLoadSeconds = Date().timeIntervalSince(started)
                    owner.status = .ready
                    Log.models.info(
                        "model \(model.variant, privacy: .public) ready in \(owner.lastLoadSeconds, privacy: .public) s"
                    )
                }
            } catch is CancellationError {
                // superseded by a newer load
            } catch {
                let failure = LoadFailure(error)
                await MainActor.run {
                    owner?.status = .failed(failure.message)
                    owner?.lastFailure = failure
                    Log.models.error("model load failed: \(String(describing: error), privacy: .public)")
                    if failure == .offline { owner?.retryWhenOnline(model) }
                }
            }
        }
    }

    /// Rebuild the chunker with new VAD parameters (cheap; the VAD model is tiny).
    public func updateVAD(_ config: VADChunker.Config) {
        vadConfig = config
        guard status.isReady else { return }
        Task { [weak self] in
            if let chunker = try? await VADChunker.make(config: config) {
                await MainActor.run { self?.chunker = chunker }
            }
        }
    }

    /// Why the last load failed, so the UI can offer the right action.
    public private(set) var lastFailure: LoadFailure?

    public enum LoadFailure: Sendable, Equatable {
        case offline
        case diskFull
        case other(String)

        init(_ error: Error) {
            if let e = error as? URLError {
                switch e.code {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                    .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                    self = .offline
                    return
                default: break
                }
            }
            if error is DiskSpaceError {
                self = .diskFull
                return
            }
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            {
                self = .diskFull
                return
            }
            self = .other(String(describing: error))
        }

        public var message: String {
            switch self {
            case .offline:
                return
                    "No internet connection. The speech model (about 1.6 GB) downloads once; Jarvis retries when you are back online."
            case .diskFull:
                return "Not enough disk space. The speech model needs about 3 GB free; free up space and press Retry."
            case .other(let m): return m
            }
        }
    }

    struct DiskSpaceError: Error {}

    static func checkFreeSpace() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < requiredFreeBytes {
            throw DiskSpaceError()
        }
    }

    private var pathMonitor: NWPathMonitor?

    /// Wait for the network and load again (first run without internet).
    private func retryWhenOnline(_ model: WhisperModel) {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.lastFailure == .offline else { return }
                self.pathMonitor?.cancel()
                self.pathMonitor = nil
                Log.models.info("network is back, retrying model download")
                self.load(model)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.ladronix.jarvis.network"))
    }

    /// Delete this model's files and download it again (a damaged or partial download).
    public func redownload(_ model: WhisperModel) {
        unload()
        try? FileManager.default.removeItem(at: Self.folder(for: model))
        load(model)
    }

    public func unload() {
        loadTask?.cancel()
        let t = transcriber
        transcriber = nil
        chunker = nil
        loadedModel = nil
        status = .idle
        Task { await t?.unload() }
    }
}
