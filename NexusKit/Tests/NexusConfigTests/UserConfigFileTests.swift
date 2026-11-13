import Foundation
import Testing
@testable import NexusConfig

struct UserConfigFileTests {
    @Test func aMissingFileGetsTheFirstTextAndAChangeOfTheUserStays() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-user-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "redis/8/redis.conf", directoryHint: .notDirectory)

        try UserConfigFile.writeIfMissing(RedisConfig.initial, to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == RedisConfig.initial)

        try Data("maxmemory 64mb\n".utf8).write(to: file)
        try UserConfigFile.writeIfMissing(RedisConfig.initial, to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "maxmemory 64mb\n")
    }
}
