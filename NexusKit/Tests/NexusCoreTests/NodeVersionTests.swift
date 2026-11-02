import Foundation
import Testing
@testable import NexusCore

struct NodeVersionTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Node \(UUID().uuidString)", directoryHint: .isDirectory)
    private static let all = ["22", "24", "26"]

    private func write(_ text: String, to path: String) throws -> URL {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.deletingLastPathComponent()
    }

    private func choice(_ file: String, _ text: String, installed: [String] = all) -> NodeChoice {
        NodeLines.choose(hint: NodeVersionHint(file: file, text: text), installed: installed)
    }

    @Test func aVersionFileGivesTheLineOfItsMajor() {
        #expect(choice(".nvmrc", "24.1.0") == NodeChoice(line: "24", reason: "from .nvmrc"))
        #expect(choice(".node-version", "v22") == NodeChoice(line: "22", reason: "from .node-version"))
        #expect(choice(".tool-versions", "22.11.0") == NodeChoice(line: "22", reason: "from .tool-versions"))
    }

    @Test func aMajorThatNexusDoesNotHaveGivesTheOldestNewerLine() {
        #expect(choice(".nvmrc", "16") == NodeChoice(line: "22", reason: ".nvmrc asks for 16"))
        #expect(choice(".nvmrc", "20.10.0") == NodeChoice(line: "22", reason: ".nvmrc asks for 20.10.0"))
        #expect(choice(".nvmrc", "23") == NodeChoice(line: "24", reason: ".nvmrc asks for 23"))
        #expect(choice(".nvmrc", "30") == NodeChoice(line: "26", reason: ".nvmrc asks for 30"))
    }

    @Test func enginesGivesTheNewestLTSLineInTheRange() {
        #expect(choice("package.json", ">=18.0.0").line == "26")
        #expect(choice("package.json", ">= 20.9.0").line == "26")
        #expect(choice("package.json", ">=22 <25").line == "24")
        #expect(choice("package.json", "^22.11.0").line == "22")
        #expect(choice("package.json", "~22.11").line == "22")
        #expect(choice("package.json", "18 - 22").line == "22")
        #expect(choice("package.json", "^20 || ^24").line == "24")
        #expect(choice("package.json", "22.x").line == "22")
        #expect(choice("package.json", "<=24").line == "24")
        #expect(choice("package.json", ">24").line == "26")
        #expect(choice("package.json", "*").line == "26")
    }

    @Test func aRangeWithoutALineOfNexusGivesTheOldestNewerLine() {
        #expect(choice("package.json", "^16.0.0") == NodeChoice(line: "22", reason: "package.json asks for ^16.0.0"))
        #expect(choice("package.json", "20.10.0") == NodeChoice(line: "22", reason: "package.json asks for 20.10.0"))
        #expect(choice("package.json", "<18") == NodeChoice(line: "22", reason: "package.json asks for <18"))
    }

    @Test func anInstalledLineGoesBeforeALineThatIsNotInstalled() {
        #expect(NodeLines.choose(hint: nil, installed: ["22"]) == NodeChoice(line: "22", reason: "newest LTS"))
        #expect(NodeLines.choose(hint: nil, installed: []) == NodeChoice(line: "26", reason: "newest LTS"))
        #expect(choice("package.json", ">=22", installed: ["24"]).line == "24")
        #expect(choice(".nvmrc", "26", installed: ["22"]).line == "26")
    }

    @Test func theAliasesOfNvmGiveALine() {
        #expect(choice(".nvmrc", "lts/*", installed: []) == NodeChoice(line: "26", reason: "from .nvmrc"))
        #expect(choice(".nvmrc", "lts/jod").line == "22")
        #expect(choice(".nvmrc", "lts/Krypton").line == "24")
        #expect(choice(".nvmrc", "node", installed: ["22", "24"]).line == "24")
        #expect(choice(".nvmrc", "lts/hydrogen") == NodeChoice(line: "22", reason: ".nvmrc asks for lts/hydrogen"))
        #expect(choice(".nvmrc", "lts/unknown") == NodeChoice(line: "26", reason: ".nvmrc asks for lts/unknown"))
        #expect(choice(".nvmrc", "system") == NodeChoice(line: "26", reason: ".nvmrc asks for system"))
    }

    @Test func aLineOfANewerManifestCounts() {
        #expect(NodeLines.lines(installed: ["28", "22"]) == ["22", "24", "26", "28"])
        #expect(choice(".nvmrc", "28", installed: ["28"]) == NodeChoice(line: "28", reason: "from .nvmrc"))
    }

    @Test func theNearestFolderWithAVersionWins() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try write("# Node of the project\n22\n", to: "shop/.nvmrc")
        let frontend = try write(#"{"name": "frontend", "engines": {"node": "^24"}}"#, to: "shop/frontend/package.json")
        let tools = try write("ruby 3.3.0\nnodejs 22.11.0\n", to: "shop/tools/.tool-versions")
        let deep = project.appending(path: "app/Models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        #expect(NodeVersionFiles.hint(from: frontend, upTo: project) == NodeVersionHint(file: "package.json", text: "^24"))
        #expect(NodeVersionFiles.hint(from: tools, upTo: project) == NodeVersionHint(file: ".tool-versions", text: "22.11.0"))
        #expect(NodeVersionFiles.hint(from: deep, upTo: project) == NodeVersionHint(file: ".nvmrc", text: "22"))
    }

    @Test func theSearchStopsAtTheFolderOfTheProject() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("24\n", to: ".nvmrc")
        let project = try write(#"{"name": "shop"}"#, to: "shop/package.json")
        let outside = try write("", to: "other/.node-version")

        #expect(NodeVersionFiles.hint(from: project, upTo: project) == nil)
        #expect(NodeVersionFiles.hint(from: outside, upTo: project) == nil)
        #expect(NodeVersionFiles.hint(from: project, upTo: root) == NodeVersionHint(file: ".nvmrc", text: "24"))
    }
}
