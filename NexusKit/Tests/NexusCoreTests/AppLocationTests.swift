import Darwin
import Foundation
import Testing
@testable import NexusCore

struct AppLocationTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "Nexus Location \(UUID().uuidString)", directoryHint: .isDirectory)

    private var applications: URL {
        root.appending(path: "Applications", directoryHint: .isDirectory)
    }

    private var bundle: URL {
        root.appending(path: "Disk/Nexus.app", directoryHint: .isDirectory)
    }

    private final class RecordingFileManager: FileManager {
        var trashed: [URL] = []

        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            trashed.append(url)
            try removeItem(at: url)
        }
    }

    private final class LastStepFailingFileManager: FileManager {
        let trash: URL
        var lastStepFails = true

        init(trash: URL) {
            self.trash = trash
            super.init()
        }

        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try FileManager.default.moveItem(at: url, to: trash)
            outResultingURL?.pointee = trash as NSURL
        }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if lastStepFails {
                lastStepFails = false
                throw CocoaError(.fileWriteUnknown)
            }

            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    private func makeBundle(marker: String = "new") throws {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appending(path: "marker"))
    }

    private func marker(in app: URL) throws -> String {
        try String(contentsOf: app.appending(path: "Contents/marker"), encoding: .utf8)
    }

    private func setQuarantine(on item: URL) {
        let value = "0081;00000000;Safari;"
        setxattr(item.path(percentEncoded: false), "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW)
    }

    private func hasQuarantine(_ item: URL) -> Bool {
        getxattr(item.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    @Test func aTemporaryCopyAndAReadOnlyDiskImageAreTemporary() {
        #expect(AppLocation.isTemporary(path: "/private/var/folders/x/AppTranslocation/1234/d/Nexus.app", onReadOnlyVolume: true))
        #expect(AppLocation.isTemporary(path: "/private/var/folders/x/AppTranslocation/1234/d/Nexus.app", onReadOnlyVolume: false))
        #expect(AppLocation.isTemporary(path: "/Volumes/Nexus/Nexus.app", onReadOnlyVolume: true))
    }

    @Test func applicationsAndAWritableExternalDiskAreNotTemporary() {
        #expect(!AppLocation.isTemporary(path: "/Applications/Nexus.app", onReadOnlyVolume: false))
        #expect(!AppLocation.isTemporary(path: "/Volumes/External/Apps/Nexus.app", onReadOnlyVolume: false))
    }

    @Test func aBundleInAWritableFolderIsNotTemporary() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle()

        #expect(!AppLocation.isTemporary(bundle))
    }

    @Test func aMoveCopiesTheBundleAndLeavesNoQuarantineMark() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle()
        let inner = bundle.appending(path: "Contents/marker")
        setQuarantine(on: bundle)
        setQuarantine(on: inner)
        #expect(hasQuarantine(inner))

        let target = try AppLocation.move(bundle, to: applications)

        #expect(target == applications.appending(path: "Nexus.app", directoryHint: .isDirectory))
        #expect(try marker(in: target) == "new")
        #expect(!hasQuarantine(target))
        #expect(!hasQuarantine(target.appending(path: "Contents/marker")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path(percentEncoded: false)) == ["Nexus.app"])
    }

    @Test func aMovePutsAnOlderCopyInTheTrash() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle()
        let old = applications.appending(path: "Nexus.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appending(path: "marker"))
        let fileManager = RecordingFileManager()

        let target = try AppLocation.move(bundle, to: applications, using: fileManager)

        #expect(fileManager.trashed.map(\.lastPathComponent) == ["Nexus.app"])
        #expect(try marker(in: target) == "new")
    }

    @Test func aFailedLastStepPutsTheOlderCopyBackFromTheTrash() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle()
        let old = applications.appending(path: "Nexus.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appending(path: "marker"))
        let fileManager = LastStepFailingFileManager(trash: root.appending(path: "Trashed.app", directoryHint: .isDirectory))

        #expect(throws: (any Error).self) {
            try AppLocation.move(bundle, to: applications, using: fileManager)
        }

        #expect(try marker(in: applications.appending(path: "Nexus.app", directoryHint: .isDirectory)) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path(percentEncoded: false)) == ["Nexus.app"])
    }

    @Test func aFailedCopyKeepsTheOlderCopyAndLeavesNoTemporaryFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = applications.appending(path: "Nexus.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appending(path: "marker"))

        #expect(throws: (any Error).self) {
            try AppLocation.move(bundle, to: applications)
        }

        #expect(try marker(in: applications.appending(path: "Nexus.app", directoryHint: .isDirectory)) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path(percentEncoded: false)) == ["Nexus.app"])
    }
}
