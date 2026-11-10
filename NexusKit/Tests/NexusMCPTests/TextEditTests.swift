import Foundation
import Testing
@testable import NexusMCP

struct JSONTextEditTests {
    private let entry = JSONText.object([("command", .string("/n/nexus")), ("args", .array([.string("mcp")]))])

    @Test func anEntryGoesAfterTheOtherServersAndTheRestStays() throws {
        let text = """
        {
          "theme": "dark",
          "mcpServers": {
            "pencil": {
              "command": "/p"
            }
          },
          "zeta": 1
        }

        """

        let result = try JSONTextEdit.setting(["mcpServers", "nexus"], to: entry, in: text)

        #expect(result == """
        {
          "theme": "dark",
          "mcpServers": {
            "pencil": {
              "command": "/p"
            },
            "nexus": {
              "command": "/n/nexus",
              "args": ["mcp"]
            }
          },
          "zeta": 1
        }

        """)
    }

    @Test func aMissingServersKeyAndAnEmptyFileGetOne() throws {
        #expect(try JSONTextEdit.setting(["mcpServers", "nexus"], to: entry, in: "") == """
        {
          "mcpServers": {
            "nexus": {
              "command": "/n/nexus",
              "args": ["mcp"]
            }
          }
        }

        """)

        #expect(try JSONTextEdit.setting(["servers", "nexus"], to: .bool(true), in: "{\n    \"a\": 1\n}\n") == "{\n    \"a\": 1,\n    \"servers\": {\n        \"nexus\": true\n    }\n}\n")
    }

    @Test func commentsAndTrailingCommasStay() throws {
        let text = """
        // Zed settings
        {
          "theme": "One Dark", // the theme
          /* servers */
          "context_servers": {
            "other": { "command": "x" }, // keep
          },
        }
        """

        let result = try JSONTextEdit.setting(["context_servers", "nexus"], to: .bool(true), in: text)

        #expect(result == """
        // Zed settings
        {
          "theme": "One Dark", // the theme
          /* servers */
          "context_servers": {
            "other": { "command": "x" }, // keep
            "nexus": true,
          },
        }
        """)

        #expect(try JSONTextEdit.removing(["context_servers", "nexus"], in: result) == text)
    }

    @Test func anEntryThatExistsGetsItsNewValue() throws {
        let text = "{\n  \"mcpServers\": {\n    \"nexus\": {\"command\": \"/old\"},\n    \"b\": 2\n  }\n}\n"
        let result = try JSONTextEdit.setting(["mcpServers", "nexus"], to: .bool(false), in: text)

        #expect(result == "{\n  \"mcpServers\": {\n    \"nexus\": false,\n    \"b\": 2\n  }\n}\n")
    }

    @Test(arguments: [
        ("{\n  \"s\": {\n    \"a\": 1,\n    \"nexus\": 2\n  }\n}\n", "{\n  \"s\": {\n    \"a\": 1\n  }\n}\n"),
        ("{\n  \"s\": {\n    \"nexus\": 2,\n    \"a\": 1\n  }\n}\n", "{\n  \"s\": {\n    \"a\": 1\n  }\n}\n"),
        ("{\n  \"s\": {\n    \"nexus\": 2\n  }\n}\n", "{\n  \"s\": {}\n}\n"),
        ("{\"s\": {\"a\": 1, \"nexus\": 2}}", "{\"s\": {\"a\": 1}}"),
        ("{\"s\": {\"a\": 1}}", "{\"s\": {\"a\": 1}}"),
    ])
    func removalTakesTheEntryWithItsCommaAndLine(text: String, expected: String) throws {
        #expect(try JSONTextEdit.removing(["s", "nexus"], in: text) == expected)
    }

    @Test func stringsGoIntoAListOnce() throws {
        let text = "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\"\n    ]\n  }\n}\n"
        let added = try JSONTextEdit.addingStrings(["mcp__nexus__a", "Bash(ls)"], toArrayAt: ["permissions", "allow"], in: text)

        #expect(added == "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\",\n      \"mcp__nexus__a\"\n    ]\n  }\n}\n")
        #expect(try JSONTextEdit.removingStrings(["mcp__nexus__a"], fromArrayAt: ["permissions", "allow"], in: added) == text)
        #expect(try JSONTextEdit.addingStrings(["x"], toArrayAt: ["permissions", "allow"], in: "{}") == "{\n  \"permissions\": {\n    \"allow\": [\"x\"]\n  }\n}")
    }

    @Test(arguments: ["{\"a\": }", "[1, 2]", "{\"a\": 1} {}", "{\"mcpServers\": 3}"])
    func aFileThatIsNotSafeChangesNothing(text: String) {
        #expect(throws: JSONTextEdit.Failure.self) {
            try JSONTextEdit.setting(["mcpServers", "nexus"], to: .bool(true), in: text)
        }
    }

    @Test func textWithEscapesAndUnicodeStays() throws {
        let text = "{\"a\": \"é \\\"q\\\" // not a comment\", \"b\": []}"
        let result = try JSONTextEdit.setting(["b2"], to: .string("ü"), in: text)

        #expect(result.hasPrefix("{\"a\": \"é \\\"q\\\" // not a comment\", \"b\": [],"))
        #expect(try JSONTextEdit.value(at: ["b2"], in: result) as? String == "ü")
    }
}

