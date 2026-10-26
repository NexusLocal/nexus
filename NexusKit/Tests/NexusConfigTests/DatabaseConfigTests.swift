import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct DatabaseConfigTests {
    @Test func mySQLGetsRootWithThePasswordRootOnEveryLocalAddress() {
        let sql = DatabaseConfig.mysqlInitSQL(account: .standard)

        for host in ["localhost", "127.0.0.1", "::1"] {
            #expect(sql.contains("CREATE USER IF NOT EXISTS 'root'@'\(host)';"))
            #expect(sql.contains("ALTER USER 'root'@'\(host)' IDENTIFIED BY 'root';"))
            #expect(sql.contains("GRANT ALL PRIVILEGES ON *.* TO 'root'@'\(host)' WITH GRANT OPTION;"))
        }
    }

    @Test func mariaDBChangesTheUserTableAndRemovesTheAnonymousUsers() {
        let sql = DatabaseConfig.mariadbInitSQL(account: .standard)

        #expect(sql.contains("DELETE FROM mysql.global_priv WHERE User = ''"))
        #expect(sql.contains("PASSWORD('root')"))
        #expect(!sql.contains("ALTER USER"))
    }

    @Test func aPasswordWithQuotesStaysOneValue() {
        let account = DatabaseAccount(user: "root", password: #"it's "secret"\"#)

        let options = DatabaseConfig.clientOptions(host: "127.0.0.1", port: 3306, account: account, pluginFolder: URL(filePath: "/Application Support/mysql/lib/plugin/"))
        let sql = DatabaseConfig.mysqlInitSQL(account: account)

        #expect(options.contains(#"password = "it's \"secret\"\\""#))
        #expect(options.contains(#"plugin-dir = "/Application Support/mysql/lib/plugin/""#))
        #expect(options.contains("protocol = TCP"))
        #expect(sql.contains(#"IDENTIFIED BY 'it''s "secret"\\';"#))
    }

    @Test func identifiersGetTheQuotesOfTheirServer() {
        #expect(DatabaseConfig.identifier("shop-ticket-1", kind: .mysql) == "`shop-ticket-1`")
        #expect(DatabaseConfig.identifier("shop-ticket-1", kind: .postgresql) == "\"shop-ticket-1\"")
    }

    @Test func myCnfHasAServerSection() {
        #expect(DatabaseConfig.initialMyCnf.contains("[mysqld]"))
    }
}
