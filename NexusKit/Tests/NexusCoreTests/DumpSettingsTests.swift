import Foundation
import NexusCore
import Testing

struct DumpSettingsTests {
    @Test func theDefaultsCatchDumpsLogLinesAndCommandsWithTheAutomaticPageMode() {
        let settings = DumpSettings()

        #expect(settings.catchDumps)
        #expect(!settings.catchQueries)
        #expect(settings.catchLogs)
        #expect(!settings.catchJobs)
        #expect(settings.pageMode == .automatic)
        #expect(settings.commands)
        #expect(settings.catchesAnything)
    }

    @Test func anOldFileWithoutTheKeysGetsTheDefaults() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data("{}".utf8))

        #expect(settings == DumpSettings())
    }

    @Test func aFileOfTheFirstVersionKeepsCatchDumpsOffForTheLogLines() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data(#"{"catchDumps":false,"pageMode":"never","commands":false}"#.utf8))

        #expect(settings == DumpSettings(catchDumps: false, catchQueries: false, catchLogs: false, catchJobs: false, pageMode: .never, commands: false))
        #expect(!settings.catchesAnything)
    }

    @Test func aFileOfTheFirstVersionWithCatchDumpsOnCatchesLogLines() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data(#"{"catchDumps":true,"pageMode":"always","commands":true}"#.utf8))

        #expect(settings.catchLogs)
    }

    @Test func aFileWithItsOwnCatchLogLinesKeepsIt() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data(#"{"catchDumps":false,"catchLogs":true}"#.utf8))

        #expect(settings.catchLogs)
        #expect(!settings.catchDumps)
    }

    @Test(arguments: [
        (DumpSettings(catchDumps: false, catchQueries: false, catchLogs: false, catchJobs: false, pageMode: .automatic, commands: true), false),
        (DumpSettings(catchDumps: false, catchQueries: true, catchLogs: false, catchJobs: false, pageMode: .automatic, commands: true), true),
        (DumpSettings(catchDumps: false, catchQueries: false, catchLogs: true, catchJobs: false, pageMode: .automatic, commands: true), true),
        (DumpSettings(catchDumps: false, catchQueries: false, catchLogs: false, catchJobs: true, pageMode: .automatic, commands: true), true),
        (DumpSettings(catchDumps: true, catchQueries: false, catchLogs: false, catchJobs: false, pageMode: .automatic, commands: true), true),
    ])
    func eachSwitchMakesTheSettingsCatchSomething(settings: DumpSettings, catches: Bool) {
        #expect(settings.catchesAnything == catches)
    }

    @Test func eachKindHasItsSwitch() {
        let settings = DumpSettings(catchDumps: false, catchQueries: true, catchLogs: false, catchJobs: true, pageMode: .automatic, commands: true)

        #expect(!settings.catches(.dump))
        #expect(!settings.catches(.dd))
        #expect(settings.catches(.query))
        #expect(!settings.catches(.log))
        #expect(settings.catches(.job))
    }

    @Test func aSettingThatTheFileDoesNotHaveGetsItsDefault() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data(#"{"commands":false}"#.utf8))

        #expect(settings == DumpSettings(catchDumps: true, pageMode: .automatic, commands: false))
    }

    @Test func anUnknownPageModeGetsTheDefault() throws {
        let settings = try JSONDecoder().decode(DumpSettings.self, from: Data(#"{"catchDumps":false,"pageMode":"sometimes"}"#.utf8))

        #expect(settings == DumpSettings(catchDumps: false, catchLogs: false, pageMode: .automatic, commands: true))
    }

    @Test(arguments: DumpPageMode.allCases)
    func theSettingsSurviveARoundTrip(pageMode: DumpPageMode) throws {
        let settings = DumpSettings(catchDumps: false, catchQueries: true, catchLogs: false, catchJobs: true, pageMode: pageMode, commands: false)

        let decoded = try JSONDecoder().decode(DumpSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded == settings)
    }

    @Test func theFileHoldsOnlyTheSixSettings() throws {
        let data = try JSONEncoder().encode(DumpSettings())

        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys

        #expect(Set(keys) == ["catchDumps", "catchQueries", "catchLogs", "catchJobs", "pageMode", "commands"])
    }
}
