import Foundation
import Testing
@testable import NexusCore

struct DebugCommandTests {
    private let example = "nexus debug artisan my:command"

    private func withProject(_ test: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Nexus Debug \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "app", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "other", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env php\n<?php\n".utf8).write(to: root.appending(path: "artisan"))
        try Data("<?php echo 1;\n".utf8).write(to: root.appending(path: "run.php"))
        try Data("<?php echo 2;\n".utf8).write(to: root.appending(path: "other/task.php"))
        try Data("#!/bin/sh\n".utf8).write(to: root.appending(path: "deploy.sh"))

        try test(root.path(percentEncoded: false))
    }

    private func refusal(_ arguments: [String], in folder: String) -> String? {
        do {
            _ = try DebugCommand.target(of: arguments, currentFolder: folder)
            return nil
        } catch let refusal as DebugCommand.Refusal {
            return refusal.description
        } catch {
            return "\(error)"
        }
    }

    @Test func aScriptWithoutAnExtensionRunsWithPHP() throws {
        try withProject { folder in
            let target = try DebugCommand.target(of: ["artisan", "my:command"], currentFolder: folder)

            #expect(target.tool == .php)
            #expect(target.arguments == ["artisan", "my:command"])
        }
    }

    @Test(arguments: [
        (["php", "-v"], ProjectTool.php, ["-v"]),
        (["composer", "install"], ProjectTool.composer, ["install"]),
        (["wp", "option", "get", "siteurl"], ProjectTool.wp, ["option", "get", "siteurl"]),
    ])
    func aToolOfPHPGetsTheOtherArguments(arguments: [String], tool: ProjectTool, rest: [String]) throws {
        let target = try DebugCommand.target(of: arguments, currentFolder: "/")

        #expect(target.tool == tool)
        #expect(target.arguments == rest)
    }

    @Test func aFirstDoubleDashOnlyEndsTheOptionsOfNexusDebug() throws {
        try withProject { folder in
            let target = try DebugCommand.target(of: ["--", "artisan", "migrate"], currentFolder: folder)

            #expect(target.tool == .php)
            #expect(target.arguments == ["artisan", "migrate"])
        }
    }

    @Test(arguments: ["\u{FEFF}<?php echo 1;", "\n<?php echo 1;", "<?= 1 ?>"])
    func aScriptWithAMarkOrAnEmptyLineBeforeItsCodeIsPHP(start: String) {
        #expect(DebugCommand.isPHP(URL(filePath: "/tools/task"), start: start))
    }

    @Test func anOptionGoesToPHPWithEveryArgument() throws {
        try withProject { folder in
            let target = try DebugCommand.target(of: ["-d", "memory_limit=1G", "run.php"], currentFolder: folder)

            #expect(target.tool == .php)
            #expect(target.arguments == ["-d", "memory_limit=1G", "run.php"])
        }
    }

    @Test func aPHPFileHereOrInAnotherFolderRunsWithPHP() throws {
        try withProject { folder in
            let here = try DebugCommand.target(of: ["run.php"], currentFolder: folder)
            let other = try DebugCommand.target(of: ["\(folder)other/task.php", "--fast"], currentFolder: "/")
            let relative = try DebugCommand.target(of: ["../other/task.php"], currentFolder: "\(folder)app")

            #expect(here.tool == .php)
            #expect(here.arguments == ["run.php"])
            #expect(other.tool == .php)
            #expect(other.arguments == ["\(folder)other/task.php", "--fast"])
            #expect(relative.tool == .php)
        }
    }

    @Test(arguments: [["node", "-v"], ["npm", "ci"]])
    func nodeAndNPMAreRefused(arguments: [String]) {
        #expect(refusal(arguments, in: "/") == "nexus debug runs PHP only. Xdebug cannot debug \(arguments[0]).")
    }

    @Test func aFileThatIsNoPHPFileIsRefused() throws {
        try withProject { folder in
            #expect(refusal(["shop.php"], in: folder) == "Nexus cannot find the file shop.php. nexus debug runs php, composer, wp or a PHP file, for example: \(example)")
            #expect(refusal(["app"], in: folder) == "Nexus cannot find the file app. nexus debug runs php, composer, wp or a PHP file, for example: \(example)")
            #expect(refusal(["deploy.sh"], in: folder) == "deploy.sh is not a PHP file. nexus debug runs php, composer, wp or a PHP file, for example: \(example)")
        }
    }

    @Test func noCommandIsRefused() {
        #expect(refusal([], in: "/") == "Name the command to debug, for example: \(example)")
    }
}
