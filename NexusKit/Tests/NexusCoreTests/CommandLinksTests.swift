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

    @Test func aLinkNeverPointsToAMissingCommandOrATemporaryCopyOfTheApp() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "Applications/Nexus.app/Contents/Helpers/nexus")
        let translocated = root.appending(path: "AppTranslocation/1234/d/Nexus.app/Contents/Helpers/nexus")

        for command in [installed, translocated] {
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path(percentEncoded: false))
        }

        #expect(CommandLinks.canPoint(to: installed))
        #expect(!CommandLinks.canPoint(to: translocated))
        #expect(!CommandLinks.canPoint(to: root.appending(path: "Gone.app/Contents/Helpers/nexus")))
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
