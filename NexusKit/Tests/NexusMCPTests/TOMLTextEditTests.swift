import Foundation
import Testing
@testable import NexusMCP

struct TOMLTextEditTests {
    private let path = ["mcp_servers", "nexus"]
    private let keys = [TOMLTextEdit.Key("command", "\"/n/nexus\""), TOMLTextEdit.Key("args", "[\"mcp\"]"), TOMLTextEdit.Key("tool_timeout_sec", "120", keepExisting: true)]

    @Test func aNewTableGoesAtTheEnd() throws {
        let result = try TOMLTextEdit.setting(path, keys: keys, in: "model = \"x\"\n\n[mcp_servers.pencil]\ncommand = \"/p\"\n")

        #expect(result == "model = \"x\"\n\n[mcp_servers.pencil]\ncommand = \"/p\"\n\n[mcp_servers.nexus]\ncommand = \"/n/nexus\"\nargs = [\"mcp\"]\ntool_timeout_sec = 120\n")
        #expect(try TOMLTextEdit.value("command", inTable: path, in: result) == "/n/nexus")
    }

    @Test func aTableThatExistsKeepsTheKeysAndSubtablesOfTheUser() throws {
        let text = """
        [mcp_servers.nexus]
        command = "/old"
        startup_timeout_sec = 30
        tool_timeout_sec = 300

        [mcp_servers.nexus.env]
        DEBUG = "1"

        # The GitHub server
        [mcp_servers.github]
        command = "gh"

        """

        let result = try TOMLTextEdit.setting(path, keys: keys, in: text)

        #expect(result == """
        [mcp_servers.nexus]
        command = "/n/nexus"
        startup_timeout_sec = 30
        tool_timeout_sec = 300
        args = ["mcp"]

        [mcp_servers.nexus.env]
        DEBUG = "1"

        # The GitHub server
        [mcp_servers.github]
        command = "gh"

        """)
    }

    @Test func removalLeavesTheOtherTablesAndTheirComments() throws {
        let text = "a = 1\n\n[mcp_servers.nexus]\ncommand = \"/n\"\n\n# The plugin\n[plugins.x]\nenabled = true\n"

        #expect(try TOMLTextEdit.removing(path, in: text) == "a = 1\n\n# The plugin\n[plugins.x]\nenabled = true\n")
        #expect(try TOMLTextEdit.removing(path, in: "a = 1\n\n[mcp_servers.nexus]\ncommand = \"/n\"\n") == "a = 1\n")
        #expect(try TOMLTextEdit.removing(path, in: "[mcp_servers.nexus]\ncommand = \"/n\"\n") == "")
    }

    @Test func quotedNamesAndSpacesCount() {
        #expect(TOMLTextEdit.headerName("[ mcp_servers . \"nexus-dev\" ] # x") == ["mcp_servers", "nexus-dev"])
        #expect(TOMLTextEdit.headerName("[[a.b]]") == ["a", "b"])
    }

    @Test(arguments: [
        "[mcp_servers]\nnexus = { command = \"/n\" }\n",
        "[mcp_servers]\n'nexus' = { command = \"/n\" }\n",
        "[mcp_servers]\nnexus.command = \"/n\"\n",
        "mcp_servers.nexus.command = \"/n\"\n",
        "mcp_servers = { nexus = { command = \"/n\" } }\n",
    ])
    func anotherFormIsNotSafe(text: String) {
        #expect(throws: TOMLTextEdit.Failure.self) {
            try TOMLTextEdit.setting(path, keys: keys, in: text)
        }
    }

    @Test func anotherServerInTheParentTableIsSafe() throws {
        let text = "[mcp_servers]\nnexusish = { command = \"/x\" }\n"

        #expect(try TOMLTextEdit.setting(path, keys: keys, in: text).hasSuffix("[mcp_servers.nexus]\ncommand = \"/n/nexus\"\nargs = [\"mcp\"]\ntool_timeout_sec = 120\n"))
    }

    @Test func aHeaderInAMultiLineStringIsNoHeader() throws {
        #expect(try !TOMLTextEdit.hasTable(path, in: "note = \"\"\"\n[mcp_servers.nexus]\n\"\"\"\n"))
    }

    @Test(arguments: [
        ("command = '/a/b/nexus'", "/a/b/nexus"),
        ("command = \"/a#b/nexus\" # the command", "/a#b/nexus"),
        ("command = \"/a \\\"b\\\"/nexus\"", "/a \"b\"/nexus"),
    ])
    func aStringValueReadsLiteralStringsAndHashes(line: String, value: String) throws {
        #expect(try TOMLTextEdit.value("command", inTable: path, in: "[mcp_servers.nexus]\n\(line)\n") == value)
    }

    @Test func aPathWithQuotesAndBackslashesIsEscaped() {
        #expect(TOMLTextEdit.quoted("/a b/\"c\"\\d") == "\"/a b/\\\"c\\\"\\\\d\"")
    }
}
