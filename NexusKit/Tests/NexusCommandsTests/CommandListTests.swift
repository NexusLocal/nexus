import ArgumentParser
import Testing
@testable import NexusCommands
import NexusCore

struct CommandListTests {
    private static let examples = CommandSection.all.flatMap(\.commands).map(\.command)

    @Test(arguments: examples)
    func eachExampleIsAValidCommand(_ example: String) throws {
        let words = try #require(Self.words(of: example))

        #expect(words.first == "nexus")
        #expect(throws: Never.self) { try NexusCommand.parseAsRoot(Array(words.dropFirst())) }
    }

    @Test func theListHasEveryCommand() throws {
        let listed = try Set(Self.examples.map { example in
            let words = try #require(Self.words(of: example))
            return ObjectIdentifier(type(of: try NexusCommand.parseAsRoot(Array(words.dropFirst()))))
        })

        let missing = Self.leaves(of: NexusCommand.self).filter { !listed.contains(ObjectIdentifier($0)) }

        #expect(missing.isEmpty, "Not on the Command line page: \(missing.map { $0._commandName })")
    }

    @Test func aCommandShowsOnce() {
        #expect(Set(Self.examples).count == Self.examples.count)
    }

    private static func leaves(of command: any ParsableCommand.Type) -> [any ParsableCommand.Type] {
        let subcommands = command.configuration.subcommands

        return subcommands.isEmpty ? [command] : subcommands.flatMap(leaves)
    }

    // The words of an example as a shell gives them. Only double quotes occur in the examples.
    private static func words(of example: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var quoted = false

        for character in example {
            switch character {
            case "\"":
                quoted.toggle()
            case " " where !quoted:
                if !word.isEmpty {
                    words.append(word)
                    word = ""
                }
            default:
                word.append(character)
            }
        }

        if !word.isEmpty {
            words.append(word)
        }

        return quoted ? nil : words
    }
}
