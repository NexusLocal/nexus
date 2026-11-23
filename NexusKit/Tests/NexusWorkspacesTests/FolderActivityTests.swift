import Foundation
import Synchronization
import Testing
@testable import NexusWorkspaces

struct FolderActivityTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-activity-\(UUID().uuidString)/vendor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "laravel/framework/src/Illuminate"), withIntermediateDirectories: true)
        return folder
    }

    private func setOld(_ folder: URL) throws {
        let old = Date(timeIntervalSinceNow: -3600)
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []

        for item in [folder] + items {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: item.path(percentEncoded: false))
        }
    }

    @Test func aChangeUpToThreeLevelsDeepIsTheLastChange() throws {
        let vendor = try folder()
        defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
        try setOld(vendor)

        try Data("{}".utf8).write(to: vendor.appending(path: "laravel/framework/composer.json"))

        let last = try #require(FolderActivity.lastChange(in: [vendor.path(percentEncoded: false)]))
        #expect(Date().timeIntervalSince(last) < 60)
    }

    @Test func aChangeDeeperThanThreeLevelsDoesNotCount() throws {
        let vendor = try folder()
        defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
        try setOld(vendor)

        try Data("<?php".utf8).write(to: vendor.appending(path: "laravel/framework/src/Illuminate/Foundation.php"))

        let last = try #require(FolderActivity.lastChange(in: [vendor.path(percentEncoded: false)]))
        #expect(Date().timeIntervalSince(last) > 3000)
    }

    @Test func anOldFolderOrNoFolderGivesNoWait() async throws {
        let vendor = try folder()
        defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
        try setOld(vendor)
        let clock = ContinuousClock()
        let start = clock.now

        await FolderActivity.waitUntilQuiet([vendor.path(percentEncoded: false), "/tmp/nexus-no-such-folder"], quiet: .seconds(5))

        #expect(clock.now - start < .seconds(1))
    }

    @Test func aFolderThatAnotherProgramWritesGetsAWaitUntilItStopsChanging() async throws {
        let vendor = try folder()
        defer { try? FileManager.default.removeItem(at: vendor.deletingLastPathComponent()) }
        try setOld(vendor)
        let clock = ContinuousClock()
        let start = clock.now
        let lastWrite = Mutex(start)

        let writer = Task {
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    for index in 0..<6 {
                        try? Data("<?php".utf8).write(to: vendor.appending(path: "laravel/file-\(index).php"))
                        lastWrite.withLock { $0 = clock.now }
                        Thread.sleep(forTimeInterval: 0.2)
                    }

                    finished.resume()
                }
            }
        }

        let firstFile = vendor.appending(path: "laravel/file-0.php").path(percentEncoded: false)

        while !FileManager.default.fileExists(atPath: firstFile) {
            try await Task.sleep(for: .milliseconds(10))
        }

        await FolderActivity.waitUntilQuiet([vendor.path(percentEncoded: false)], quiet: .milliseconds(1500), interval: .milliseconds(100))
        let end = clock.now
        await writer.value

        #expect(end - lastWrite.withLock { $0 } >= .milliseconds(1500))
        #expect(end - start < .seconds(6))
    }
}
