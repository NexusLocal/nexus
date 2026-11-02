import Foundation
import Testing
@testable import NexusCommands
import NexusCore

struct ToolInvocationTests {
    @Test func aLinkWithTheNameOfAToolRunsThatTool() {
        let invocation = NexusCLI.toolInvocation(["/Users/me/Library/Application Support/Nexus/bin/php", "-v"])

        #expect(invocation == NexusCLI.ToolInvocation(tool: .php, arguments: ["-v"], throughLink: true))
    }

    @Test func nexusWithAToolGivesTheToolEveryArgument() {
        let invocation = NexusCLI.toolInvocation(["/Applications/Nexus.app/Contents/Helpers/nexus", "composer", "--help", "install"])

        #expect(invocation == NexusCLI.ToolInvocation(tool: .composer, arguments: ["--help", "install"], throughLink: false))
    }

    @Test func anotherCommandGoesToTheParser() {
        #expect(NexusCLI.toolInvocation(["/Applications/Nexus.app/Contents/Helpers/nexus", "status"]) == nil)
        #expect(NexusCLI.toolInvocation(["nexus"]) == nil)
        #expect(NexusCLI.toolInvocation(["nexus", "site", "edit", "shop.test", "--node", "24"]) == nil)
    }

    @Test func withoutNexusdALinkFindsTheNextProgramOnThePath() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Nexus Path \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let nexus = root.appending(path: "Nexus.app/Contents/Helpers/nexus")
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nexus.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: nexus)
        try Data("#!/bin/sh\n".utf8).write(to: other.appending(path: "php"))
        for file in [nexus, other.appending(path: "php")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        try CommandLinks.write(in: bin, command: nexus)
        let path = [bin, root.appending(path: "missing"), other].map { $0.path(percentEncoded: false) }.joined(separator: ":")

        let php = NexusCLI.nextProgram(named: "php", path: path, nexus: RealPath.of(nexus))
        let node = NexusCLI.nextProgram(named: "node", path: path, nexus: RealPath.of(nexus))

        #expect(php == other.appending(path: "php").path(percentEncoded: false))
        #expect(node == nil)
        #expect(NexusCLI.path(path, without: RealPath.of(nexus)) == [root.appending(path: "missing"), other].map { $0.path(percentEncoded: false) }.joined(separator: ":"))
    }
}
