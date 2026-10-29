import Foundation
import Testing
@testable import NexusCore

struct CommandLinksTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Links \(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func eachToolGetsALinkToTheNexusCommand() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let command = root.appending(path: "Nexus.app/Contents/Helpers/nexus")

        try CommandLinks.write(in: bin, command: command)

        for name in ["nexus", "php", "composer", "node", "npm"] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: name).path(percentEncoded: false)) == command.path(percentEncoded: false))
        }
    }

    @Test func aLinkToAnOldPlaceOrAFileGetsReplaced() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appending(path: "php").path(percentEncoded: false), withDestinationPath: "/Applications/Gone.app/Contents/Helpers/nexus")
        try Data("#!/bin/sh\n".utf8).write(to: bin.appending(path: "node"))
        let command = root.appending(path: "Applications/Nexus.app/Contents/Helpers/nexus")

        try CommandLinks.write(in: bin, command: command)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: "php").path(percentEncoded: false)) == command.path(percentEncoded: false))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: "node").path(percentEncoded: false)) == command.path(percentEncoded: false))
    }
}
