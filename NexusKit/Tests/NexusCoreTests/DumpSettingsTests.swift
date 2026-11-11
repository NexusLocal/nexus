import Foundation
import NexusCore
import Testing

struct DumpSettingsTests {
    @Test func theDefaultsCatchDumpsAndCommandsWithTheAutomaticPageMode() {
        let settings = DumpSettings()

        #expect(settings.catchDumps)
        #expect(settings.pageMode == .automatic)
        #expect(settings.commands)
    }

    @Test func anOldFileWithoutTheKeysGetsTheDefaults() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data("{}".utf8))

        #expect(settings == DumpSettings())
    }

    @Test func aSettingThatTheFileDoesNotHaveGetsItsDefault() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data(#"{"commands":false}"#.utf8))

        #expect(settings == DumpSettings(catchDumps: true, pageMode: .automatic, commands: false))
    }

    @Test func anUnknownPageModeGetsTheDefault() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data(#"{"catchDumps":false,"pageMode":"sometimes"}"#.utf8))

        #expect(settings == DumpSettings(catchDumps: false, pageMode: .automatic, commands: true))
    }

    @Test(arguments: DumpPageMode.allCases)
    func theSettingsSurviveARoundTrip(pageMode: DumpPageMode) throws {
        let settings = DumpSettings(catchDumps: false, pageMode: pageMode, commands: false)

        let decoded = try JSONDecoder().decode(DumpSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded == settings)
    }

    @Test func theFileHoldsOnlyTheThreeSettings() throws {
        let data = try JSONEncoder().encode(DumpSettings())

        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys

        #expect(Set(keys) == ["catchDumps", "pageMode", "commands"])
    }
}
