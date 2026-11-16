import ArgumentParser
import Testing
@testable import NexusCommands

struct WorkspaceListTests {
    private func parse(_ arguments: [String]) throws -> any ParsableCommand {
        try NexusCommand.parseAsRoot(arguments)
    }

    @Test func oldAndDaysGiveTheListOfOldWorkspaces() throws {
        let list = try #require(try parse(["workspace", "list", "--old", "--days", "3"]) as? WorkspaceCommand.List)

        #expect(list.old)
        #expect(list.days == 3)
        #expect(!list.all)
    }

    @Test func aPlainListHasNoLimit() throws {
        let list = try #require(try parse(["workspace", "list", "--all"]) as? WorkspaceCommand.List)

        #expect(!list.old)
        #expect(list.days == nil)
        #expect(list.all)
    }
}
