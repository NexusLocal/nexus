import Foundation
import Testing
@testable import NexusCore

struct ShellCommandsTests {
    private let bin = URL(filePath: "/Users/me/Library/Application Support/Nexus/bin/", directoryHint: .isDirectory)

    @Test func eachNameThatDoesNotRunTheLinkOfNexusIsAnOtherCommand() {
        let output = """
            Welcome back
            nexus-shell-check
            php is an alias for /Applications/MAMP/bin/php/php8.5.2/bin/php -c "/Library/MAMP PRO/php8.5.2.ini"
            composer is a shell function from /Users/me/.zshrc
            node is '/Users/me/Library/Application Support/Nexus/bin/node'
            npm not found

            """

        let others = ShellCommands.others(in: output, bin: bin)

        #expect(others == [
            OtherCommand(name: "php", description: "php is an alias for /Applications/MAMP/bin/php/php8.5.2/bin/php -c \"/Library/MAMP PRO/php8.5.2.ini\""),
            OtherCommand(name: "composer", description: "composer is a shell function from /Users/me/.zshrc"),
            OtherCommand(name: "npm", description: "npm not found"),
        ])
    }

    @Test func textOfTheShellFilesBeforeTheMarkerDoesNotCount() {
        let output = "php is /opt/homebrew/bin/php\nnexus-shell-check\nphp is /Users/me/Library/Application Support/Nexus/bin/php\nnode is '/Users/me/Library/Application Support/Nexus/bin/node'\n"

        #expect(ShellCommands.others(in: output, bin: bin).isEmpty)
        #expect(ShellCommands.others(in: "zsh: no answer", bin: bin).isEmpty)
    }

    @Test func aFolderOnThePathWithAnExtraSlashIsStillTheBinFolderOfNexus() {
        let output = "nexus-shell-check\nphp is '/Users/me/Library/Application Support/Nexus/bin//php'\nnode is '/Users/me/Library/Application Support/Nexus/bin/nodejs'\n"

        #expect(ShellCommands.others(in: output, bin: bin) == [
            OtherCommand(name: "node", description: "node is '/Users/me/Library/Application Support/Nexus/bin/nodejs'"),
        ])
    }

    @Test func aMissingLinkIsNotFound() {
        let others = ShellCommands.others(in: "nexus-shell-check\nnpm not found\nphp is an alias for php8\n", bin: bin)

        #expect(others.map(\.isNotFound) == [true, false])
    }

    @Test func theCheckWatchesTheFilesThatALoginShellReads() {
        let files = ShellCommands.files(home: URL(filePath: "/Users/me", directoryHint: .isDirectory)).map { $0.path(percentEncoded: false) }

        #expect(files.contains("/Users/me/.zshrc"))
        #expect(files.contains("/Users/me/.profile"))
        #expect(files.contains("/etc/zprofile"))
    }

    @Test func theScriptAsksForEachTool() {
        #expect(ShellCommands.script == "print -r -- nexus-shell-check; whence -v -- php composer node npm; true")
    }
}
