import Foundation
import Testing
@testable import NexusCore

struct ViteLiveCheckTests {
    private func version(_ text: String) throws -> ViteVersion {
        try #require(ViteVersion(text))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vite live \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writePackage(version: String, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name": "vite", "version": "\#(version)"}"#.utf8).write(to: file)
    }

    @Test(arguments: ["5.4.21", "6.3.9", "6.4.5", "7.3.7", "8.0.9", "8.1.6", "8.2.4", "8.3.6", "8.3.7-beta.1"])
    func aVersionWithoutTheFixesGetsNoLive(_ text: String) throws {
        #expect(!ViteLiveCheck.allowsLive(try version(text)))
    }

    @Test(arguments: ["6.4.6", "6.5.0", "7.3.8", "7.4.0", "8.1.7", "8.2.5", "8.3.7", "8.3.8", "8.4.0", "9.0.0", "9.0.0-beta.1"])
    func aVersionWithTheFixesGetsLive(_ text: String) throws {
        #expect(ViteLiveCheck.allowsLive(try version(text)))
    }

    @Test func aTextThatIsNoFullVersionGivesNoVersionAndNoLive() {
        #expect(ViteVersion("x") == nil)
        #expect(ViteVersion("8") == nil)
        #expect(ViteVersion("8.3") == nil)
        #expect(!ViteLiveCheck.allowsLive(installed: nil))
        #expect(!ViteLiveCheck.allowsLive(installed: "workspace:*"))
        #expect(ViteLiveCheck.allowsLive(installed: "8.3.8"))
    }

    @Test func aPrereleaseIsLowerThanItsRelease() throws {
        #expect(try version("8.3.7-beta.1") < version("8.3.7"))
        #expect(try version("8.3.7") < version("8.3.8"))
        #expect(try version("8.10.0") > version("8.9.9"))
    }

    @Test func theFixIsTheFirstFixAboveTheVersionInItsOwnMajor() throws {
        #expect(ViteLiveCheck.fix(for: try version("8.3.5"))?.description == "8.3.7")
        #expect(ViteLiveCheck.fix(for: try version("8.0.3"))?.description == "8.1.7")
        #expect(ViteLiveCheck.fix(for: try version("6.2.0"))?.description == "6.4.6")
        #expect(ViteLiveCheck.fix(for: try version("5.4.21")) == nil)
    }

    @Test func theVersionComesFromTheFolderAParentBelowTheRootOfGitAndThePnpmFolder() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "repo with space/apps/shop", directoryHint: .isDirectory)
        let repository = root.appending(path: "repo with space", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)

        try writePackage(version: "5.4.21", at: root.appending(path: "node_modules/vite/package.json"))
        let aboveTheRoot = ViteLiveCheck.installedVersion(in: project)

        try writePackage(version: "7.3.8", at: repository.appending(path: "node_modules/.pnpm/node_modules/vite/package.json"))
        let fromThePnpmFolder = ViteLiveCheck.installedVersion(in: project)

        try writePackage(version: "8.3.8", at: repository.appending(path: "node_modules/vite/package.json"))
        let fromTheParent = ViteLiveCheck.installedVersion(in: project)

        try writePackage(version: "9.0.0", at: project.appending(path: "node_modules/vite/package.json"))
        let fromTheFolder = ViteLiveCheck.installedVersion(in: project)

        #expect(aboveTheRoot == nil)
        #expect(fromThePnpmFolder == "7.3.8")
        #expect(fromTheParent == "8.3.8")
        #expect(fromTheFolder == "9.0.0")
    }

    @Test func aFolderWithoutGitReadsOnlyItself() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writePackage(version: "8.3.8", at: root.appending(path: "node_modules/vite/package.json"))

        #expect(ViteLiveCheck.installedVersion(in: project) == nil)
    }

    @Test func theTextOfAnOldVersionNamesTheApprovedListOrTheFixOfItsLine() {
        #expect(ViteLiveCheck.liveBlockedText(version: "5.4.21", install: "npm install") == "Live is not possible for this site. It has Vite 5.4.21, which lets visitors read files on your Mac. Update Vite in this project to 6.4.6, 7.3.8, 8.1.7 or later to use Live.")
        #expect(ViteLiveCheck.liveBlockedText(version: "8.3.5", install: "npm install") == "Live is not possible for this site. It has Vite 8.3.5, which lets visitors read files on your Mac. Update Vite in this project to 8.3.7 or later to use Live.")
        #expect(ViteLiveCheck.liveBlockedText(version: nil, install: "pnpm install") == "Live is not possible for this site. Nexus cannot find the version of Vite in node_modules. Vite is the dev server of the styles and scripts. Run pnpm install in this project to use Live.")
    }

    @Test func theRefusalOfAnAppNamesTheVersionOrTheInstall() {
        #expect(ViteLiveCheck.appRefusal(version: "5.4.21", install: "npm install") == "Nexus cannot share this app. Its dev server is Vite 5.4.21, which lets visitors read files on your Mac. Update Vite in this project to 6.4.6, 7.3.8, 8.1.7 or later. Then share the app again.")
        #expect(ViteLiveCheck.appRefusal(version: "7.3.1", install: "npm install") == "Nexus cannot share this app. Its dev server is Vite 7.3.1, which lets visitors read files on your Mac. Update Vite in this project to 7.3.8 or later. Then share the app again.")
        #expect(ViteLiveCheck.appRefusal(version: nil, install: "yarn install") == "Nexus cannot share this app. Its dev server is Vite, but Nexus cannot find the version of Vite in node_modules. Run yarn install in this project. Then share the app again.")
    }
}
