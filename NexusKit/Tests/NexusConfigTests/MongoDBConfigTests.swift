import Foundation
import Testing
@testable import NexusConfig

struct MongoDBConfigTests {
    private let data = URL(filePath: "/Nexus Data/mongodb-8.0", directoryHint: .isDirectory)

    @Test func anInstanceWithoutAPasswordRunsAsAReplicaSetWithoutALogin() {
        let arguments = MongoDBConfig.serverArguments(config: URL(filePath: "/config/mongod.conf"), data: data, port: 27017, replicaSet: "nexus", keyFile: nil)

        #expect(arguments == [
            "--config", "/config/mongod.conf",
            "--dbpath", "/Nexus Data/mongodb-8.0/",
            "--port", "27017",
            "--bind_ip", "127.0.0.1",
            "--nounixsocket",
            "--setParameter", "diagnosticDataCollectionEnabled=false",
            "--replSet", "nexus",
        ])
    }

    @Test func anInstanceWithAPasswordNeedsTheKeyFileAndALogin() {
        let keyFile = MongoDBConfig.keyFile(in: data)
        let arguments = MongoDBConfig.serverArguments(config: nil, data: data, port: 27017, replicaSet: "nexus", keyFile: keyFile)

        #expect(arguments.suffix(3) == ["--keyFile", "/Nexus Data/mongodb-8.0/nexus.key", "--auth"])
        #expect(!arguments.contains("--config"))
    }

    @Test func aServerWithASocketFolderGetsItsSocketThere() {
        let arguments = MongoDBConfig.serverArguments(config: nil, data: data, port: 40001, replicaSet: "nexus", keyFile: nil, socketFolder: URL(filePath: "/Nexus/run", directoryHint: .isDirectory))

        #expect(arguments.contains("--unixSocketPrefix"))
        #expect(arguments[arguments.firstIndex(of: "--unixSocketPrefix")! + 1] == "/Nexus/run/")
        #expect(!arguments.contains("--nounixsocket"))
    }

    @Test func aTemporaryStartHasNoReplicaSet() {
        #expect(!MongoDBConfig.serverArguments(config: nil, data: data, port: 40001, replicaSet: nil, keyFile: nil).contains("--replSet"))
    }

    @Test func aKeyHasTheLengthAndTheCharactersThatMongodAccepts() {
        let key = MongoDBConfig.newKey()

        #expect((6...1024).contains(key.count))
        #expect(key.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
        #expect(key != MongoDBConfig.newKey())
    }

    @Test func theFirstConfigFileLimitsTheCache() {
        #expect(MongoDBConfig.initialConf.contains("cacheSizeGB: 1"))
    }
}
