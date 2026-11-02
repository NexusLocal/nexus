import Foundation
import Testing
@testable import NexusCore

struct ShellPathLineTests {
    private let home = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Home \(UUID().uuidString)", directoryHint: .isDirectory)

    private var setting: ShellPathLine {
        ShellPathLine(bin: home.appending(path: "Library/Application Support/Nexus/bin", directoryHint: .isDirectory), home: home)
    }

    private func zshrc() throws -> String {
        try String(contentsOf: home.appending(path: ".zshrc"), encoding: .utf8)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: home.appending(path: ".zshrc"))
    }

    @Test func theLinePutsTheBinFolderFirstOnThePath() {
        #expect(setting.line == "export PATH=\"$HOME/Library/Application Support/Nexus/bin:$PATH\" # Added by Nexus (Settings > General > Add Nexus to PATH)")
        #expect(ShellPathLine.shellPath(URL(filePath: "/Volumes/My \"Disk\"/$bin/"), home: home) == "/Volumes/My \\\"Disk\\\"/\\$bin")
    }

    @Test func turningItOnAddsOneLineAtTheEndAndTurningItOffRemovesIt() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write("export PATH=\"/opt/homebrew/bin:$PATH\"\nalias ll='ls -l'")

        try setting.turnOn()
        let on = try zshrc()
        let state = setting.state()
        try setting.turnOn()
        let twice = try zshrc()
        try setting.turnOff()

        #expect(on == "export PATH=\"/opt/homebrew/bin:$PATH\"\nalias ll='ls -l'\n\(setting.line)\n")
        #expect(state == .on)
        #expect(twice == on)
        #expect(try zshrc() == "export PATH=\"/opt/homebrew/bin:$PATH\"\nalias ll='ls -l'\n")
        #expect(setting.state() == .off)
    }

    @Test func aLineThatIsNotLastShowsAndMovesToTheEndAtTheNextTurnOn() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write("# start\n\(setting.line)\nexport PATH=\"/Applications/MAMP/bin/php/php8.4/bin:$PATH\"\n\n")

        let before = setting.state()
        try setting.turnOn()

        #expect(before == .notLast)
        #expect(try zshrc() == "# start\nexport PATH=\"/Applications/MAMP/bin/php/php8.4/bin:$PATH\"\n\n\(setting.line)\n")
        #expect(setting.state() == .on)
    }

    @Test func withoutAZshrcTurningItOnMakesOneAndTurningItOffMakesNone() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try setting.turnOff()
        let none = FileManager.default.fileExists(atPath: home.appending(path: ".zshrc").path(percentEncoded: false))
        try setting.turnOn()

        #expect(!none)
        #expect(try zshrc() == "\(setting.line)\n")
    }

    @Test func aLinkedZshrcStaysALinkAndTheFileKeepsItsPermissions() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let dotfiles = home.appending(path: "dotfiles/zshrc")
        try FileManager.default.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export EDITOR=vim\n".utf8).write(to: dotfiles)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotfiles.path(percentEncoded: false))
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".zshrc"), withDestinationURL: dotfiles)

        try setting.turnOn()

        let link = home.appending(path: ".zshrc").path(percentEncoded: false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == dotfiles.path(percentEncoded: false))
        #expect(try String(contentsOf: dotfiles, encoding: .utf8) == "export EDITOR=vim\n\(setting.line)\n")
        #expect(try FileManager.default.attributesOfItem(atPath: dotfiles.path(percentEncoded: false))[.posixPermissions] as? Int == 0o600)
    }
}
