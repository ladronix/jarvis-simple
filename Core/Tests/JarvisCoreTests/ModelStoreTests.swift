import CryptoKit
import Foundation
import Testing

@testable import JarvisCore

@Suite("Model store")
struct ModelStoreTests {
    /// A local "hub" laid out like Hugging Face (`<repo>/resolve/<revision>/<folder>/<file>`),
    /// served through file URLs, and an empty download base.
    struct Fixture {
        let root: URL
        var hub: URL { root.appendingPathComponent("hub", isDirectory: true) }
        var base: URL { root.appendingPathComponent("base", isDirectory: true) }
        let source: ModelSource

        init(files: [String: String]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let entries = files.sorted { $0.key < $1.key }.map { path, content in
                ModelFile(path: path, size: Int64(content.utf8.count), sha256: Self.sha(content))
            }
            source = ModelSource(
                repo: "test/model", revision: String(repeating: "a", count: 40), remoteFolder: "variant",
                localFolder: "models/test/model/variant", files: entries)
            for (path, content) in files { try serve(path, content) }
        }

        func serve(_ path: String, _ content: String) throws {
            let url = hub.appendingPathComponent("test/model/resolve/\(source.revision)/variant/\(path)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }

        func local(_ path: String) -> URL { source.localURL(base: base).appendingPathComponent(path) }

        static func sha(_ content: String) -> String {
            SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    @Test func downloadsVerifiesAndMarks() async throws {
        let f = try Fixture(files: ["config.json": "{}", "Model.mlmodelc/weights/weight.bin": "weights"])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(!ModelStore.isReady([f.source], base: f.base))

        try await ModelStore.ensure([f.source], base: f.base, hub: f.hub)

        #expect(ModelStore.isReady([f.source], base: f.base))
        #expect(try String(contentsOf: f.local("Model.mlmodelc/weights/weight.bin"), encoding: .utf8) == "weights")
        #expect(!FileManager.default.fileExists(atPath: f.local("config.json.part").path))
    }

    @Test func replacesACorruptedFile() async throws {
        let f = try Fixture(files: ["config.json": "{}", "weight.bin": "good"])
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await ModelStore.ensure([f.source], base: f.base, hub: f.hub)

        // Damage a file and drop the marker, as after an interrupted or tampered copy.
        try Data("evil".utf8).write(to: f.local("weight.bin"))
        try FileManager.default.removeItem(at: f.local(ModelStore.markerName))
        #expect(try ModelStore.invalidFiles(f.source, base: f.base).map(\.path) == ["weight.bin"])

        try await ModelStore.ensure([f.source], base: f.base, hub: f.hub)
        #expect(try String(contentsOf: f.local("weight.bin"), encoding: .utf8) == "good")
        #expect(ModelStore.isReady([f.source], base: f.base))
    }

    @Test func rejectsTamperedDownload() async throws {
        let f = try Fixture(files: ["weight.bin": "good"])
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.serve("weight.bin", "evil")  // same size, different content

        await #expect(throws: ModelStoreError.checksumMismatch("weight.bin")) {
            try await ModelStore.ensure([f.source], base: f.base, hub: f.hub)
        }
        #expect(!FileManager.default.fileExists(atPath: f.local("weight.bin").path))
        #expect(!ModelStore.isReady([f.source], base: f.base))
    }

    @Test func markerFromAnotherManifestIsNotTrusted() async throws {
        let f = try Fixture(files: ["weight.bin": "good"])
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await ModelStore.ensure([f.source], base: f.base, hub: f.hub)
        try Data("something else".utf8).write(to: f.local(ModelStore.markerName))
        #expect(!ModelStore.isReady([f.source], base: f.base))
    }

    @Test func pinnedSourcesAreWellFormed() {
        let sources = WhisperModel.catalog.flatMap(\.sources) + [.sileroVAD]
        let hex = /^[0-9a-f]+$/
        for source in sources {
            #expect(source.revision.count == 40 && source.revision.wholeMatch(of: hex) != nil, "\(source.repo)")
            #expect(!source.files.isEmpty)
            #expect(Set(source.files.map(\.path)).count == source.files.count)
            for file in source.files {
                #expect(file.sha256.count == 64 && file.sha256.wholeMatch(of: hex) != nil, "\(file.path)")
                #expect(!file.path.hasPrefix("/") && !file.path.split(separator: "/").contains(".."), "\(file.path)")
                #expect(file.size > 0)
            }
        }
        for model in WhisperModel.catalog {
            #expect(model.sources[0].remoteFolder == model.variant)
        }
    }
}
