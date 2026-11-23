import Foundation
import NexusCore
import NexusIPC
import Testing
@testable import NexusEngine
@testable import NexusRuntime

struct MongoDBTransferTests {
    @Test(arguments: [
        ("mongodb+srv://ann@cluster0.example.net/shop?retryWrites=true", "mongodb+srv://ann@cluster0.example.net/?retryWrites=true"),
        ("mongodb://127.0.0.1:27018/shop", "mongodb://127.0.0.1:27018/"),
        ("mongodb://127.0.0.1:27018", "mongodb://127.0.0.1:27018/"),
    ])
    func theURLOfTheOtherServerLosesItsDatabase(_ value: String, server: String) {
        #expect(MongoDBTransfer.serverURL(value) == server)
    }

    @Test func aLocalServerWithAPasswordHasItsUserInTheDatabaseAdmin() {
        let endpoint = MongoDBTransfer.local(port: 27017, account: DatabaseAccount(user: "ann bee", password: "pw"))

        #expect(endpoint.url == "mongodb://ann%20bee@127.0.0.1:27017/?authSource=admin")
        #expect(endpoint.password == "pw")
        #expect(MongoDBTransfer.local(port: 27017, account: .newInstance).url == "mongodb://127.0.0.1:27017/")
    }

    @Test func aNamespaceEscapesTheWildcardOfItsDatabase() {
        #expect(MongoDBTransfer.namespacePattern("shop") == "shop.*")
        #expect(MongoDBTransfer.namespacePattern("a*b\\c") == "a\\*b\\\\c.*")
    }

    @Test func aPasswordInTheConfigFileKeepsItsQuotesAndBackslashes() {
        #expect(MongoDBTransfer.yamlString("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }

    @Test func theURLOfTheSheetGetsThePasswordOnlyWhenItHasNone() {
        let withoutPassword = NexusEngine.mongoDBSource(DatabaseServer(account: DatabaseAccount(user: "", password: "secret"), url: "mongodb+srv://ann@cluster0.example.net/shop"))
        let withPassword = NexusEngine.mongoDBSource(DatabaseServer(account: DatabaseAccount(user: "", password: "other"), url: "mongodb://ann:secret@127.0.0.1:27018"))
        let fromHost = NexusEngine.mongoDBSource(DatabaseServer(host: "127.0.0.1", port: 27018, account: DatabaseAccount(user: "root", password: "pw")))

        #expect(withoutPassword.url == "mongodb+srv://ann@cluster0.example.net/")
        #expect(withoutPassword.password == "secret")
        #expect(withPassword.password == "")
        #expect(fromHost.url == "mongodb://root@127.0.0.1:27018/")
        #expect(fromHost.password == "pw")
    }

    @Test(arguments: [
        (["DB_CONNECTION": "mysql", "MONGODB_URI": "mongodb://127.0.0.1:27017", "MONGODB_DATABASE": "shop"], "shop"),
        (["MONGODB_URI": "mongodb://localhost:27017/crm"], "crm"),
        (["DB_CONNECTION": "mongodb", "DB_URI": "mongodb://127.0.0.1:27017", "DB_DATABASE": "app"], "app"),
        (["DB_CONNECTION": "mongodb", "DB_DATABASE": "app"], "app"),
        (["MONGODB_URI": "mongodb://127.0.0.1:27018/shop"], nil),
        (["MONGODB_URI": "mongodb+srv://ann@cluster0.example.net/shop"], nil),
        (["DB_CONNECTION": "mysql", "DB_DATABASE": "shop"], nil),
    ] as [([String: String], String?)])
    func aSiteUsesADatabaseOfAMongoDBWhenItsKeysReachThePort(_ env: [String: String], database: String?) {
        #expect(NexusEngine.mongoDBDatabase(in: env, port: 27017) == database)
    }

    @Test func aLinkToAMongoDBWithoutAPasswordHasNoUser() {
        #expect(DatabaseKind.mongodb.url(port: 27017, account: .newInstance, database: "shop")?.absoluteString == "mongodb://127.0.0.1:27017/shop")
        #expect(DatabaseKind.mongodb.url(port: 27017, account: DatabaseAccount(user: "root", password: "pw"), database: "shop")?.absoluteString == "mongodb://root:pw@127.0.0.1:27017/shop?authSource=admin")
    }

    @Test func onlyTablePlusAndCompassOpenMongoDB() {
        #expect(DatabaseApp.allCases.filter { $0.opens(.mongodb) } == [.tablePlus, .compass])
        #expect(!DatabaseApp.compass.opens(.mysql))
    }

    @Test func theArchiveOfMongoDBLosesMongosAndTheScriptOfCompass() {
        #expect(RuntimeInstaller.unusedFiles(of: "mongodb") == ["bin/mongos", "bin/install_compass"])
        #expect(RuntimeInstaller.unusedFiles(of: "mysql").isEmpty)
    }
}
