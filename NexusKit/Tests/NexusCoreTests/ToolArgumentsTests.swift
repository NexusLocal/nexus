import Foundation
import Testing
@testable import NexusCore

struct ToolArgumentsTests {
    private func folder(_ tool: ProjectTool, _ arguments: [String]) -> String? {
        ToolArguments.folder(of: tool, in: arguments, currentFolder: "/Users/me/")
    }

    @Test(arguments: [
        (["/Sites/shop/artisan", "boost:mcp"], "/Sites/shop/"),
        (["artisan", "migrate"], "/Users/me/"),
        (["vendor/bin/phpunit"], "/Users/me/vendor/bin/"),
        (["../shop/artisan"], "/Users/shop/"),
        (["-d", "memory_limit=1G", "/Sites/shop/artisan"], "/Sites/shop/"),
        (["-dmemory_limit=1G", "-n", "/Sites/shop/artisan"], "/Sites/shop/"),
        (["-f", "/Sites/shop/index.php"], "/Sites/shop/"),
        (["-S", "localhost:8000", "-t", "/Sites/shop/public"], "/Sites/shop/public/"),
    ])
    func phpTakesTheFolderOfItsScript(arguments: [String], expected: String) {
        #expect(folder(.php, arguments) == expected)
    }

    @Test(arguments: [["-v"], ["-r", "echo 1;"], ["-i"], ["--", "/Sites/shop/artisan"], [], ["-d", "memory_limit=1G"]])
    func phpWithoutAScriptNamesNoFolder(arguments: [String]) {
        #expect(folder(.php, arguments) == nil)
    }

    @Test(arguments: [
        (["/Sites/app/server.js"], "/Sites/app/"),
        (["-r", "dotenv/config", "/Sites/app/server.js"], "/Sites/app/"),
        (["--inspect=9229", "--", "/Sites/app/server.js"], "/Sites/app/"),
    ])
    func nodeTakesTheFolderOfItsScript(arguments: [String], expected: String) {
        #expect(folder(.node, arguments) == expected)
    }

    @Test(arguments: [["-e", "console.log(1)"], ["-v"], ["-"]])
    func nodeWithoutAScriptNamesNoFolder(arguments: [String]) {
        #expect(folder(.node, arguments) == nil)
    }

    @Test(arguments: [
        (ProjectTool.composer, ["--working-dir=/Sites/shop", "install"], "/Sites/shop/"),
        (.composer, ["install", "--working-dir", "/Sites/shop"], "/Sites/shop/"),
        (.composer, ["-d", "../shop", "install"], "/Users/shop/"),
        (.composer, ["-d/Sites/shop", "install"], "/Sites/shop/"),
        (.npm, ["--prefix", "/Sites/app", "ci"], "/Sites/app/"),
        (.npm, ["-C", "/Sites/app", "run", "dev"], "/Sites/app/"),
        (.wp, ["--path=/Sites/blog/wordpress", "option", "get", "siteurl"], "/Sites/blog/wordpress/"),
    ])
    func theWorkingFolderOfATool(tool: ProjectTool, arguments: [String], expected: String) {
        #expect(folder(tool, arguments) == expected)
    }

    @Test func theOptionsOfAScriptAfterTwoDashesDoNotCount() {
        #expect(folder(.composer, ["run", "--", "-d", "/Sites/shop"]) == nil)
        #expect(folder(.composer, ["install"]) == nil)
        #expect(folder(.wp, ["option", "get", "siteurl"]) == nil)
    }
}
