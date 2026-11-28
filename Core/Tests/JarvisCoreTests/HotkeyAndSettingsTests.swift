import Carbon.HIToolbox
import Foundation
import Testing

@testable import JarvisCore

@Suite struct HotkeyTests {
    @Test func codableRoundTrip() throws {
        let h = Hotkey(keyCode: 12, modifiers: Hotkey.cmd | Hotkey.shift)
        let data = try JSONEncoder().encode(h)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == h)
    }

    @Test func displayShowsModifiers() {
        let h = Hotkey(keyCode: UInt32(kVK_Space), modifiers: Hotkey.cmd | Hotkey.option)
        #expect(h.display == "⌥⌘Space")
    }
}

@Suite struct SettingsTests {
    @Test @MainActor func languageHintFollowsSettings() {
        let suite = "JarvisTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.languageHint == .auto)
        store.preferredLanguages = ["cs", "en"]
        #expect(store.languageHint == .autoAmong(["cs", "en"]))
        store.language = "cs"
        #expect(store.languageHint == .fixed("cs"))
    }
}
