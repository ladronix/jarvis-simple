import Foundation
import Network
import Observation

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

    /// Whether the model's files are on disk and verified (no download needed).
    public static func isDownloaded(_ model: WhisperModel) -> Bool {
        ModelStore.isReady(model.sources)
    }

    /// Files a model needs: its CoreML model, its tokenizer and the voice activity model.
    static func sources(for model: WhisperModel) -> [ModelSource] { model.sources + [.sileroVAD] }

    /// Where FluidAudio kept the voice activity model before Jarvis pinned and verified it.
    static var legacyVADFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// Delete every downloaded model (speech and voice activity).
    public static func deleteAllModels() {
        try? FileManager.default.removeItem(at: WhisperModel.defaultDownloadBase)
        try? FileManager.default.removeItem(at: legacyVADFolder)
    }

    /// Load `model` (download first if needed). Cancels a load in flight. Safe to call repeatedly.
    public func load(_ model: WhisperModel) {
        if loadedModel == model, status.isReady { return }
        loadTask?.cancel()
        lastFailure = nil
        // Verifying files already on disk shows as preparing; real downloads switch to progress.
        status = .loading
        let vadConfig = vadConfig
        let previous = transcriber
        loadTask = Task { [weak self] in
            // `self` is a weak var here; nested closures need an immutable copy.
            let owner: ModelManager? = self
            let started = Date()
            do {
                // Verify what is on disk and fetch what is missing, all from pinned commits.
                try await ModelStore.ensure(Self.sources(for: model)) { phase in
                    guard case .downloading(let fraction) = phase else { return }
                    Task { @MainActor in
                        switch owner?.status {
                        case .downloading?, .loading?: owner?.status = .downloading(fraction)
                        default: break
                        }
                    }
                }
                try Task.checkCancellation()
                await MainActor.run { owner?.status = .loading }

                var options = WhisperKitTranscriber.Options()
                options.model = model
                options.modelFolder = model.folder
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
            if case ModelStoreError.notEnoughSpace? = error as? ModelStoreError {
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
        ModelStore.remove(model.sources)
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
